'use strict';
/**
 * 纵横四海 · 统一 AI 决策服务
 *
 * 封装「大模型调用」的单一出口，供各系统决策层复用，把 AI 注入整个游戏：
 *   - 世界经济事件生成（ai-decision）
 *   - AI 玩家行为决策（ai-players）
 *   - 世界情报/市场分析摘要（经济系统向玩家提供的信息）
 *   - 战斗 NPC/世界播报叙述生成
 *
 * 后端可切换（ZHSH_AI_PROVIDER）：
 *   - ollama（默认）：本地 http://127.0.0.1:11434，零成本、低延迟、需本机算力
 *   - openai       ：任何 OpenAI 兼容的联网服务（OpenAI / DeepSeek / 通义千问 compatible-mode /
 *                    Kimi(Moonshot) / 智谱 / SiliconFlow / OpenRouter …），只需 HTTP + API Key，
 *                    无需本地模型。配置 ZHSH_AI_BASE_URL / ZHSH_AI_API_KEY 后开箱可用。
 *
 * 核心约定：所有 aiDecide 均接受"当前状态上下文"，输出结构化对象；
 * 解析失败或超界由各调用方规则层保底（决不让 AI 失败导致系统不可用）。
 */
const http = require('node:http');
const https = require('node:https');

/** ---- 总开关 ----
 *  ZHSH_AI_DISABLED=1 时立刻失败、绝不发起任何请求：所有场景瞬时走规则保底。
 *  与"没装模型"不同——这是明确关闭，不会产生网络/显存开销，用于纯规则玩法。 */
const DISABLED = String(process.env.ZHSH_AI_DISABLED || '0') === '1';

/** ---- 后端选择 ----
 *  ollama=本地模型（默认）；openai=OpenAI 兼容的联网服务（别名 cloud） */
const PROVIDER = String(process.env.ZHSH_AI_PROVIDER || 'ollama').trim().toLowerCase();
const IS_CLOUD = PROVIDER === 'openai' || PROVIDER === 'cloud' || PROVIDER === 'remote';

const OLLAMA_URL = process.env.ZHSH_OLLAMA_URL || 'http://127.0.0.1:11434';
/** 联网后端基址：含版本段、不含 /chat/completions，例如 https://api.deepseek.com/v1 */
const API_BASE_URL = String(process.env.ZHSH_AI_BASE_URL || (IS_CLOUD ? 'https://api.openai.com/v1' : '')).replace(/\/+$/, '');
const API_KEY = process.env.ZHSH_AI_API_KEY || '';
/** 单次请求超时：本地 <1s，云端留足首字延迟；超时即中断，避免信号量被挂死请求永久占用 */
const TIMEOUT_MS = Math.max(1000, Number(process.env.ZHSH_AI_TIMEOUT_MS || (IS_CLOUD ? 30000 : 60000)));

/** ---- 全局 AI 并发信号量 ----
 *  同时进行的大模型请求数上限（默认 2，可用 ZHSH_AI_CONCURRENCY 调），超出排队等前一个完成。
 *  本地取决于 GPU，云端取决于 API 速率限制；两种后端都需要这个闸门。 */
const AI_CONCURRENCY = Math.max(1, Number(process.env.ZHSH_AI_CONCURRENCY || 2));
let activeGenerate = 0;
const waitQueue = [];
function acquireGenerate() {
  return new Promise((resolve) => {
    if (activeGenerate < AI_CONCURRENCY) { activeGenerate += 1; return resolve(); }
    waitQueue.push(resolve);
  });
}
function releaseGenerate() {
  const next = waitQueue.shift();
  if (next) { /* 保持 activeGenerate 不变，直接移交许可 */ next(); }
  else activeGenerate -= 1;
}

/** 当前默认模型（环境变量可覆盖）。分层：MODEL_LIGHT=内容生成主力，MODEL_FAST=极高频短任务。
 *  云端的默认值不如本地有共识，因此 MODEL_LIGHT/FAST 未单独指定时回落到 ZHSH_AI_MODEL；
 *  两者都未设置时用各后端的安全默认（云端 gpt-4o-mini，本地沿用原 qwen 分层）。 */
const CLOUD_DEFAULT_MODEL = process.env.ZHSH_AI_MODEL || 'gpt-4o-mini';
const MODEL = process.env.ZHSH_AI_MODEL || (IS_CLOUD ? CLOUD_DEFAULT_MODEL : 'qwen3.5:9b');
const MODEL_LIGHT = process.env.ZHSH_AI_MODEL_LIGHT || (IS_CLOUD ? CLOUD_DEFAULT_MODEL : 'qwen3.8-4b-distill:latest');
const MODEL_FAST = process.env.ZHSH_AI_MODEL_FAST || (IS_CLOUD ? CLOUD_DEFAULT_MODEL : 'qwen3.8-2b-distill:latest');

if (IS_CLOUD) {
  console.log(`[AI] provider=openai base=${API_BASE_URL} models=${MODEL_LIGHT}/${MODEL_FAST} timeout=${TIMEOUT_MS}ms key=${API_KEY ? 'set' : 'MISSING'}`);
}
if (DISABLED) {
  console.log('[AI] ZHSH_AI_DISABLED=1：AI 已关闭，所有场景走规则保底');
}
if (IS_CLOUD && !API_KEY) {
  console.warn('[AI] 未设置 ZHSH_AI_API_KEY，联网模型请求大概率会鉴权失败（各 AI 场景将走规则保底）');
}

/** ---- 运行统计 ----
 *  供 /api/ai/status 可视化：真的在用模型吗？成功率多少？最近一次错误/延迟是什么？
 *  排查"配了云端但一直是 fallback"这类问题全靠它。 */
const stats = {
  calls: 0, ok: 0, fail: 0,
  lastAt: null, lastOkAt: null, lastErrorAt: null,
  lastError: null, lastLatencyMs: null, lastModel: null,
  promptTokens: 0, completionTokens: 0, cachedPromptTokens: 0, lastUsage: null,
};
function recordCall(model) { stats.calls += 1; stats.lastAt = Date.now(); stats.lastModel = model; }
function recordOk(startedAt) { stats.ok += 1; stats.lastOkAt = Date.now(); stats.lastLatencyMs = Date.now() - startedAt; }
/** 云端返回的 usage：累计 token，供 /api/ai/status 做成本观察 */
function recordUsage(usage) {
  if (!usage) return;
  const prompt = Number(usage.prompt_tokens) || 0;
  const completion = Number(usage.completion_tokens) || 0;
  const cached = Number(usage.prompt_cache_hit_tokens) || 0;
  stats.promptTokens += prompt;
  stats.completionTokens += completion;
  stats.cachedPromptTokens += cached;
  stats.lastUsage = { prompt, completion, cached };
}
function recordFail(err) {
  stats.fail += 1;
  stats.lastErrorAt = Date.now();
  stats.lastError = String(err?.message ?? err).slice(0, 200);
}

/** 当前 AI 配置与运行状况快照（不含 API Key） */
function getStats() {
  return {
    enabled: !DISABLED,
    provider: IS_CLOUD ? 'openai' : 'ollama',
    isCloud: IS_CLOUD,
    base: IS_CLOUD ? API_BASE_URL : OLLAMA_URL,
    models: { default: MODEL, light: MODEL_LIGHT, fast: MODEL_FAST },
    timeoutMs: TIMEOUT_MS,
    concurrency: AI_CONCURRENCY,
    calls: stats.calls,
    ok: stats.ok,
    fail: stats.fail,
    successRate: stats.calls ? Math.round((stats.ok / stats.calls) * 100) : null,
    lastLatencyMs: stats.lastLatencyMs,
    lastModel: stats.lastModel,
    lastAt: stats.lastAt,
    lastOkAt: stats.lastOkAt,
    lastErrorAt: stats.lastErrorAt,
    lastError: stats.lastError,
    tokens: { prompt: stats.promptTokens, completion: stats.completionTokens, cachedPrompt: stats.cachedPromptTokens },
    lastUsage: stats.lastUsage,
  };
}

/** 统一 HTTP(S) JSON 请求：按协议选 transport，带超时与错误体截断。
 *  云端与本地 ollama 共用，保证两套后端的失败语义一致（reject，由调用方保底）。 */
function requestJson(urlString, { method = 'GET', body = null, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const transport = url.protocol === 'https:' ? https : http;
    const payload = body === null ? null : JSON.stringify(body);
    const req = transport.request(url, {
      method,
      headers: {
        ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {}),
        ...headers,
      },
    }, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`http ${res.statusCode}: ${data.slice(0, 300)}`));
          return;
        }
        try { resolve(data ? JSON.parse(data) : {}); }
        catch (err) { reject(new Error(`response parse: ${err.message}`)); }
      });
    });
    req.setTimeout(TIMEOUT_MS, () => { req.destroy(new Error(`timeout after ${TIMEOUT_MS}ms`)); });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

/** 唤起 ollama 生成，返回原始响应文本。
 *  注意：qwen 系列思考开关必须放请求体顶层 `think: false`（否则模型输出完整推理链，
 *  拖慢且污染结果）；options.think 无效。可按调用传入 model 选择分层模型。
 *  keepAlive=-1 让模型常驻内存，消除每次请求的加载/卸载开销（预热的真实推理速度）。 */
async function ollamaGenerate(prompt, { format = null, temperature = 0.8, maxTokens = 300, system = null, model = null, think = true, keepAlive = -1, numCtx = 4096 } = {}) {
  if (DISABLED) throw new Error('AI disabled (ZHSH_AI_DISABLED=1)');
  if (IS_CLOUD) return cloudGenerate(prompt, { format, temperature, maxTokens, system, model });
  await acquireGenerate();
  const body = {
    model: model || MODEL,
    prompt,
    stream: false,
    think,
    keep_alive: keepAlive, // 负值=常驻；0=立即卸载；正值=驻留秒数
    options: { temperature, max_tokens: maxTokens, num_ctx: numCtx },
  };
  if (system) body.system = system;
  if (format) body.format = format;
  recordCall(body.model);
  const startedAt = Date.now();
  try {
    const data = await requestJson(new URL('/api/generate', OLLAMA_URL).toString(), { method: 'POST', body });
    recordOk(startedAt);
    return data.response ?? '';
  } catch (err) {
    recordFail(err);
    throw err;
  } finally {
    releaseGenerate();
  }
}

/** 联网后端（OpenAI 兼容 /chat/completions）：单轮 user + 可选 system，json 模式按需开启。
 *  `response_format` 个别服务不支持，可用 ZHSH_AI_JSON_MODE=0 关闭（调用方本就有正则兜底）。 */
async function cloudGenerate(prompt, { format = null, temperature = 0.8, maxTokens = 300, system = null, model = null } = {}) {
  await acquireGenerate();
  const messages = [];
  if (system) messages.push({ role: 'system', content: system });
  messages.push({ role: 'user', content: prompt });
  const body = {
    model: model || MODEL,
    messages,
    temperature,
    max_tokens: maxTokens,
    stream: false,
  };
  // DeepSeek 的思考模式默认开启：先产出 reasoning_content，且推理 token 也吃 max_tokens。
  // 游戏里的台词/旁白/决策都是几十字的短文本，开着思考会又慢又贵、还经常只返回空 content。
  // 默认关闭；确实需要推理时设 ZHSH_AI_THINKING=1。非 DeepSeek 端点不发这个字段，避免 400。
  const thinkingSetting = String(process.env.ZHSH_AI_THINKING ?? '').trim().toLowerCase();
  const deepSeekEndpoint = /(^|\.)deepseek\.com/i.test(API_BASE_URL);
  if (deepSeekEndpoint || thinkingSetting) {
    const thinkingEnabled = ['1', 'true', 'on', 'enabled', 'yes'].includes(thinkingSetting);
    body.thinking = { type: thinkingEnabled ? 'enabled' : 'disabled' };
  }
  if (format === 'json' && process.env.ZHSH_AI_JSON_MODE !== '0') body.response_format = { type: 'json_object' };
  recordCall(body.model);
  const startedAt = Date.now();
  try {
    const data = await requestJson(`${API_BASE_URL}/chat/completions`, {
      method: 'POST',
      body,
      headers: { Authorization: `Bearer ${API_KEY}` },
    });
    recordUsage(data?.usage);
    recordOk(startedAt);
    return data?.choices?.[0]?.message?.content ?? '';
  } catch (err) {
    recordFail(err);
    throw err;
  } finally {
    releaseGenerate();
  }
}

/** 唤起大模型并解析 JSON 对象（剥离 markdown 代码块） */
async function ollamaJson(prompt, opts = {}) {
  const raw = await ollamaGenerate(prompt, { ...opts, format: 'json' });
  const m = String(raw ?? '').match(/\{[\s\S]*\}/);
  if (!m) throw new Error('model did not return a JSON object');
  return JSON.parse(m[0]);
}

/** 当前配置的模型是否可用。
 *  本地：/api/tags 里存在该模型；云端：/models 可达（且若能列出则核对模型名）。 */
function ping() {
  if (DISABLED) return Promise.resolve(false);
  if (IS_CLOUD) {
    return requestJson(`${API_BASE_URL}/models`, { headers: { Authorization: `Bearer ${API_KEY}` } })
      .then((data) => {
        const ids = (data?.data ?? []).map((m) => m?.id).filter(Boolean);
        return ids.length ? ids.includes(MODEL_LIGHT) || ids.includes(MODEL) : true;
      })
      .catch(() => false);
  }
  return requestJson(new URL('/api/tags', OLLAMA_URL).toString())
    .then((data) => Boolean(data.models?.some((m) => m.name === MODEL)))
    .catch(() => false);
}

/**
 * 安全的 JSON 决策：调用 aiDecide（async 函数）并规范化；任何失败返回 fallback。
 * 供各系统保底使用，保证 AI 错误不破坏游戏。
 */
async function safeJsonDecide(aiDecide, context, fallback) {
  if (typeof aiDecide !== 'function') return fallback;
  try { const result = await aiDecide(context); return (result && typeof result === 'object') ? result : fallback; }
  catch { return fallback; }
}

module.exports = {
  ollamaGenerate, ollamaJson, safeJsonDecide, ping, getStats,
  MODEL, MODEL_LIGHT, MODEL_FAST,
  PROVIDER, IS_CLOUD, DISABLED, OLLAMA_URL, API_BASE_URL, TIMEOUT_MS,
};

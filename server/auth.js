'use strict';
/**
 * 纵横四海 · 网游服务器 — 账号与认证
 * 零外部依赖：JWT(HS256) 用 node:crypto 手写，密码哈希用 scrypt。
 */
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

// JWT secret 必须跨重启保持稳定，否则每次重启服务器都会把所有人踢下线
// （客户端还拿着旧 token → 401 → 界面卡在“无法启动”）。
// 优先用环境变量；否则生成一次并落盘到 server/data/jwt-secret。
const SECRET_PATH = path.join(__dirname, 'data', 'jwt-secret');

function loadJwtSecret() {
  const fromEnv = process.env.ZHSH_JWT_SECRET;
  if (fromEnv) return fromEnv;
  try {
    const saved = fs.readFileSync(SECRET_PATH, 'utf8').trim();
    if (saved.length >= 32) return saved;
  } catch { /* 首次启动：还没有 secret 文件 */ }
  const generated = crypto.randomBytes(32).toString('hex');
  try {
    fs.mkdirSync(path.dirname(SECRET_PATH), { recursive: true });
    fs.writeFileSync(SECRET_PATH, generated + '\n', { encoding: 'utf8', mode: 0o600 });
  } catch (error) {
    console.warn(`[auth] JWT secret 无法写入 ${SECRET_PATH}，重启后需要重新登录：${error.message}`);
  }
  return generated;
}

const JWT_SECRET = loadJwtSecret();
const TOKEN_TTL_SECONDS = 7 * 24 * 3600;

function base64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function b64urlDecode(str) {
  str = str.replace(/-/g, '+').replace(/_/g, '/');
  return Buffer.from(str, 'base64').toString('utf8');
}

function signJwt(payload) {
  const header = b64encodeJson({ alg: 'HS256', typ: 'JWT' });
  const body = b64encodeJson(payload);
  const signature = hmac(`${header}.${body}`);
  return `${header}.${body}.${signature}`;
}

function verifyJwt(token) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) return null;
  const [header, body, signature] = parts;
  const expected = hmac(`${header}.${body}`);
  const a = Buffer.from(expected), b = Buffer.from(signature);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const payload = JSON.parse(b64urlDecode(body));
    if (payload.exp && Number(payload.exp) < Math.floor(Date.now() / 1000)) return null;
    return payload;
  } catch { return null; }
}

function b64encodeJson(obj) {
  return base64url(Buffer.from(JSON.stringify(obj), 'utf8'));
}

function hmac(input) {
  return crypto.createHmac('sha256', JWT_SECRET).update(input).digest('base64url');
}

// ---- 密码哈希 (scrypt) ----
function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 64).toString('hex');
  return { salt, hash };
}

function verifyPassword(password, salt, hash) {
  const derived = crypto.scryptSync(password, salt, 64).toString('hex');
  const a = Buffer.from(derived), b = Buffer.from(hash);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function issueToken(account) {
  const payload = {
    sub: account.id,
    username: account.username,
    player: account.player_canonical_id,
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
  };
  return signJwt(payload);
}

module.exports = { signJwt, verifyJwt, hashPassword, verifyPassword, issueToken, TOKEN_TTL_SECONDS };

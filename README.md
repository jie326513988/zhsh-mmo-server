# 纵横四海 · 文字版大航海网游（zhsh-mmo-server）

一个**非官方**、**服务端同步**的多人在线文字网游项目。灵感与部分原始数据源自怀旧文字页游《纵横四海》（原QQ家园/苏摩科技运营，已于 2018 年停服）。本项目建立在 nicktangx 的《纵横四海》高保真复原项目（提供复原骨架与思路）之上，并在此基础上扩展为多人在线联机网游。**与原版权方无任何关联**。


---

## 项目简介

本项目以高保真复原的《纵横四海》为骨架，扩展为**多人在线文字网游**，参考《大航海时代》系列升级为「文字版大航海时代」级玩法。

**技术栈**：Node.js（单进程，HTTP + WebSocket）+ SQLite（WAL）+ 内存状态 registry + 本地大模型（ollama qwen）驱动的 AI 系统。零第三方 npm 依赖（纯 Node 内置模块 + 本地 SQLite）。

## 核心特性

### 世界与叙事
- **12 大世界区域**：地中海 / 北海 / 西非 / 东非红海 / 印度洋 / 东南亚 / 东亚·中国 / 东亚·日本 / 新大陆·玛雅 / 加勒比 / 南美 / 极地，各配文化主题 / 发现物 / 势力 / 关键 NPC。
- **原版任务线为主线**：以原版《纵横四海》15 条任务线（task.series.01–15，威尼斯新手→海盗铁箱→詹姆斯→龙珠→寻裔之路→聚宝盆→妖气长安→八仙蓬莱→地魔）为唯一主线按序推进，并挂接世界观扩充（12 区域探索 / 44 个发现物 / 世界事件支线 / AI 叙述）；另含 80+ 关键 NPC、47 条支线、30 个本土船员、21 项职业技能。

### 多人在线联机
- 玩家账号（JWT + scrypt），状态全部服务器落盘（SQLite WAL）。
- WebSocket 实时世界广播；同城玩家可见；AI 玩家与世界共存。

### 动态世界经济
- 商品价格**动态变化**：区域基准（产区 0.75 / 异区 1.25）× 区域供需周期 × 天气影响 × 随机波动。
- **随机世界事件**（海盗 / 丰收 / 旱灾 / 风暴 / 瘟疫 / 商集 / 珍稀发现…）作用于价格与天气，并产生新遭遇。
- 玩家通过「天下页」情报（天气 / 供需 / 事件 + 套利提示）**主动收集信息**判断买卖时机，体现信息不对称的经济决策深度。

### 大航海玩法（7 批）
- **市场套利** / **装备强化**（15 级、失败不降）/ **宠物**（30 只、上限 3、出战伤害）
- **探索发现 + 声望爵位**（水手→船长→提督→总督→公爵）
- **船员随从**（招募上限 5，属性加成）+ **技能职业**（技能树）
- **商会 + 城市占领 / 税收**（影响力投资、占领区免税+日税）
- 战斗 / 航海 / 钓鱼 / 潜水 / 地牢 / 掉落等完整玩法

### AI 驱动系统（本地大模型，无需联网）
- **分层模型**：内容生成用 qwen3.8-4b-distill，极高频超短任务用 2b，9b 备用；`keep_alive=-1` 常驻 + 顶层 `think:false`，常驻后 <1s 实时响应。
- **9 个 AI 场景**：NPC 情境台词 / 世界事件播报 / 市场情报综述 / 经济事件生成 / 战斗叙述 / AI 玩家决策 / 市场顾问 / 发现物探索叙事 / 任务情境叙述。
- **AI 玩家**：3 名 AI 船员（ollama 决策 + 规则执行层）与世界共存。

---

## 快速开始

### 启动游戏（Windows 推荐）

本仓库即完整的游戏本身：游戏服务器 + 浏览器客户端。**Windows 用户直接双击根目录 `启动游戏.cmd`**（或 `启动游戏.vbs`，无控制台窗口），游戏服务器将以**系统托盘**方式常驻后台并自动打开浏览器。

**首次启动会先弹出「AI 设置」窗口**，让你选择本局用本地模型、联网模型还是关闭 AI（详见下节）。之后右键托盘图标可「打开游戏 / AI 设置 / 重启服务器 / 停止服务器 / 退出」，托盘提示文字会显示当前 AI 后端。任何时候想改配置，双击根目录 `ai-setup.cmd` 即可。

- 服务器监听 `http://0.0.0.0:4173`；浏览器打开 `http://127.0.0.1:4173/`，**注册账号**即可进入。
- 局域网其他设备：`http://<本机局域网IP>:4173/`（首次启动自动放行防火墙端口）。
- 存档位于 `server/data/`（账号库 accounts.db / 玩家库 players.sqlite / 运行时库 runtime.sqlite / 经济状态 economy.json），服务端落盘、多设备共档。
- 需 Node.js 22 或更高版本，**无需安装 npm 依赖**。

#### 手动启动（跨平台）

```powershell
cd <仓库根目录>
node server/server.js
```

服务器监听 `http://0.0.0.0:4173`。经济 tick / AI tick 间隔可用 `ZHSH_ECO_TICK_MS` / `ZHSH_AI_TICK_MS` 调整。

### AI 模型（可选，增强体验）
AI 是**同一个服务器进程内**的调用，没有独立的启动命令：起服务器时自动接入，未配置模型时各场景走规则保底（游戏核心玩法不受影响）。全部经由 `server/ai/ai-decision-service.js` 单一出口。

**图形化选择（推荐）**：双击 `ai-setup.cmd`，或在双击 `启动游戏.cmd` 时按提示选择。

| 模式 | 行为 | 适用 |
| --- | --- | --- |
| 本地模型（ollama） | 调 `http://127.0.0.1:11434`，免费可离线 | 有独立显卡、在意零成本 |
| 联网模型（OpenAI 兼容） | 调云端 API，按量计费，无需本地算力 | 机器较弱、想要更好的文笔 |
| 关闭 AI | 零调用零费用，全部走规则保底，AI 玩家也不启动 | 只想玩数值与剧情 |

窗口里有「测试连接」按钮，会真实请求 `/api/tags` 或 `/v1/models` 并检查模型名是否存在。本地模式下，打开窗口或点「测试连接」都会自动拉起 ollama（仅限 `127.0.0.1/localhost`），所以不必先手动启动服务；若提示缺模型，按提示 `ollama pull` 补齐即可；设置保存在根目录 `ai-config.json`（**含 API Key，已被 .gitignore 排除**）。游戏内「设置」页也能看到当前后端、模型、调用成功率与最近错误。

以下是等价的命令行配置方式：

**A. 本地 ollama（默认）** —— 默认 `ZHSH_OLLAMA_URL=http://127.0.0.1:11434`：

```powershell
ollama pull qwen3.5:4b   # 内容生成主力（9 个场景用它）
ollama pull qwen3.5:2b   # AI 玩家高频决策用它
setx ZHSH_AI_MODEL_LIGHT "qwen3.5:4b"   # 必须覆盖：代码默认的 qwen3.8-*-distill 在 ollama 库中不存在
setx ZHSH_AI_MODEL_FAST  "qwen3.5:2b"
```

**B. 联网模型（OpenAI 兼容）** —— 任何 OpenAI 兼容服务皆可，无需本地算力：

```powershell
setx ZHSH_AI_PROVIDER "openai"
setx ZHSH_AI_BASE_URL "https://api.deepseek.com/v1"   # 含版本段，不含 /chat/completions
setx ZHSH_AI_API_KEY  "sk-..."
setx ZHSH_AI_MODEL    "deepseek-chat"                 # LIGHT/FAST 未单独设置时都回落到它
```

常见服务的 `ZHSH_AI_BASE_URL`：DeepSeek `https://api.deepseek.com/v1`、通义千问 `https://dashscope.aliyuncs.com/compatible-mode/v1`、Kimi `https://api.moonshot.cn/v1`、智谱 `https://open.bigmodel.cn/api/paas/v4`、SiliconFlow `https://api.siliconflow.cn/v1`、OpenRouter `https://openrouter.ai/api/v1`。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `ZHSH_AI_PROVIDER` | `ollama` | `openai` 切到联网模型 |
| `ZHSH_AI_MODEL` / `_LIGHT` / `_FAST` | 见上 | 三层模型，`_LIGHT` 覆盖 9 个叙事场景，`_FAST` 只给 AI 玩家 |
| `ZHSH_AI_TIMEOUT_MS` | 云端 30000 / 本地 60000 | 单请求超时，超时中断以释放并发槽 |
| `ZHSH_AI_CONCURRENCY` | `2` | 同时进行的模型请求上限 |
| `ZHSH_AI_TICK_MS` | `45000` | AI 玩家决策节奏（联网时建议调大以省额度） |
| `ZHSH_AI_DISABLED` | — | 设 `1` 彻底关闭 AI：不发起任何请求，AI 玩家也不启动 |
| `ZHSH_ECO_AI` | 开启 | 设 `0` 关闭经济事件 AI（注意：市场综述 AI 不受它控制） |

> **成本提示**：AI 玩家每 tick 对 3 名船员各请求一次，加上经济引擎每分钟一条市场综述，**挂机基线约 7 次/分钟（约 1 万次/天）**。用联网模型时建议调大 `ZHSH_AI_TICK_MS`，或按需灰度。

## 构建与数据

```powershell
# 重新生成数据库与客户端内容
node scripts/import-content.js
node scripts/build-browser.js

# UI 截图巡检（Edge headless，产物在 artifacts/ui-shots/）
npm run ui:shots
```

重新生成内容后，`server/data/runtime.sqlite` 会基于内容库重建。

界面排版约定（经典 WAP：不用 Grid/圆角，靠 flex 百分比 + 固定图标槽 + table 对齐）见
[`docs/design/ui-patterns.md`](docs/design/ui-patterns.md)。

## 数据与缓存位置

游戏本体**只写仓库所在目录**，不会向系统盘写存档或缓存：

| 内容 | 位置 |
| --- | --- |
| 账号库 / 玩家存档 / 经济状态 | `server/data/`（`accounts.db`、`runtime.sqlite`、`economy.json`） |
| 内容库 | `data/zhsh-content.sqlite` |
| 客户端构建产物 | `dist/`（可用 `npm run build` 随时重建） |
| AI 设置（含 API Key） | 根目录 `ai-config.json`（已 gitignore） |
| 浏览器侧 | 仅 `localStorage` 两条键（登录 token、角色 id）。所有静态资源带 `Cache-Control: no-store`，浏览器**不会**把那份 15MB 内容包写进磁盘缓存 |
| 本地 ollama 模型 | 默认 `%USERPROFILE%\.ollama\models`（数 GB），由 `OLLAMA_MODELS` 决定；本机已设为 `E:\ollama-models`。换盘只改这个变量并重启 ollama |
| ollama 程序本体 | 本机装在 `E:\Ollama`（3.16 GB，经官方 `/DIR=` 参数指定；`C:\...\Local\Programs\Ollama` 不存在）。重装用 `ollama-install.cmd`，支持断点续传并校验数字签名 |
| ollama 日志与配置 | `%LOCALAPPDATA%\Ollama`（约 0.2 MB，日志/设置库）与 `%USERPROFILE%\.ollama`（SSH 密钥等，KB 级）——这两处由 ollama 自身固定，无法改盘 |

最后两行属于浏览器与 ollama 自身的行为，与游戏无关；不想在 C 盘产生任何模型文件时，AI 选择「联网模型」或「关闭」即可。

## 测试

```powershell
node --test tests/*.test.js   # 单元与集成测试
```

## 项目结构

```
server/           # 游戏服务器：HTTP/WS 端点、认证、经济引擎、AI 系统
server/content/   # 12区世界/商品/发现物/宠物/主线/角色/支线/船员/技能/城市 等数据
server/ai/        # AI 决策服务、NPC台词、播报、战斗/发现物/任务叙述
server/eco/       # 世界经济引擎（动态价格/天气/事件）+ AI 情报/顾问
src/task-runtime/ # 游戏引擎（任务/战斗/经济/装备/宠物/船员/商会等 Runtime）
web/              # 客户端前端（app.js + game-api.js）
tests/            # 集成测试与基准
docs/             # 复原资料、任务索引、冲突记录、设计决策
data/             # 内容库
scripts/          # 构建/导出/校验脚本
```

## 数据来源

### 上游复原项目（骨架与思路）
本项目的任务、地图、NPC、怪物、装备等**原始数据与高保真复原骨架**，源自 **nicktangx 的《纵横四海》高保真复原项目**（`github.com/nicktangx/zhsh-remake`，Initial public release）。该项目对多源资料进行了系统整理，保留了来源证据、冲突记录与修复决策（见 `docs/` 与 `restoration_records` 等表），并为后续扩展提供了：复原任务/地图/NPC/怪/装备数据、原始引擎（`src/task-runtime`、`web` 前端骨架）、修复工具与测试方法。

### 融合内容来源：《纵横四海 · 潮汐纪事》（Godot 4 版）
本项目在玩法机制层面参考并吸收了 **976971956 的《纵横四海：潮汐纪事》**（`github.com/976971956/zongheng-sihai`，Godot 4 手机竖屏 2D 航海 RPG，同样基于苏摩科技 2009 WAP/QQ 家园旧版改编）。该仓库的设计文档系统梳理了旧版考据结论与数值拟合方案，以下内容据此引入（**只吸收机制与设计思路，未复制其 GDScript 代码或美术资产**）：

| 吸收内容 | 来源 | 落地方式 | 文档依据 |
| --- | --- | --- | --- |
| **怪物状态效果 + 周期技能** | `潮汐纪事` 敌人 `effect`/`special` 字段 | 给 `monster_definitions` 增加 `effect`（中毒/虚弱/诅咒/缓慢，按概率施加）+ `special`（每 N 回合伤害倍增）；战斗结算在既有公式上叠加，不改变平衡锚点 | `docs/design/external-absorption-summary.md` |
| **装备套装分段共鸣** | `潮汐纪事` 装备 `set_id`/`bonuses`（2/4/6 件分段激活） | 给装备 `normalized_data_json` 写 `set_id` + `set_bonuses`（哥伦布7件/龙20件/航海4件），`effectiveStats` 按已装备同套件数取 2/4/6 最高档累计攻防/体力/速度；数值锚定单件属性 ~25/50/75% 量级，不破坏平衡 | `docs/design/external-absorption-summary.md` |

> 说明：吸收遵循「数值锚定现有基准、不破坏经济与战斗平衡」原则。Godot 版独有的 2D 即时驾驶、付费/失败等待、私人舰队等因形态不符或违背禁止商用定位，明确不吸收，详见 `docs/design/external-absorption-summary.md`。

**免责声明**：本项目为非官方研究复刻，与原版权方（腾讯QQ家园、苏摩科技等）无任何关联，不持有其商标或授权。若权利人主张权利，本项目将配合移除相关数据。请勿用于商业用途（见 LICENSE）。

## License

**禁止商用（No Commercial Use）**。详见 [LICENSE](LICENSE)。二次发布须保留版权声明与许可证全文。

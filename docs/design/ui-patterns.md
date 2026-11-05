# 界面模式与对齐约定（经典 WAP 风格）

> 这套界面是"经典手机文字 MUD"的等价复原：**最大宽度 420px、文字链接下划线、不用卡片/圆角/CSS Grid**。
> `tests/browser-playable.test.js` 会断言 `styles.css` 里不出现 `grid-template-columns` / `border-radius` / `.panel` / `.card`，
> 所以做对齐时用 **flex + 百分比宽度 + 固定图标槽 + table**，不要引入 Grid 或圆角。

## 一、为什么不用 Grid

参考站（纵横四海2、老 wap 文字 MUD）的观感来自：

- 纯文字、无卡片、无圆角、无阴影；
- 多列地名/链接靠**等宽列**对齐（4 列出口、2 列系列、5 列导航）；
- 地图是一张等宽字符网格，而不是彩色卡片面板。

Grid 能实现同样效果，但会破坏项目既定的"经典 WAP"约束与测试护栏；flex 百分比 + `table-layout:fixed` 已经足够。

## 二、可复用的布局原语

| 场景 | 标记 | 对齐方式 |
| --- | --- | --- |
| 出口 | `.exit-grid` + 每个 `.text-link` | flex，`flex:0 0 25%`，≤360px 变 33% |
| 任务系列 | `.series-grid` + `.series-item` | flex，`flex:1 1 calc(50% - 6px)`；≤480px 变整行，名称左、进度右 |
| 任务行 | `.task-row` | flex：序号 `1.6em` / 名称 `flex:1` / 状态右对齐；快速旅行换行缩进 |
| NPC | `.npc-grid` + `.npc-item` | 两列 flex，固定 20px 图标槽，名称左对齐 |
| 导航 | `.primary-nav` + `.nav-link` | flex，`flex:0 0 20%`（≤400px 25%），固定 20px 图标槽 |
| 背包 | `.bag-row` | flex：图标 22px / 序号 1.4em / 名称 `flex:1` / 数量右 |
| 商店 | `.shop-row` | flex：图标 / 名称 `flex:1` / 价格 / 操作（窄屏可换行） |
| 市场 | `.trade-row` | flex：名称 `flex:1` / 价格 / 买入卖出固定宽度 |
| 角色列表 | `.character-row` | flex：名称 `flex:1` / 等级 / 操作 |
| 地图（附近） | `.city-map-table` | `table-layout:fixed`；原地名块用 `rowspan/colspan` 还原形状 |
| 地图（全城） | `.city-map-table.is-list` | 4 列固定表格，名称省略号 |

通用规则：

1. **需要跨行对齐的元素，必须有固定宽度的槽位**（图标 20px、序号 1.4em、状态右侧固定），否则文字宽度会破坏列；
2. 可伸缩列用 `flex:1 1 auto; min-width:0`，配合 `overflow:hidden;text-overflow:ellipsis;white-space:nowrap`；
3. 长名称最多两行（`-webkit-line-clamp:2`），不要单行硬截断；
4. 不用 `border-radius`；分隔线用 1px 实线/点线。

## 三、城内地图

数据来自原版 `cities.grid_json`（导出时并入内容包的 `cities[].grid`）：

- **附近**：以当前地点为中心截 9×7 窗口，按地点块生成 `<table>`，块用 `rowspan/colspan` 保持形状；★ 当前位置，蓝色可点；
- **全城**：按参考站「地图全景」的做法，4 列地名表格，不做整张网格缩放；
- 地点名 → `map_nodes` 按 `display_name` 匹配；城市自身节点不在网格里时落到「其他地点」。

## 四、截图巡检

```
npm run ui:shots
```

用 Edge headless 打开 `http://127.0.0.1:4173/`，自动注册/登录 `uiprobe`（截图后记得删测试账号），逐页截图到
`artifacts/ui-shots/`（已 gitignore）。脚本会走：位置、任务、系列展开、城内地图（附近/全城）、背包、市场、烹饪、
状态、设置、超管；并在结束时打印浏览器 console 错误。

> 截图脚本会写入测试账号与铜币/物品，跑完删除 `uiprobe`：
> `delete from accounts where username='uiprobe'`（服务端 `player_*` 行同理）。

## 五、测试护栏

- `tests/browser-playable.test.js`：CSS 不得出现 Grid/圆角/panel/card；`max-width:420px`、下划线链接必须保留；
- `tests/authoritative-assets.test.js`：导航必须仍包含 `compendium`（dev=1）与 `admin` 入口；
- `npm test` 覆盖烹饪运行时（学习/等级/扣料）与内容包哈希稳定性。

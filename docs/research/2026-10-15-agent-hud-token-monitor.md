# Agent HUD、Token Monitor 对 Codex TouchBar 的借鉴

调研日期：2026-10-15。结论基于公开 README、项目文档、关键源码和仓库提供的界面截图；没有安装运行两个竞品，没有进行性能、耗电或真实账户兼容性测试。截图中的数据不是本次测量结果。

## 1. 结论

Codex TouchBar 最值得发展的方向是：**更容易理解的额度状态、更及时且克制的提醒、手边可执行的快捷操作**。

- 从 Agent HUD 借鉴：常驻摘要 → 展开详情 → 独立分析的层级；将数字转化为近期变化与行动提示；把需要关注的状态突出出来。
- 从 Token Monitor 借鉴：额度、重置倒计时、新鲜度的紧密编排；紧凑趋势；少量外观预设与实时预览；可选自适应刷新。
- 保留自身优势：AppKit 原生体验、两个额度窗口、四个固定操作槽、系统 Control Strip、凭据与聊天内容零读取的边界。
- 暂不扩展到多供应商、多账户切换、会话审批、同步和成本中心。它们有真实用途，但会改变当前工具的职责与数据边界。

## 2. 调研快照与证据

| 项目 | 本次读取的版本 | 核验范围 |
| --- | --- | --- |
| Agent HUD Open | `376e9d6af2e47cccf0ec90c33f94659e48644ca2` | README、HUD 规则、数据访问、额度语义、预测逻辑、主题与截图 |
| Token Monitor | `631c25cb4947bd7a75aebf5997bbeadd33cc9c98`，package.json 为 0.71.0 | README、首页/额度截图、Codex 数据源、菜单栏布局、自适应刷新、第三方重置预测 |
| Codex TouchBar | `981a2d92b83e2ca2b4cf598b18bdfa59d19dea67`，README 对应 v2.2.1 | 当前 README、截图、详情面板、额度卡、Touch Bar、历史与提醒代码 |

外部项目使用固定提交链接，避免后续 main 分支变化影响复核。当前项目仅新增本调研文档，未修改产品实现。

## 3. 两个产品分别解决什么问题

| 维度 | Agent HUD Open | Token Monitor | Codex TouchBar 的取舍 |
| --- | --- | --- | --- |
| 核心任务 | 看额度、看 Agent 是否需要人介入、返回会话 | 汇总 token、估算成本、查看额度与跨设备使用情况 | 专注 Codex 额度和桌面快捷操作 |
| 常驻入口 | 刘海、屏幕边缘、Simple 小面板 | 菜单栏/托盘、悬浮小窗、边缘侧栏、小组件 | 已有菜单栏和实体 Touch Bar |
| 展开内容 | 额度、余额、近期 token、会话与请求 | 首页、额度、工具、模型、设备、会话等分组 | 主面板保持短，分析另开窗口 |
| 数据深度 | 会话、轮次、调用、缓存与 API 价格估算 | 多工具/模型/项目/设备统计、历史与导出 | 当前只有额度观测，不能推算 token 或花费 |
| 技术实现 | Swift，桌面层包含 AppKit 与 SwiftUI | Electron 主体，另有原生 macOS 小组件 | 无需迁移 UI 框架来借鉴布局 |

Agent HUD README 同时介绍官方产品和开源构建：iPhone、Apple Watch、iCloud Remote 等产品能力不能全部算成 agent-hud-open 的能力。其数据访问文档明确说开源构建没有云同步或推送服务。[Agent HUD README](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/README.md)、[开源数据边界](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/docs/data-access.md)

Token Monitor 的首页大数字突出 token 总量，额度页将多个提供方和账户纵向分组；支持本地模式以及可选多设备同步。这适合多工具使用者，但若移植到仅看两项 Codex 额度的工具中，会增加大量导航和设置。[Token Monitor README](https://github.com/Javis603/token-monitor/blob/631c25cb4947bd7a75aebf5997bbeadd33cc9c98/README.zh-CN.md)、[技术入口](https://github.com/Javis603/token-monitor/blob/631c25cb4947bd7a75aebf5997bbeadd33cc9c98/package.json)

## 4. 功能借鉴：先补解释，再补预测

### 4.1 将“额度还有多少”延伸为“最近变化如何”——优先

Agent HUD 用剩余额度、近期消耗速度、距重置时间来判断是否可能提前耗尽；其计算并非简单拿总 token 换算额度。5 小时窗口观察最近一小时，周窗口观察最近一天，并设最短样本时长、跨回升重建基线等规则。[额度语义](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/docs/usage-semantics.md)、[计算实现](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/Sources/AgentHUDCore/Logic/Quota/UsageAnalytics.swift)

建议分两步：

1. 先显示可核验事实，例如“最近 30 分钟观测下降 8 个百分点”。不足 30 分钟就显示实际观测时长或“记录不足”。这可复用现有历史，无需读取聊天记录。
2. 再考虑默认关闭的趋势估算，例如“按近期速度，可能在重置前用尽”。必须标注估算，不给出“某个任务一定能做完”的承诺。

样本必须来自成功查询；同一窗口、同一有效段内计算。长采样空档、过期数据、额度回升、重置时间或套餐变化时停止计算并重新建立基线。现有历史的 `rise` 标记是图表注释规则，不宜直接当预测连续性的全部判据。

更关键的限制：本工具不读取账户身份，无法可靠识别同套餐账户切换。不能直接照搬 Agent HUD 按账户维护长期预测的可信度；初版宜只做短期观测说明，并保留切换账户后清空记录的入口。

### 4.2 提醒应围绕明确事件——优先补小缺口

当前版本已有四种阈值提醒、启动基线与去重，不能将“增加低额提醒”当成新功能。

值得补充的是：

- 可用重置机会即将到期：只使用响应中已有的到期时间；缺失时不猜。
- 一次性的“恢复后提醒我”：适合额度耗尽后临时等待的场景，比长期进入设置开关更顺手。
- 未来若增加预测预警，限制为同一有效周期一次，并允许关闭。

Agent HUD 已有新增重置机会提醒，可借鉴“首次读数不补发、失败/旧读数不确认”的规则；本工具已有部分同类保护，应复用而非另写一套。[Agent HUD 提醒规则](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/docs/usage-semantics.md)

### 4.3 可选智能刷新——第二阶段

Token Monitor 有明确的自适应模式：通常五分钟，估计接近耗尽时缩短，最低一分钟；固定间隔仍保持原意。代码根据剩余比例和观察到的消耗速度安排查询，而不是只看“低于某个百分比”。这可以避免“低额但整晚闲置，仍高频查询”的浪费。[自适应刷新源码](https://github.com/Javis603/token-monitor/blob/631c25cb4947bd7a75aebf5997bbeadd33cc9c98/src/shared/limits/burnRate.js)

本项目适合借鉴策略，不适合直接搬常量：当前前台默认 30 秒，后台 5 分钟，查询还会启动短生命周期子进程。建议在通用设置中提供独立可选模式；尊重刷新开关、限制最短间隔、不重叠请求、不因后台切换延期。已知重置时间到达后可以安排一次确认查询，但倒计时归零不等于额度已恢复。

是否更省电需要实际测量子进程次数、CPU、内存和唤醒，不能由 Swift/Electron 技术栈直接推出。

### 4.4 有界定制与导出——按需要增加

Token Monitor 可以组合图标、双行数据、进度条、百分比、重置时间等，并进行排序和预览。这套编辑器的自由度很高。[菜单栏布局模型](https://github.com/Javis603/token-monitor/blob/631c25cb4947bd7a75aebf5997bbeadd33cc9c98/src/shared/trayLayout.js)

Codex TouchBar 首先只需两三套预设，例如标准双行数值、双行数值加微型条；保持 5H/周都可见并右对齐，全部使用剩余口径。快捷操作页已经有四槽预览，可复用其“先预览、再应用”的交互。完整拖拽布局编辑器收益不足。

CSV 导出只导出现有额度观测和采样时间，也有一定价值；它是本地复盘功能，不需要跟随竞品建设跨设备成本中心。

## 5. 界面借鉴：保留骨架，调整信息层级

### 5.1 Agent HUD：借鉴逐层展开和注意力分配

屏幕边缘的 Simple 模式以小图标、环形状态构成入口；悬停后展开详细数据。请求面板把需要处理的事项排在前面，展开项才展示具体操作。其 HUD 文档还明确区分状态摘要、卡片文字层级和统计窗口。[HUD 交互规则](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/docs/hud.md)、[Simple 模式演示](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/docs/videos/simple-mode-tour.zh-CN.webp)、[请求界面](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/docs/screenshots/approvals.webp)

对应本项目的三层：

- 菜单栏和 Touch Bar：一眼读取两项剩余额度；Touch Bar 保留四个固定操作。
- 点击后的额度面板：剩余、距重置、新鲜度、短期变化。
- 独立历史窗口：时间范围、实测点、空档和回升解释。

不建议移植刘海光晕、持续活动动画和小机器人。它们是 Agent HUD 的品牌表现；Touch Bar 的横向空间和直接触控场景更适合清楚的文字、细条和短暂反馈。若未来真的获得可靠任务状态，可讨论小标记与“返回会话”，但当前前台检测不能说明 Agent 正在工作，也不能拿刷新动画冒充工作状态。

### 5.2 Token Monitor：借鉴数据对齐和上下文相邻

从首页和额度页截图可见，它把窗口名称、剩余百分比、进度条、重置倒计时放在同一个紧凑分组内，时间/设备/账户信息用较弱层级；首页再用微型趋势与活跃图提供概览。[首页截图](https://github.com/Javis603/token-monitor/blob/631c25cb4947bd7a75aebf5997bbeadd33cc9c98/.github/assets/home-view.png)、[额度页截图](https://github.com/Javis603/token-monitor/blob/631c25cb4947bd7a75aebf5997bbeadd33cc9c98/.github/assets/limits-view.png)

可借鉴对齐、紧凑分组和按需展开。不宜复制整页大 token 总量、多个分组页面、重玻璃透明效果或品牌色额度条：本工具主任务是判断剩余额度，四档风险色比供应商品牌色更有用。

### 5.3 当前面板的具体调整

当前已经有圆角卡片、套餐标签、等宽数字和进度条，不需要重做视觉语言。优先处理以下六点：

1. **让数值含义显式化。** 将“87% + 已用 13%”改成“剩余 87%”。当前同一行显示互补数字，需要用户再次确认哪个是余额，也与“所有显示额度使用剩余百分比”的项目规则不完全一致。
2. **相对时间优先。** 面板主显示“1 小时后重置”，完整日期放次级详情。Touch Bar 已有短倒计时，这里是统一表达，不是从零增加。
3. **将新鲜度移出拥挤标题行。** 标题保留名称、套餐标签、刷新入口；底部用“30 秒前更新”。比“在线”更准确地表达一次成功查询，不暗示持续连接。
4. **每卡仅增加一行近期变化。** 先用文字或无坐标微型趋势，点击进入已有曲线。没有连续样本时显示“记录不足”，不补画平滑历史。
5. **正常与异常状态分别设计。** 正常时仅弱提示更新时间；失败时保留上次数字，明确标注“旧数据 · 上次成功时间”，同时隐藏趋势估算。四档颜色仍表达该次读数的余额区间，另用文字说明新鲜度。
6. **降低低频入口权重。** 额度曲线与设置是主要入口；退出可以留在右键菜单或次级更多菜单。积分为零时可以考虑收进可展开附加信息，重置机会非零或将到期时应保持可见。

Touch Bar 不加入完整曲线、会话列表或大面积动画；保留两卡四操作和系统 Control Strip，卡片轻点仍展开完整时间。颜色不能作为唯一提示，数值与状态文字要同时可读。浅色外观下黄色的可读性需要单独检查。

### 5.4 历史窗口只加能回答问题的摘要

保持现有剩余额度曲线与实/虚线含义，可在顶部增加“当前剩余、最近连续区段变化、最新成功记录时间”。Token Monitor 的全年热力图适合长期使用分析；本工具当前只有 48 小时/14 天的观测，不适合凭空延伸成年历或将采样次数当作使用强度。

图表中的“额度回升”继续保持描述性，不直接重命名成“周期重置”；余额升高可能有多种原因。

## 6. 不应直接照搬的能力

| 能力 | 原项目做法/价值 | 对本项目的影响 |
| --- | --- | --- |
| Codex 多账户与切换 | Token Monitor 管理账户并切换本机登录材料 | 其文档明确涉及 auth.json 与凭据写入，违反当前项目边界 |
| 会话审批与直接答复 | Agent HUD 展示命令、修改差异、问题及回应 | 需要 hook/IPC、会话与操作上下文；不能作为普通快捷按钮加入 |
| token、成本和回本倍数 | 依赖本地日志、模型计价或额外数据源 | 额度百分比不足以推导 token，更不能将 API 估值当订阅实际账单 |
| 第三方重置预测 | Token Monitor 可接 codex-resets.com | 属于外部预测信息，不是官方额度或本地消耗速度外推 |
| 远程同步与移动端 | 对跨设备用户有价值 | 改变本地工具定位，增加传输、身份、部署与维护范围 |

[Token Monitor Codex 数据源与切换说明](https://github.com/Javis603/token-monitor/blob/631c25cb4947bd7a75aebf5997bbeadd33cc9c98/docs/providers/codex.md)、[第三方预测实现](https://github.com/Javis603/token-monitor/blob/631c25cb4947bd7a75aebf5997bbeadd33cc9c98/src/electron/providers/codex/resetForecast.js)、[Agent HUD 数据访问说明](https://github.com/jazzenchen/agent-hud-open/blob/376e9d6af2e47cccf0ec90c33f94659e48644ca2/docs/data-access.md)

补充区别：Agent HUD 的 Codex 额度也通过已安装 app-server 获取，但其整体实现还会读取登录时间和账户标识。只能复用适合的计算/呈现思路，不能把其整个数据访问层视作符合本项目政策。

## 7. 建议实施顺序与验收

| 阶段 | 范围 | 验收重点 |
| --- | --- | --- |
| 第一阶段 | 剩余口径、相对时间、新鲜度布局、异常态 | 首次使用无需解释就能区分余额/重置/旧数据；两档外观与实体 Touch Bar 可读 |
| 第二阶段 | 近期观测变化、局部趋势、重置到期提醒 | 缺样本不推断、跨空档不假装连续、提醒不重复、失败查询不确认恢复 |
| 第三阶段 | 可选智能刷新、趋势预警、少量布局预设 | 尊重刷新设置、没有重叠请求、无后台延期；记录误报与查询成本 |
| 后置研究 | 任务状态与返回会话 | 先验证受支持的数据来源，明确新增隐私范围，再决定是否做 |

实现入口：面板与文案在 `PanelController.swift`、`QuotaCardView.swift`、`Formatting.swift`；摘要数据复用 `UsageHistory.swift` 与 `UsageMonitoringModels.swift`；刷新策略落在 `RefreshPolicy.swift` / `QuotaRefreshTimer.swift`；菜单栏和 Touch Bar 沿用 `UsageIcon.swift` / `TouchBarController.swift`。不必为了界面借鉴把 AppKit 改写为 SwiftUI 或 Electron。

后续若实施，应运行现有构建与自测，使用隔离设置和假通知做 UI 检查；实体 Touch Bar 验证双卡、四槽、系统控制和前台切换。本次调研未执行产品构建或安装。

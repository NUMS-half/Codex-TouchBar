# Free、Go、Plus 与多档 Pro 账号兼容性审查

> 实施状态（2026-10-19）：已按用户确认的最小改动方案完成适配。下文初始审查中的“当前代码”和问题复现指实施前基线；文末“实施结果与最终验证”记录修改后的行为。原始证据予以保留，不能把旧审查程序中确认缺口的断言当作修改后的验收标准。

审查日期：2026-10-19（Asia/Shanghai）

审查基线：当前仓库 `0b042a9` / v2.2.2；审查开始时工作区干净。

本机已安装包声明版本：`~/Applications/CodexTouchBar.app` v2.2.1。本报告的可执行验证针对当前仓库源码，未重新安装应用；对照 v2.2.1 标签后，窗口解析、套餐标签映射、缓存和重置到期时间沿用的核心逻辑一致。未验证已安装二进制与该标签的可复现构建关系。

## 结论

**当前代码没有 Plus 专属的登录或套餐准入判断。只要官方 app-server 成功返回可识别的 5 小时／每周窗口，Free、Go、Plus 以及 Pro 家族的百分比计算、菜单栏和 Touch Bar 显示可共用现有逻辑。但目前不能宣称所有套餐已完整兼容。**

主要缺口是套餐名称映射、缺失字段的含义、非标准窗口、额外额度池以及切换套餐／账号时的状态隔离。真实 Free、Go、Pro 100／200／500 登录后的接口可用性与实际返回结构，尚未用对应账号验证。用户已有的 Plus 使用结果是人工反馈，不是本轮跨套餐实测。

本应用展示的是 Codex app-server 的额度，不是 ChatGPT 各聊天模型、图片、语音等功能的全部限制。套餐提供某项 ChatGPT 权益，不等于本应用能读取该项权益的配额。

## 官方套餐与协议依据

以下信息均为本轮打开官方页面核实，价格为官方页面列出的美元月价，不推断地区定价和税费。

| 个人套餐 | 官方月价 | 与本次审查有关的事实 |
| --- | --- | --- |
| Free | $0 | 官方 Codex 定价页包含该套餐；桌面使用受逐步开放影响 |
| Go | $8 | 官方 Codex 定价页包含该套餐；桌面使用受逐步开放影响 |
| Plus | $20 | 有扩展 Codex 用量 |
| Pro 100 | $100 | Pro 的三种当前在售月度档位之一 |
| Pro 200 | $200 | 高于 Pro 100 的用量；部分旧订阅有过渡安排 |
| Pro 500 | $500 | 三档中最高的包含用量，并提供 Ultrafast 权益 |

来源：[官方 Codex 定价](https://learn.chatgpt.com/docs/pricing)、[ChatGPT 个人套餐](https://chatgpt.com/pricing/)、[About ChatGPT Pro tiers](https://help.openai.com/en/articles/9793128-about-chatgpt-pro-tiers)。Pro 200 符合资格的旧订阅可保留旧包含用量至 2026-10-29；这不是一个应由本地写死倍率计算的独立套餐。

从本机 ChatGPT 自带的 `codex-cli 0.163.0-alpha.10.2` 导出了 JSON Schema，只生成协议文件，未发起登录或读取额度请求。其 `PlanType` 包含：`free`、`go`、`plus`、`pro`、`prolite`、`promax`，另有组织与教育类别。

官方公开源码对这些枚举的显示名为：`free → Free`、`go → Go`、`plus → Plus`、`prolite → Pro`、`pro → Pro (More)`、`promax → Pro (Max)`。来源：[OpenAI Codex 的 KnownPlan 定义](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/auth.rs)。这里确证的是枚举和官方显示名；商业价格与原始枚举的对应关系没有通过真实各档账号逐一验证，因此本报告不把原始枚举直接强制改写成价格标签。

[官方 app-server 文档](https://learn.chatgpt.com/docs/app-server)明确说明：`rateLimits` 是兼容旧客户端的单额度池视图；`rateLimitsByLimitId` 是多额度池视图；`planType`、积分信息、重置机会信息可由服务端按可用情况提供。官方示例还包括 15 分钟和 60 分钟窗口，不能假定所有合法返回都有 5 小时和每周窗口。**这些示例不证明 Free 或 Go 必然使用相应时长。**

## 分套餐判断

| 套餐／协议值 | 当前名称显示（离线执行真实视图代码） | 标准 300／10080 分钟窗口 | 可下的结论 |
| --- | --- | --- | --- |
| Free / `free` | `Free` | 正确显示剩余 80%／60% | 解析兼容；真实账号是否返回这些窗口待验证 |
| Go / `go` | `go` | 正确显示剩余 80%／60% | 解析兼容；名称大小写未规范化，真实返回待验证 |
| Plus / `plus` | `Plus` | 正确显示剩余 80%／60% | 代码验证通过；已有用户日常使用反馈 |
| Pro 家族 / `prolite` | `prolite` | 正确显示剩余 80%／60% | 不会因枚举被拒绝；显示名不符合官方名称 |
| Pro 家族 / `pro` | `Pro` | 正确显示剩余 80%／60% | 额度解析兼容；没有展示官方 More 区别或价格档位 |
| Pro 家族 / `promax` | `promax` | 正确显示剩余 80%／60% | 不会因枚举被拒绝；显示名不符合官方名称 |

三个 Pro 商业档位无需在本地按价格或固定倍率换算百分比。当前以服务端 `usedPercent` 计算 `remainingPercent` 的方向正确；不同账号、模型、速度和过渡政策应继续由服务端决定。

## 已确认的问题

### P2：无法识别的窗口被解释成“当前方案未提供”

位置：`Sources/CodexTouchBar/Models.swift:114-115,171-188`，`Sources/CodexTouchBar/QuotaCardView.swift:115-123`。

解析器只将 240...360 分钟归为 5H、8640...11520 分钟归为每周。输入合法的 15／60／1440 分钟窗口，或协议允许的空时长，窗口会变成 `nil`。界面继而展示 `N/A` 和“当前方案未提供”；历史与提醒也收不到该窗口的观测值。未返回窗口、返回其他窗口和套餐不提供额度，并非同一事实。

最小改进：保持两张既有卡片布局，使用中性的“未返回可识别的此类额度”等状态文案，区分尚未读取和已读取但不可分类。若以后扩展其他时长，应显式建模，不能把它们塞进 5H。当前分类范围还会将 4／6 小时当成 5H、6／8 天当成每周，建议另行明确精确时长契约。

### P2：Go 和新增 Pro 枚举没有用户可读的名称映射

位置：`Sources/CodexTouchBar/PanelController.swift:53-59`。

名称字典只有 `free`、`plus`、`pro`。原始 `go`、`prolite`、`promax` 被直接输出，六种枚举不会导致崩溃，但新 Pro 类型会暴露内部标识。服务端只给 `pro` 时，本地也不能推断其旧额度资格或商业档位。

最小改进：参考官方枚举显示名统一映射；未知值保留可读回退。不要从 `limitName` 猜订阅档位，该字段在协议中表示额度池名称。

### P2：缺失的重置机会信息显示成确定的 0 次

位置：`Sources/CodexTouchBar/Models.swift:140,157`，`Sources/CodexTouchBar/PanelController.swift:341`。

官方允许 `rateLimitResetCredits: null`，但当前 `availableCount` 解析失败或缺失都会回退 `0`，最终显示“可用重置：0 次”。离线已复现。这会让不返回该字段的账号看起来已确定没有重置机会。

最小改进：保留“未知”和“已知为 0”的区别，未知时在现有详情行显示占位或未提供说明；提醒继续要求明确大于 0。

### P2：切换套餐后可能沿用旧套餐的重置到期时间

位置：`Sources/CodexTouchBar/UsageStore.swift:72-92`。

普通刷新不请求重置明细时，只要新旧 `availableResetCredits` 相同且旧到期时间未过期，就沿用旧到期时间，没有比较 `planType` 或 `limitName`。已复现 Plus 快照有 1 次机会和到期时间，随后 Pro 快照也是 1 次但明细未知，界面状态仍携带 Plus 的到期时间。这会影响到期显示，并可能影响后续提醒。

最小改进：作用域变化时不要沿用旧明细；新作用域到期时间未知就保留未知。即使同一套餐，次数相同也不严格证明是同一张重置机会；需要到期信息时应重新读取明细，不能用次数相等替代身份或版本判断。

### P2：同套餐账号切换可被误判为同一账号的额度变化

位置：`Sources/CodexTouchBar/UsageMonitoringModels.swift:18-32,162-180`；共享缓存位于 `Sources/CodexTouchBar/UsageStore.swift`。

观测作用域只比较套餐、窗口时长和额度池名称。用合成的账号 A（Plus，剩余 80%）与账号 B（Plus，剩余 5%）连续生成快照，解析后账号边界被丢弃，低额度状态机会生成一次跨账号的下降提醒。历史也没有账号隔离依据。切换到不同套餐时已有部分作用域保护，但同套餐账号无法靠 `planType` 区分。

这是切换场景的问题，不意味着长期只用同一账号会出现该现象。修复必须遵守项目“不持久化账号身份”的边界：可设计会话级切换信号和重建提醒基线，或明确提供用户触发的会话重置路径；不能为了隔离历史去读取凭据或把身份加进缓存。本轮未实现该设计。

## 功能边界与证据不足项

- **多个额度池：** 固定优先 `rateLimitsByLimitId["codex"]`，否则用 `rateLimits`，符合当前仅展示基础 Codex 两窗口的方向；但不会展示其他模型／功能的额度池。合成的额外池已耗尽时，基础池仍可显示 80%，不能把基础池百分比理解为全部模型都可用。未证明某个 Pro 商业档位必然触发该结构。
- **稀疏元数据：** 选中的 `codex` 池缺少套餐信息时，即使旧单池有 `planType`，也不会合并，套餐标签可能隐藏。协议允许字段为空，不能因此断言登录失败。合并前应确认两个视图语义一致。
- **空快照：** `{ "rateLimits": {} }` 能被接受为成功读取，并替换旧窗口；`UsageStore` 标为 `.live`。这是合法的“无已知窗口”与“读取失败”没有细分的状态边界，不应把所有空窗口一概判为网络错误，也不应悄悄继续当作旧额度有效。
- **额度与使用许可：** 新协议还包含 `ordinaryUsageAllowed`、`rateLimitReachedType`、`spendControlReached` 等信息，当前未消费。应用只能声称展示已知配额窗口，不能仅凭百分比推断模型当前一定可用。
- **客户端与权限：** `CodexExecutableResolver` 对所有套餐使用相同的 ChatGPT 内置可执行文件，App 不实现独立账号登录。需要已在被选中 CLI/app-server 所用的认证环境完成登录；“网页已登录”本身不是这一条件的证明。Free／Go 的桌面开放及额度读取权限仍需实测。
- **积分：** 当前字符串余额和 `unlimited` 能显示；`unlimited` 只表示积分状态，不代表所有配额窗口无限制。未使用 `hasCredits` 的情况应理解为积分信息不完整，不能由本地套餐价格推断余额。
- **测试覆盖：** 原 XCTest 与可执行自检有窗口顺序、缺失窗口、缓存过期及错误保留等测试，但没有六种套餐值的名称映射和跨套餐／同套餐账号切换覆盖。XCTest 命令本轮只报告编译完成，没有测试用例执行统计。

## 本轮验证

1. `swift test --disable-sandbox`：退出码 0，报告 Build complete；**未观察到 XCTest 用例实际执行**，不写成“全部单元测试通过”。
2. 当前源码构建出的 `.build/debug/CodexTouchBar --self-test`：退出码 0，解析边界、刷新策略、历史／提醒等可执行自检通过。
3. `.build/debug/CodexTouchBar --monitoring-ui-self-test`：退出码 0，界面与刷新管线自检通过；使用隔离偏好、临时数据和替代通知服务，没有发送真实通知。
4. 额外离线审查程序：将未修改的生产 Swift 文件与临时审查入口共同编译，使用合成快照执行解析器、实际套餐标签／配额卡视图、缓存合并和提醒状态机，**32 项行为断言通过**。其中 `REPRO`／`LIMITATION` 断言是确认缺口存在，不是确认产品完整兼容。
5. 导出的官方本机协议与日志保存在 `build/plan-compatibility-audit/`（已被仓库忽略）。`main.swift` 是审查入口，`audit` 是审查可执行文件，`results.txt` 是运行输出，`schema/` 是从本机 CLI 生成的协议文件。全部数据为合成样本，没有真实账号标识、任务或 JSON-RPC 响应日志。

UI 检查在沙盒中打印了 Launch Services／XPC 连接警告，但上述检查均完成并返回 0。本轮只核验离屏文本与现有 UI 自检，不构成各套餐真实登录、完整原生 popover 箭头或物理 Touch Bar 验收。

## 技能使用与变更范围

使用 find-skills 查找审查辅助能力，复用了项目已有的 `addyosmani/agent-skills@code-review-and-quality`。检索时该技能约 66.4K 安装；新增的 `obra/superpowers@verification-before-completion` 约 244.1K 安装，来源仓库超过 100 stars，读取内容后用于要求结论附实际运行证据。安装命令在本仓库执行：

```sh
npx skills add obra/superpowers --skill verification-before-completion --agent codex -y
```

安装结果已由 `npx skills list --agent codex --json` 确认是 **project** 作用域，仅 Codex；目录为 `.agents/skills/verification-before-completion`，没有使用全局安装参数。未重复安装已有审查技能，未安装面向差异提交的 `mattpocock/skills@code-review`，因本任务审查的是当前整体行为。

本轮没有修改 `Sources/` 或 `Tests/`，没有改变 UI 设计、登录状态或已安装应用，没有提交或发布。新增此报告、项目级验证技能及被忽略的本地审查材料。

## 建议处理顺序

先修正套餐显示名、缺失字段文案／数据类型和跨套餐到期时间沿用，并增加可执行的协议样本检查；这些可以沿用当前视觉设计。随后明确基础额度池的产品语义与账号切换会话策略。最终用各档真实账号补齐“app-server 可读取 → 实际字段 → 菜单栏／popover／Touch Bar → 提醒和历史”的端到端验收，再对外声明全套餐兼容。

## 实施结果与最终验证

已执行用户确认的范围：保留 5H／每周两张卡，使用稳定套餐家族名，同套餐不同账号隔离另行处理。没有套餐价格、用量倍率或某套餐必须／不得有 5H 的判断，也没有新建配置页、规则服务或历史表。

| 原问题／需求 | 实施后行为 |
| --- | --- |
| 非标准窗口误分类／文案过度推断 | 只精确识别 300／10080 分钟；未读取显示“尚未读取额度”，缺失对应窗口显示“未提供此窗口数据”，数值为 `—` |
| 套餐名称随档位变化 | Free／Go／Plus 规范大小写；已知 Pro 类型和 x5／x20 旧名称统一显示 Pro；原始类型可悬停查看，未知名称回退原文并截断长文本 |
| 未知重置机会被表示为 0 | `availableResetCredits` 改为可选；缺失、null、负数为未知，显示 `—`；明确 0 与正数分别正常显示 |
| 次数相等沿用旧到期时间 | 已删除合并逻辑，成功读取直接采用新快照；打开面板期间的现有刷新会附带明细，手动请求和到期提醒条件继续生效 |
| 窗口取消／恢复产生提醒误判 | 成功快照进入监控时清理缺失窗口的基线，恢复首条仅建基线；失败读取不进入该路径，旧值和判断基线保留 |
| 历史与账号隐私 | 继续只采集实际窗口，不补虚构值、不持久化身份；同套餐账号隔离仍未实现，属于已确认的后续范围 |

主要运行时代码改动位于 `Models.swift`、`Formatting.swift`、`PanelController.swift`、`UsageStore.swift` 及现有刷新／提醒入口。低额度和恢复判定算法、基础额度池选择、刷新触发门控、数据库结构、Control Strip 私有 API 保护保持原有实现。新增合成样本放在独立的 `PlanCompatibilityDiagnostics.swift` 和 `PlanCompatibilityUIDiagnostics.swift`，没有放入领域策略文件。

旧缓存中的整型次数保持可读；未知次数可完成新的缓存往返。旧缓存已有的 0 无法追溯其来源，继续作为缓存记录展示，下一次成功读取由本轮解析语义覆盖。原始套餐字段仍保存在既有快照和历史字段中，显示用的 Pro 家族名不参与作用域比较。

最终检查结果：

| 检查 | 实际结果 |
| --- | --- |
| `./build.sh` | 成功；测试目标编译、release 构建、应用组装及固定本地证书签名均完成 |
| `codesign --verify --strict build/CodexTouchBar.app` | 在允许访问系统信任服务的环境中退出 0 |
| 构建包 `--self-test` | 退出 0，新增套餐兼容检查与原有自检全部实际执行通过 |
| 构建包 `--monitoring-ui-self-test` | 退出 0，新增名称／悬停／缺失窗口／重置明细／失败读取及提醒管线检查通过，原有导航、图表和材质检查通过 |
| 构建包 `--settings-self-test` | 退出 0，Touch Bar 可见范围／等宽卡片／间距及设置界面检查通过 |
| Debug 构建 `--panel-motion-self-test` | 退出 0，并打印完整成功标记；原生弹出面板、展开／返回／反向操作无裁切，顶部漂移 0pt；新增缺失窗口与长名称检查通过 |
| 回归检查有效性 | 临时反转缺失窗口清理条件，新可执行自检按预期失败；源码逐字节恢复，随后完整构建及自检通过 |
| 代码审查与格式检查 | 复查正确性、可读性、架构、隐私和性能；`git diff --check` 通过，未发现本次范围内的阻断问题 |

`swift test` 在此工具链中仍只输出编译完成，没有实际 XCTest 用例执行统计。新增四项 XCTest 会调用与 `--self-test` 相同的检查函数；本报告以可执行自检和 UI 自检的真实运行结果证明行为，不将编译成功计为 XCTest 全部执行通过。

沙盒无法完整访问系统图形／证书信任服务：已签名 GUI 自检在沙盒中曾退出 134，签名验证曾返回 `CSSMERR_TP_NOT_TRUSTED`。允许系统服务访问后，原签名未变且验证及自检均通过。没有通过修改签名或降低证书要求绕过问题。

已人工查看以下完整原生截图（包含箭头），浅／深外观的主体材质连续，卡片尺寸与现有风格一致，长名称在标签内截断，未挤出刷新按钮：

- [仅周额度：浅色](../../build/panel-motion/native-plan-weekly-only-NSAppearanceNameAqua.png)
- [仅周额度：深色](../../build/panel-motion/native-plan-weekly-only-NSAppearanceNameDarkAqua.png)
- [长名称：浅色](../../build/panel-motion/native-plan-long-name-NSAppearanceNameAqua.png)
- [长名称：深色](../../build/panel-motion/native-plan-long-name-NSAppearanceNameDarkAqua.png)

其他离屏样本位于 `build/monitoring-previews/plan-*.png`。反向验证日志位于 `build/plan-compatibility-audit/mutation-check.txt`。这些构建与诊断产物均被 Git 忽略。

没有调用安装脚本，没有提交或发布；`~/Applications/CodexTouchBar.app` 的可执行文件 SHA-256 仍为 `c34435a9c6d5377d60b8b590bf9fd4ed65c83065b188face21a581c694f955f2`，与初始审查一致。新构建位于 `build/CodexTouchBar.app`，版本号未做发布式递增。

尚待人工验收：各档真实账号登录后的 app-server 可读取性及实际窗口，以及物理 Touch Bar 上的系统控制区共存与前台切换。自动检查没有发送真实通知，也没有更换用户账号。本次完成的是基于返回数据的适配，不能据此声称各档真实账号已端到端实测。

# Apple Silicon 无 Touch Bar 适配实施记录

日期：2026-10-23。代码与可执行自检已完成；双硬件真机验收仍待完成。范围依据[已确认计划](../plans/2026-10-23-non-touchbar-support.md)。

## 结果与改动范围

无实体 Touch Bar、无法确认硬件状态或无可用呈现接口时，应用使用菜单栏额度监控，隐藏 Touch Bar 显示开关、专属刷新选项和快捷操作页。原有偏好和按钮配置保留，能力恢复后按原设置重新启用。仅支持 Apple Silicon（arm64）、macOS 14+。

主要产品改动集中在五个文件：

| 文件 | 改动 |
| --- | --- |
| `TouchBarSupport.swift`（新增） | 硬件三态、呈现能力和可选会话；无硬件不会创建控制器，重复更新复用实例，禁用或能力失效时清理 |
| `TouchBarSystem.swift`（新增） | 集中原有私有 API 包装，新增只读 DFR 状态检测；完整呈现与 Control Strip 均检查必要入口；提供假接口注入用于验证 |
| `AppDelegate.swift` | 启动、唤醒、打开设置时重新检测；按需创建控制器和设置窗口，额度推送只更新已经存在的硬件 UI |
| `TouchBarController.swift` | 保留 placement 0 及现有布局；仅在呈现路径接受请求后启动倒计时，隐藏时撤下实际创建的资源，重复操作不重复登记或清理 |
| `SettingsWindowController.swift` | 按能力生成可用页面，隐藏专属控件，延迟创建快捷操作编辑器；能力变化时安全回到通用页并保留草稿，关闭仍按原规则丢弃未保存内容 |

检测和会话代码独立于套餐、窗口、额度计算、缓存、历史及提醒算法。原工作区中的不同套餐适配改动保留；同一个快照在不同硬件模式下继续产生相同菜单栏值。此次不新增偏好键、数据迁移、网络服务或第三方依赖。

更新了 `README.md`、`AGENTS.md` 和 `docs/DEVELOPMENT.md`，明确 arm64 范围、无 Touch Bar 的设置行为、权限与验收边界。实施检查时 README 标明适配尚未包含在 v2.2.2 下载包；此次发布准备已将说明更新为 v2.3.0，详见[发布说明](../releases/v2.3.0.md)。

## 检测依据与实际验证边界

- Apple 的 [NSTouchBar 文档](https://developer.apple.com/documentation/appkit/nstouchbar) 未提供实体硬件检测的公开 API；[`isVisible`](https://developer.apple.com/documentation/appkit/nstouchbar/isvisible) 是显示资格，不代表实体设备存在。
- 参考 [Hammerspoon 扩展的原始实现](https://github.com/asmagill/hs._asm.undocumented.touchbar/blob/master/internal.m)，将 `DFRGetStatus` 的 0/2 视作无实体硬件、1/3 视作有实体硬件；缺失、负数及其他值视作未知。框架和符号均动态解析，不调用 `DFRSetStatus`、不创建模拟器。
- 本轮在当前 arm64 主机进行只读原型查询，得到 `DFRGetStatus = 1`。这证明了本机可取得该状态，不能替代另一台无 Touch Bar Mac 的检测验收。
- 私有接口存在及呈现调用已发出，都不保证系统实际上显示了内容。代码和报告均保留此区别。

## 实际执行的验证

最终验证针对 `./build.sh` 生成的签名应用执行，命令退出码均为 0，且逐项检查了自检成功标记。

| 检查 | 结果 |
| --- | --- |
| `./build.sh` | 调试/测试目标构建、release 构建和固定证书签名完成；没有临时签名回退 |
| `--self-test` | 新增硬件状态与会话检查通过；原有套餐、解析、历史、提醒、刷新策略检查通过 |
| `--settings-self-test --settings-preview …` | 新增假呈现接口、动态页面、偏好及草稿测试通过；原有按钮、布局、设置测试通过 |
| `--monitoring-ui-self-test` | 三种硬件模式下的相同请求、历史、低额提醒、过期快照与菜单栏值检查通过；原有套餐和图表检查通过 |
| `--panel-motion-self-test` | 实际原生 popover 检查通过；7 组导航轨迹无裁剪，窗口顶部漂移为 0 pt |
| `codesign --verify --deep --strict build/CodexTouchBar.app` | 通过 |
| `lipo -archs …/CodexTouchBar` | `arm64` |
| `git diff --check` | 通过 |

当前 Command Line Tools 不提供 XCTest 模块。新增测试沿用仓库的 `#if canImport(XCTest)` 约定，因此 `swift test` 的成功只表示目标构建成功，XCTest 用例本身在此环境被条件排除，没有实际运行。关键逻辑由上表的可执行自检执行，不能将其表述为 XCTest 通过。

原生 GUI 与固定证书验证使用允许访问 macOS 系统服务的执行环境。调试编译先因默认 module cache 不可写失败，改用项目已有的工作区 module cache 配置后正常；未更换工具链或签名身份。

测试使用隔离偏好、临时数据库、合成快照、假通知/登录项及假 Touch Bar 呈现接口。没有控制真实 ChatGPT 菜单、没有发送真实通知，也没有向实体 Touch Bar 发出测试呈现请求。

## 回归有效性与外观

临时将会话条件 `support.isUsable && enabled` 改成 `support.isUsable || enabled`，重新编译后运行基础自检，得到退出码 1，明确失败于“menu-only startup, refresh, foreground, sleep and exit never create a controller”。随后逐字节恢复源文件，完整重建并运行最终验证。这确认测试能捕获无硬件仍创建控制器的实际回归。

已检查无硬件模式的浅色/深色设置、支持模式及未知状态说明；控件保持在原窗口内，隐藏项由原有 stack 布局收拢。也检查了完整原生 popover 的浅色缺失窗口、深色长套餐名场景，箭头与主体材质连续，两张卡及按钮布局保留。

本地证据（构建目录已忽略，不作为源码提交）：

- `build/non-touchbar-audit/final-build.log`：最终构建及签名。
- `build/non-touchbar-audit/final-results.json`：六项最终应用验证的退出码；同目录各项 `.log` 保留成功标记。
- `build/non-touchbar-audit/mutation-check.txt`：错误条件被测试拒绝的证据。
- `build/non-touchbar-audit/settings-final/hardware-settings-*.png`：签名应用生成的硬件状态设置预览。
- `build/panel-motion/native-plan-*.png`：完整原生 popover 截图。

## 审查结论与后续验收

按正确性、可读性、架构、安全和性能五项审查，本次改动未发现阻断问题。探测集中在三个既有生命周期事件，没有新轮询或额度请求；不引入账号身份或凭据读取；用户配置与暂时能力状态分开。

仍需以下真实设备验收，不能以注入测试替代：

1. 无 Touch Bar 的 Apple Silicon Mac：首次启动、菜单栏、实际登录后的读取、缓存、历史、提醒设置及登录启动入口；无硬件专属入口与辅助功能授权弹窗。
2. 有实体 Touch Bar 的 Apple Silicon Mac：实际呈现、四按钮、两卡、睡眠恢复、切离 ChatGPT 后撤下和右侧系统 Control Strip。

上述实施检查结束时未提交、未发布、未安装；后续提交与发布见 v2.3.0 发布记录。已安装应用的可执行文件 SHA-256 在实施操作前后相同：`c34435a9c6d5377d60b8b590bf9fd4ed65c83065b188face21a581c694f955f2`。

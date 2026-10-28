# 开发与诊断

用户安装与使用见 [README](../README.md)。本文集中说明从源码构建、签名和诊断。

## 构建

项目使用Swift Package Manager和AppKit，仅支持Apple Silicon（arm64）、macOS 14或更高版本，没有第三方包依赖。

```bash
./tools/setup-local-signing.sh  # 首次配置本机签名身份
./build.sh                     # 构建应用到build/CodexTouchBar.app
./install.sh                   # 构建、安装到~/Applications并启动
```

安装脚本只替换本工具，并检查应用标识和签名身份。构建与发布目标为arm64，不安排Intel兼容或Universal安装包。

## 固定签名

辅助功能授权与代码签名身份关联。临时签名的身份随程序变化，更新后可能出现系统开关已开启、操作仍被拒绝的问题。

本机设置脚本创建专用钥匙串，仅添加当前用户对这张证书的代码签名信任。后续构建复用同一证书；签名失败不会退回临时签名。签名目录位于：

```text
~/Library/Application Support/com.wyx.CodexTouchBar/Signing
```

请妥善备份，不要删除、分享或提交专用钥匙串、私钥及密码。构建者也可通过`CODEX_TOUCHBAR_SIGNING_IDENTITY`指定自己的证书，必要时通过`CODEX_TOUCHBAR_SIGNING_KEYCHAIN`指定钥匙串。

意外更换证书会使安装停止。确需迁移时可设置`CODEX_TOUCHBAR_ALLOW_SIGNER_CHANGE=1`，并重新授权辅助功能。公开分发建议使用Developer ID Application签名与公证，详见 [发布指南](../RELEASING.md)。

## 可执行诊断

```bash
build/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --self-test
build/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --settings-self-test
build/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --monitoring-ui-self-test
./tools/check-signing.sh
```

- `--self-test`实际执行解析、历史、提醒等逻辑检查。
- 设置与监控界面自检使用隔离偏好、临时数据库和通知／登录项替身，不修改用户真实设置。
- `check-signing.sh`确认更新后的代码满足旧版签名身份，并拒绝被篡改的程序或同标识的临时签名程序。
- Command Line Tools环境可能只构建XCTest目标；请以实际执行的自检结果为准。

原生菜单面板检查需要可交互的桌面。通过macOS正常启动路径运行时，应显式指定输出目录，避免启动工作目录为`/`时写入失败：

```bash
open -n -W --stdout "$PWD/build/panel-motion.log" --stderr "$PWD/build/panel-motion.stderr.log" \
  build/CodexTouchBar.app --args --panel-motion-self-test --panel-motion-output "$PWD/build/panel-motion"
```

检查结束后读取日志中的`Real menu panel motion self-test passed`；`open`退出码本身不代表应用自检通过。测试期间会显示使用隔离示例数据的原生弹出面板，点击其他窗口会关闭临时面板并使检查失败。

若系统 ScreenCaptureKit 调用未返回，可在此命令的参数末尾加入 `--native-frame-render`，使用 AppKit 窗口框架视图继续检查几何和裁切。该替代方式可能缺少合成器绘制的箭头及材质背景，不能用它宣称通过最终屏幕合成视觉验收；应在报告中记录截图方式与剩余项目。

### 无 Touch Bar 模式

- `TouchBarSystem.detect()`只读查询动态解析的`DFRGetStatus`，状态0/2表示未检测到实体硬件，1/3表示存在，符号缺失或其他值表示未知。这是私有接口约定，需在真实硬件与支持的系统上验收。检测不调用`DFRSetStatus`。
- `TouchBarSupport`分别表示硬件与呈现能力；`TouchBarSession`只有在硬件已确认、接口可用、用户开启且需要显示时才创建控制器。无硬件时额度读取、历史、提醒和菜单栏不经过硬件路径。
- 启动、唤醒和打开设置重新检测；检测结果不持久化，也不改写Touch Bar偏好。设置页根据同一支持状态隐藏专属入口，编辑器按需创建。
- `--self-test`覆盖状态转换、接口存在但无硬件、控制器惰性创建与恢复。`--settings-self-test`用假的呈现接口验证清理、计时器及动态设置页；`--monitoring-ui-self-test`比较三种硬件状态下的额度查询、历史、提醒和菜单栏值。
- 保存浅／深色设置预览：`build/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --settings-self-test --settings-preview build/hardware-previews/shortcuts.png`。这些自检不呈现实物Touch Bar、不请求辅助功能权限、不发送真实通知。
- 硬件真机验收需分别覆盖无Touch Bar和有Touch Bar的Apple Silicon Mac；模拟状态只验证代码分支。实施记录见[无Touch Bar适配审查](reviews/2026-10-23-non-touchbar-support.md)。

真实通知验收需先在设置中开启提醒并允许系统通知，再显式运行：

```bash
~/Applications/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --notification-self-test
```

该命令只在已授权时发送一条标明“测试”的通知，不申请权限或修改提醒开关。

## 用户可能关心的数据边界

- 运行时只通过本机`codex app-server --stdio`读取额度，不读取`auth.json`、登录钥匙串或账户令牌。
- 不直接请求ChatGPT私有HTTP接口，不记录原始响应、聊天内容或账户身份。
- 历史使用系统SQLite；每种额度每分钟保留最后一次成功查询，分别保留48小时和14天。
- 失败查询与缓存加载不产生新采样；历史写入失败不影响现有额度显示。
- 提醒规则与系统通知发送分离，去重状态持久化；设置变更不重启刷新计时器。

### 可选会话速度

菜单栏与 Touch Bar 共享按需创建的 `SessionTPSService`；菜单栏由通用设置开关控制，Touch Bar 启用状态从快捷操作的 `TouchBarSlotAction.sessionTPS` 派生。`UsageStore.sessionTPS` 仅留内存，不进入额度缓存或历史。Touch Bar 使用 `⚡ 243 tok/s`，菜单栏将 `⚡️243` 与 `tok/s` 分为上下两行。额度面板不再包含 TPS。

`StatusUsageReadoutView` 不显示应用图标，所有文字统一使用 `NSFont.systemFont(ofSize: 9, weight: .semibold)`，不附加等宽数字字体特性；H／W 同列右对齐，剩余额度共同右对齐。普通系统字体数字宽度不同，TPS 列只为当前位数预留必要数字空间，并与 tok/s 取较宽值，避免 11→88 引起宽度变化；额度列取当前两行百分比的较宽值，H／W 到数值间距 2pt。没有六位速率或 100% 的固定预留；同位数速率保持稳定，开关或实际位数变化时才调整约束和状态项宽度。验证见[菜单栏紧凑修订](reviews/2026-10-28-tps-menubar-spacing.md)。Touch Bar TPS 占用任意一个快捷操作槽位，禁止自定义名称与点击动作；保存／取消沿用快捷操作草稿机制。5H 倒计时、卡片、四个槽位和 Control Strip 布局保持不变，控制条回退仅显示额度。硬件不可用或总开关关闭时，仅硬件配置不会继续观测；切离 Codex 暂停窗口轮询并保留计算状态。

菜单栏 `sessionTPS.menuBar.v3` 显式值优先，否则保留旧 panel.v2，再兼容 menuBar/composer.v1；显式关闭不会被旧开关重新开启。旧 Touch Bar 独立开关停用，不自动覆盖用户任何快捷操作；用户在快捷操作中选择 TPS。已移除额度面板 TPS 标签、输入框浮层、输入框 AX 定位器、辅助功能树开关、位置和文字外观控件。验证见 [菜单栏两行布局](reviews/2026-10-28-tps-menubar-layout.md)。

`thread-stream-following-changed` 表示长期订阅，并非当前可见路由。`SessionVisibleConversation` 每 500ms 检查唯一可见的 Codex 原生窗口标题；标题在只读 SQLite 中按有效 name/title 精确唯一匹配，并验证存在对应本地订阅。同一 IPC source 的订阅用集合保留；重名、未知或无可读标题时清空结果，返回缓存视图仍重新绑定日志。仅在 TPS 观测启用时运行该计时器，停止时清理。已有窗口标题访问不可用时仅使用已授权 AX 读取窗口标题；无树遍历、正文读取或自动授权。文件和连接回调用 generation 隔离。验证见 [缓存对话切换修复](reviews/2026-10-28-tps-cached-conversation-switching.md)。

性能修订：窗口采样仅在 Codex 前台运行，订阅批次以 50ms 合并；暂时读取失败最多宽限 1.5s，已确认不同页面或歧义立即清空。`SessionTitleLookup` 复用只读连接／语句，最多缓存 8 个标题映射，以 `PRAGMA data_version` 和数据库 inode 失效。最近 4 个 reader 保存数字状态与文件偏移，切出时丢弃 partial 原文并回退偏移；回访验证 inode/size/mtime，不变时零内容读取，追加仅增量，同长度改写／截断／替换重新恢复。计时并集和 token 汇总只在新增对应记录时更新，读取快照不排序。`UsageStore.onSessionTPSChange` 只更新 TPS，MainActor 渲染路径不查询系统窗口。验证见 [闪烁与性能审查](reviews/2026-10-28-tps-performance-review.md)。

数据源仍限定当前用户的 Codex IPC、只读 SQLite 索引和 ID 匹配的根对话日志。计时合并 Reasoning/AgentMessage 区间；现代与旧用量的历史累计起点独立跟踪，本轮优先现代用量并与自身响应 ID 去重统计核对，在响应边界确认测量。完成后保留最终值，迟到统计可修正，下一轮开始清空。损坏或未知模型类别使本轮失效并撤销累计基线。验证见 [结束保留修复](reviews/2026-10-28-tps-completion-retention.md)。实现依据与 MIT 声明见 [第三方说明](THIRD-PARTY-NOTICES.md)。

```bash
build/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --session-tps-self-test
build/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --session-tps-ui-self-test
```

自检使用合成数据、隔离偏好和假的 Touch Bar 呈现接口，覆盖开关、旧配置迁移、硬件门控、主卡片及控制条回退；不会呈现真实 Touch Bar。可选 `--session-tps-live-probe` 只读本机当前对话，输出状态和速度，不创建浮层、不改用户设置或发送模型请求。

原生面板诊断可增加 `--session-tps-panel-preview` 显示合成的243 tok/s，配合 `--panel-motion-preview` 暂留窗口以供检查；预览窗口 ID 与进程 ID 写入该诊断输出目录的 `preview-window.json`，仅用于限定捕获本次测试窗口。

## 文档图片

[docs/images](images)中的图片来自本应用的原生离屏界面渲染，使用隔离的示例额度和设置；不是用户账户的实际用量。

### 额度刷新策略

- `QuotaRefreshPolicy`集中定义启动、面板打开、前台切换、唤醒、前台计时器、后台计时器和Touch Bar刷新七种可配置入口；`AppDelegate.requestRefresh`在执行前统一检查策略与睡眠状态。菜单栏刷新图标和右键刷新属于始终允许的手动请求。
- `Preferences.refreshPolicy`以版本化记录保存，缺少配置时保留原有前台间隔，并默认开启七种入口；后台默认300秒。刷新偏好使用独立通知，只重建计时器，不立即查询；显示、提醒和快捷操作偏好不会重启刷新计时器。
- 每次策略允许的额度查询都在同一次请求中包含重置机会详情，避免普通刷新清掉最近到期时间；不增加查询次数，也不绕过关闭的刷新入口。`UsageStore`正在查询时合并请求。历史维护、曲线重绘和设置界面更新只处理本地数据，不请求额度。
- `--self-test`验证策略门控、手动入口、计时器选择、迁移、持久化和异常记录；`--settings-self-test`使用隔离偏好逐个操作七种开关和两个间隔控件，验证即时保存与浅色／暗色布局。


## 维护约定

- 核心规则与诊断分开：刷新规则位于`RefreshPolicy.swift`，实际可执行检查位于`RefreshPolicyChecks.swift`；UI自检共享`UIDiagnosticSupport.swift`，不让设置测试依赖曲线测试的实现。
- App标识和数据目录由`ApplicationIdentity.swift`统一维护。变更标识、偏好键名或文件名需要明确迁移方案；此次整理保持现有值不变。
- 刷新间隔列表及显示名称由刷新策略统一定义，偏好层只负责保存。各类偏好通知保持独立，同值写入不重复触发Touch Bar更新。
- `QuotaRefreshTimer`仅在前后台类别、间隔变化或显式要求时重建。两个后台App之间的切换不得改变下一次查询时间；睡眠及退出取消计时器。
- 额度RPC按行处理，未完成行／完整行限制为4MiB；多条短消息可构成超过此大小的批次。超限作为无效响应处理，沿用最近成功快照。
- 代码质量审查与本轮验证记录见[2026-10-13审查记录](reviews/2026-10-13-code-quality.md)。

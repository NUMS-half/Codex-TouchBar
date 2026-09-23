# Codex TouchBar

一个面向个人使用的原生 macOS 菜单栏应用：在带实体 Touch Bar 的 MacBook Pro 上查看 Codex 的 5 小时与每周**剩余额度**。

## 功能

- 菜单栏使用紧凑双行布局，同时显示 `5H` 与 `周` 的剩余百分比；点击打开详情，右键显示快捷操作。
- Codex Desktop 位于前台时，在左侧显示两张 Touch Bar 额度卡；右侧亮度、音量与 Siri 等系统 Control Strip 保持可用。
- 启动、Codex 获得焦点、打开菜单和系统唤醒时会立即刷新；点击额度卡或菜单栏的“刷新”也可手动更新。
- Codex 位于前台时默认每 30 秒刷新，后台固定每 5 分钟刷新。可在详情中将前台自动刷新设为 30 秒、1 分钟、2 分钟、5 分钟或 10 分钟。
- 详情面板显示积分、可用重置次数及服务端提供的最近到期时间；异常提示保持紧凑，完整错误可展开查看。
- 额度、进度条和菜单栏数值统一按四色状态展示：红、橙、黄、绿。
- 支持登录启动、睡眠唤醒恢复、24 小时本地缓存与失效标记。
- Touch Bar 私有接口不可用时，自动退回紧凑 Control Strip 摘要；菜单栏功能不受影响。

## 要求

- macOS 14 或更高版本。
- 带实体 Touch Bar 的 MacBook Pro（菜单栏功能不依赖 Touch Bar）。
- 已登录 Codex Desktop / ChatGPT，并且其自带 `codex` 可执行文件可用。
- Swift Command Line Tools 或完整 Xcode，用于从源码构建。

## 构建与安装

```bash
./build.sh
./install.sh
```

`build.sh` 会运行测试目标、构建 release 应用、生成图标，并在 `build/CodexTouchBar.app` 输出 ad-hoc 签名的应用。`install.sh` 会退出旧进程，再安装到 `~/Applications/CodexTouchBar.app` 并启动新版本。

也可执行只读诊断：

```bash
build/CodexTouchBar.app/Contents/MacOS/CodexTouchBar --self-test
```

在实体设备上验收时，请确认：Codex 前台时额度卡显示且右侧系统控制仍在；切换到其他应用后系统控制立即恢复。

## 数据与隐私

应用仅通过本机 `codex app-server --stdio` 的只读 `account/rateLimits/read` 请求读取服务端额度。

- 不读取 `auth.json`、Keychain 或登录凭据。
- 不直接请求 ChatGPT 私有 HTTP 接口。
- 不记录原始 JSON-RPC 响应、任务内容或账户标识。
- 仅缓存界面展示所需字段，最长使用 24 小时；读取失败时保留旧值并标记为过期。

## 开发

项目使用 Swift Package Manager 与 AppKit，没有第三方依赖。

## 发布

当前版本为 `v2.0.1`。发布前请阅读 [RELEASING.md](RELEASING.md)：它说明如何生成带 SHA-256 校验文件的 arm64 应用压缩包、创建 Git 标签并在 GitHub 发布 Release。

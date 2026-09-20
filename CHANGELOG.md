# Changelog

本项目的所有用户可见变更记录在此文件中。

## [Unreleased]

- Refined the usage panel with a compact rounded presentation, larger detail text, and plan tags.
- Added a selectable automatic refresh interval for Codex foreground use.
- Enlarged the app icon motif to reduce unused whitespace.

## [2.0.0] - 2026-09-20

### Added

- 原生菜单栏双行额度显示、详情面板与登录启动开关。
- Codex Desktop 前台触发的双卡 Touch Bar 视图，以及 Control Strip 回退模式。
- 基于窗口时长的 5 小时和每周额度识别、24 小时展示缓存与失效状态。
- 四档额度颜色、应用图标、`--self-test` 诊断与脱敏解析测试。

### Changed

- 使用短生命周期 `codex app-server --stdio` 请求，读取完成或超时后回收子进程。
- Touch Bar 与右侧系统 Control Strip 并存；菜单栏使用紧凑右对齐的两行布局。

### Security

- 不读取凭据或 `auth.json`，不直接访问 ChatGPT 私有 HTTP 接口，也不持久化原始响应。

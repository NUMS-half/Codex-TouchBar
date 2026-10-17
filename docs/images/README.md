# 界面预览素材

这些PNG由本应用原生AppKit界面渲染，使用示例额度和隔离设置。图片不包含真实账户、聊天内容或登录信息。

- `app-icon.png`：项目现有图标，由`tools/render_app_icon.swift`生成。
- `menu-panel.png`：真实菜单栏详情面板，包含系统原生箭头与示例额度。
- `settings-general.png`：统一设置中的通用页。
- `settings-alerts.png`：可配置阈值的额度提醒页，暗色外观。
- `shortcut-editor.png`：快捷操作编辑区。
- `quota-history.png`：620×460紧凑图表页，带返回按钮、圆角渐变柱、刷新标记；5H默认近6小时/每柱10分钟，可切换近12小时/每柱15分钟，跨刷新空档沿用前值。

菜单面板与额度图表使用`--panel-motion-self-test`自身窗口捕获，顶部“UI检查”是临时诊断图标，不含真实账户数据。其他源预览由`--settings-self-test --settings-preview PATH`和`--monitoring-ui-self-test`生成。README中的取值仅用于展示，不代表应用默认设置。

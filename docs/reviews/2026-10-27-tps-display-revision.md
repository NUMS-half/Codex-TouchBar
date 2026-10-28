# TPS 显示位置修订与验证

日期：2026-10-27。遵照用户反馈修订；不提交、不发布。

## 后续修订：快捷操作槽位与面板样式

以下内容为当前行为，取代下文首次修订中的 Touch Bar 独立开关、5H 卡片 TPS 及 Control Strip 两行显示描述：

- Touch Bar 在「设置 → 快捷操作」中选择「当前对话 TPS」，占用所选的任意一个槽位。仅显示完整速度，点击无动作，不允许自定义名称。5H 卡片恢复倒计时；Control Strip 回退仅显示额度。
- 通用设置只保留额度面板 TPS 开关，并指引用户到快捷操作配置 Touch Bar。旧 Touch Bar 开关失效，不自动覆盖用户保存的任何快捷操作。移除最后一个 TPS 槽位即关闭该处观测，面板开关独立生效。
- TPS 使用原有快捷操作草稿、保存、取消和持久化机制。保存后即时重新计算观测需求并推送当前样本。
- 面板 TPS 与积分文字均为 13pt medium 系统字体、secondaryLabelColor；保留原位置与透明背景。
- 实际执行的界面自检覆盖：TPS 槽位配置往返、编辑取消、保存后重读、禁止命名、数据更新、点击无命令、现有四槽位尺寸、最大支持数值的完整宽度、移除槽位停止需求、硬件与前台门控、面板字体颜色一致。
- 通过隔离的真实原生面板截图检查字体颜色和完整箭头，见 `build/tps-slots-native/system-overview.png`；模拟 Touch Bar 渲染见 `build/session-tps-previews/tps-touchbar-NSAppearanceNameDarkAqua.png`。不代表真实硬件接受度已完成。
- 最终固定证书构建成功；签名应用的 `--self-test`、`--session-tps-ui-self-test`、`--settings-self-test`、`--monitoring-ui-self-test` 和严格签名检查均通过。真实面板过渡自检通过。XCTest 仍仅确认编译链接，实际行为结论来自上述自检。

## 当前行为

- 完整格式为 `⚡ 243 tok/s`；未知值显示 `⚡ — tok/s`。沿用模型响应结束后更新的测量口径。
- 菜单栏恢复原有两行额度。TPS 位于点击后额度面板的积分行右侧，保留原生材质、卡片及页脚布局。
- 移除输入框浮层及定位选项。独立跨进程浮层依赖窗口采样，且当前 Codex 没有暴露输入框辅助功能边界，无法保证与窗口同帧移动，因此不继续保留割裂体验。
- 通用设置改为「在额度面板显示 TPS」「在 Touch Bar 显示 TPS」两个独立开关。旧版任一显示开关启用时迁移为面板显示；Touch Bar 默认关闭。明确保存的新设置优先于旧值。
- Touch Bar TPS 在紧凑 5H 卡片右侧替换倒计时，点击卡片仍能查看重置时间。卡片、四个动作及系统控制区尺寸保持不变；Control Strip 回退保留两项额度，并增加第二行 TPS。
- 无可用硬件时隐藏 Touch Bar 选项并保留保存值；全局 Touch Bar 关闭时该项不可操作。仅 Touch Bar 开启时，硬件不可用或 Codex 不在前台不会继续观测。无需辅助功能权限。

## 验证证据

- `./build.sh` 成功，固定本地证书签名与严格签名检查通过。当前 Command Line Tools 环境的 XCTest 仅确认编译链接；不计作实际执行。
- 签名应用的 `--self-test`、`--session-tps-ui-self-test`、`--settings-self-test`、`--monitoring-ui-self-test` 全部实际执行通过。
- 覆盖四种独立开关组合、旧偏好迁移、新值覆盖、硬件/前台门控、观测生命周期与过期回调、完整格式、面板文本位置与边界、Touch Bar 主卡片与 Control Strip 回退、浅深色渲染。
- Touch Bar 使用注入的假 API，未在自动测试中展示真实硬件或发送真实通知。物理设备接受度仍待用户试用。
- 真实 NSPopover 的展开/返回/反向过渡及关闭重开检查：无控件裁剪，顶部锚点漂移 0pt。隔离样例显示 TPS，通过系统截图仅截取已核验的本应用测试窗口，检查了箭头与主体连续材质及 TPS 位置。截图为 `build/tps-revision-native/system-overview.png`，不包含真实账户信息。
- 独立代码复核已完成；发现的 Control Strip 回退遗漏已修复并补充自检。

本记录取代初版验证记录中的菜单栏 TPS、输入框浮层、辅助功能定位和相关设置行为；本地数据读取与隐私约束维持原实现。

## 本机安装

已按既有安装授权运行 `./install.sh`，替换并启动 `~/Applications/CodexTouchBar.app`。安装版与构建二进制逐字节一致，严格签名验证通过，bundle ID 为 `com.wyx.CodexTouchBar`，`LSUIElement=true`，安装版 TPS 核心自检通过。未提交或发布；Git HEAD 保持 `0e11e8fc8bc0ca1c5e20b634fb8ce3f046678e07`。

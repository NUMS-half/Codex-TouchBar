# 开发与诊断

用户安装与使用见 [README](../README.md)。本文集中说明从源码构建、签名和诊断。

## 构建

项目使用Swift Package Manager和AppKit，要求macOS 14或更高版本，没有第三方包依赖。

```bash
./tools/setup-local-signing.sh  # 首次配置本机签名身份
./build.sh                     # 构建应用到build/CodexTouchBar.app
./install.sh                   # 构建、安装到~/Applications并启动
```

安装脚本只替换本工具，并检查应用标识和签名身份。当前发布压缩包面向arm64，其他架构的使用情况尚未验证。

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

## 文档图片

[docs/images](images)中的图片来自本应用的原生离屏界面渲染，使用隔离的示例额度和设置；不是用户账户的实际用量。

### 额度刷新策略

- `QuotaRefreshPolicy`集中定义启动、面板打开、前台切换、唤醒、前台计时器、后台计时器和Touch Bar刷新七种可配置入口；`AppDelegate.requestRefresh`在执行前统一检查策略与睡眠状态。菜单栏刷新图标和右键刷新属于始终允许的手动请求。
- `Preferences.refreshPolicy`以版本化记录保存，缺少配置时保留原有前台间隔，并默认开启七种入口；后台默认300秒。刷新偏好使用独立通知，只重建计时器，不立即查询；显示、提醒和快捷操作偏好不会重启刷新计时器。
- `UsageStore`正在查询时合并请求；必要的重置机会详情后续请求属于已有查询的补充，不是独立自动触发或失败重试。历史维护、曲线重绘和设置界面更新只处理本地数据，不请求额度。
- `--self-test`验证策略门控、手动入口、计时器选择、迁移、持久化和异常记录；`--settings-self-test`使用隔离偏好逐个操作七种开关和两个间隔控件，验证即时保存与浅色／暗色布局。


## 维护约定

- 核心规则与诊断分开：刷新规则位于`RefreshPolicy.swift`，实际可执行检查位于`RefreshPolicyChecks.swift`；UI自检共享`UIDiagnosticSupport.swift`，不让设置测试依赖曲线测试的实现。
- App标识和数据目录由`ApplicationIdentity.swift`统一维护。变更标识、偏好键名或文件名需要明确迁移方案；此次整理保持现有值不变。
- 刷新间隔列表及显示名称由刷新策略统一定义，偏好层只负责保存。各类偏好通知保持独立，同值写入不重复触发Touch Bar更新。
- `QuotaRefreshTimer`仅在前后台类别、间隔变化或显式要求时重建。两个后台App之间的切换不得改变下一次查询时间；睡眠及退出取消计时器。
- 额度RPC按行处理，未完成行／完整行限制为4MiB；多条短消息可构成超过此大小的批次。超限作为无效响应处理，沿用最近成功快照。
- 代码质量审查与本轮验证记录见[2026-10-13审查记录](reviews/2026-10-13-code-quality.md)。

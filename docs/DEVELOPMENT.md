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

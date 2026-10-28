# 发布指南

本项目的发布产物是证书签名、仅支持 Apple Silicon（arm64）的 `.app` 压缩包。默认使用构建者固定的本机自签名证书；它并非 Developer ID 签名或 Apple 公证。这解决本机源码更新的身份连续性，但不能保证满足其他用户的签名或 Gatekeeper 策略。公开分发建议使用固定的 Developer ID Application 证书并公证；其他用户也可从源码建立自己的本机签名身份。绝不分发构建者的私钥、专用钥匙串或密码。

必须在后续版本中持续使用同一签名身份，才能让 macOS 识别更新。签名器会拒绝临时签名和静默签名失败；安装器会拒绝意外更换证书。`./tools/setup-local-signing.sh` 是本机的一次性设置，`./tools/check-signing.sh` 验证变化后的代码仍满足旧版签名要求。保持签名资料安全备份，绝不上传专用钥匙串、私钥或密码。

如提供 Developer ID Application 证书，通过 `CODEX_TOUCHBAR_SIGNING_IDENTITY` 指定，必要时同时指定 `CODEX_TOUCHBAR_SIGNING_KEYCHAIN`；公证需要另行配置，不属于本次本机签名修复。

## 发布前检查

1. 确认 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 与计划标签一致，例如 `2.4.0` 对应 `v2.4.0`。
2. 更新 `CHANGELOG.md` 和 `docs/releases/v2.4.0.md`。
3. 确认位于 `main`，当前变更已提交且工作区干净；发布包校验成功后再原子推送分支和标签。
4. 记录两类 Apple Silicon Mac 的实际验收情况：无 Touch Bar 时的菜单栏与设置；有 Touch Bar 时的额度卡、快捷操作及右侧系统 Control Strip。未完成的真机验收须在发布说明中列出，不以注入自检代替。

## 生成发布包

```bash
./package-release.sh 2.4.0
```

脚本会拒绝在有未提交变更时运行，并执行构建、签名校验与只读自检。完成后会在 `dist/` 生成：

- `CodexTouchBar-v2.4.0-macos-arm64.zip`
- `CodexTouchBar-v2.4.0-macos-arm64.zip.sha256`

`dist/` 已被 Git 忽略，不能提交到仓库。

## 创建标签与 GitHub Release

创建前确认远程目标标签与Release均不存在；不得覆盖已发布版本。确认发布包无误后：

```bash
git tag -a v2.4.0 -m "Codex TouchBar v2.4.0"
git -c 'url.git@ssh.github.com:.insteadOf=git@github.com:' \
    -c 'core.sshCommand=ssh -p 443 -o BatchMode=yes -o ConnectTimeout=10' \
    push --atomic origin main v2.4.0

gh release create v2.4.0 \
  dist/CodexTouchBar-v2.4.0-macos-arm64.zip \
  dist/CodexTouchBar-v2.4.0-macos-arm64.zip.sha256 \
  --title "Codex TouchBar v2.4.0" \
  --verify-tag --latest \
  --notes-file docs/releases/v2.4.0.md
```

若未安装 GitHub CLI，可在 GitHub 仓库的 **Releases** 页面创建新 Release：选择 `v2.4.0` 标签，上传 ZIP 与 `.sha256` 文件，并粘贴 `docs/releases/v2.4.0.md` 的内容。

## 发布后

检查 Release 页面中的两个附件、下载文件名和 SHA-256 校验值。不要删除已发布标签；修复问题时创建新的版本标签。

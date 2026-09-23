# 发布指南

本项目的发布产物是 ad-hoc 签名、仅支持 Apple Silicon（arm64）的 `.app` 压缩包。它未经过 Developer ID 签名或 Apple 公证；在其他用户的 Mac 上首次打开时，macOS 可能要求通过 Finder 的“打开”确认。

## 发布前检查

1. 确认 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 与计划标签一致，例如 `2.0.1` 对应 `v2.0.1`。
2. 更新 `CHANGELOG.md` 和 `docs/releases/v2.0.1.md`。
3. 确认工作区干净且所有变更已提交、推送到 `main`。
4. 在实体 Touch Bar Mac 上确认额度卡与右侧系统 Control Strip 正常显示。

## 生成发布包

```bash
./package-release.sh 2.0.1
```

脚本会拒绝在有未提交变更时运行，并执行构建、签名校验与只读自检。完成后会在 `dist/` 生成：

- `CodexTouchBar-v2.0.1-macos-arm64.zip`
- `CodexTouchBar-v2.0.1-macos-arm64.zip.sha256`

`dist/` 已被 Git 忽略，不能提交到仓库。

## 创建标签与 GitHub Release

确认发布包无误后：

```bash
git tag -a v2.0.1 -m "Codex TouchBar v2.0.1"
git push origin v2.0.1

gh release create v2.0.1 \
  dist/CodexTouchBar-v2.0.1-macos-arm64.zip \
  dist/CodexTouchBar-v2.0.1-macos-arm64.zip.sha256 \
  --title "Codex TouchBar v2.0.1" \
  --notes-file docs/releases/v2.0.1.md
```

若未安装 GitHub CLI，可在 GitHub 仓库的 **Releases** 页面创建新 Release：选择 `v2.0.1` 标签，上传 ZIP 与 `.sha256` 文件，并粘贴 `docs/releases/v2.0.1.md` 的内容。

## 发布后

检查 Release 页面中的两个附件、下载文件名和 SHA-256 校验值。不要删除已发布标签；修复问题时创建新的版本标签。

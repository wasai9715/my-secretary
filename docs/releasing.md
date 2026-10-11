# 开源与 macOS 预览版发布指南

本项目暂不使用 Apple Developer ID 证书与公证；在 GitHub 发布的 DMG 是 **UNNOTARIZED 未公证预览版**，可能被 macOS Gatekeeper 拦截。这不等同于 Apple 信任的安装包。未来若升级为签名公证发行版，须另行准备 Developer ID Application 证书、公证凭据，修改并验证发布流水线；仓库保留的 `scripts/package-release.sh` 仅供届时使用，**当前 CI 不会调用**。

## 发布前

- 仓库已经公开，采用 MIT 许可证。检查整个 Git 历史及 `docs/design/evidence/`；发现真实 Token 要先撤销/轮换，不能只删除当前文件。提交作者邮箱与历史文档会随仓库公开。
- README 与 Release 文案必须醒目标注未公证、早期预览和提醒可靠性限制。请勿推荐关闭 Gatekeeper、批量移除隔离属性或冒充官方 Apple 验证。
- GitHub `release` environment 只允许 `v*.*.*` 标签部署，并由仓库所有者人工审批发布。没有 Apple 凭据，也不应添加证书和公证密钥。请保护 `main`、限制谁能推送 `v*` 标签；审批不能替代标签保护。当前公开仓库使用标准 `macos-15` (arm64) 与 `macos-15-intel` (Intel) runner，不使用收费的 xlarge runner；若将仓库改回私有或更换 runner，先核对 GitHub Actions 计费。

## 构建与发布

1. 确认 `main` 的离线检查通过并尽可能完成 [真机验收清单](design/mac-v1-acceptance-checklist.md)。自动检查不代替通知、勿扰、登录启动等真实桌面验收。
2. 发布一个新标签，例如 `git tag v0.1.0 && git push origin v0.1.0`。不要移动或复用已发布标签；修复时递增版本。
3. Actions 在 Intel 与 Apple Silicon runner 上各运行 Swift 离线检查，用 `scripts/build-app.sh` 做 ad-hoc 签名，再通过 `scripts/package-preview.sh` 输出明确带 `UNNOTARIZED` 的 DMG 和 `.sha256`。**两个架构构建成功后，`publish` 等待 `release` 环境人工审批，批准才公开创建 GitHub Pre-release。**
4. 检查 [Actions](https://github.com/wasai9715/my-secretary/actions) 两个架构与最终 Release 状态。每个 DMG 内有 `READ-ME-FIRST.txt` 警告。用 `shasum -a 256 -c 文件名.dmg.sha256` 验证下载完整性。分别在 Intel / Apple Silicon 的真实 Mac 上，从 **Release 下载的 DMG** 挂载、拖入「应用程序」测试首次打开、菜单栏、通知与覆盖安装。哈希只能检测内容一致，**无法证明发布者身份**。

本地复现：`APP_VERSION=0.1.0 APP_BUILD_NUMBER=3 scripts/build-app.sh`，然后 `APP_VERSION=0.1.0 scripts/package-preview.sh`。不会请求证书或联网公证。若首次打开被 macOS 阻止，只在确认来源可信时，在「系统设置 → 隐私与安全性」选择「仍要打开」。本版本并非完整 V1 验收通过。

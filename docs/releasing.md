# 开源与 macOS 发布指南

## 公开前

- 核对整个 Git 历史和 `docs/design/evidence/`，确认没有真实 Token、个人事项或未授权资源。泄露过的 Token 应先撤销/轮换，不能只删除当前文件。
- 审核 Git 提交作者邮箱和产品设计文档是否允许公开。GitHub 仓库可见性由维护者在网页上手动切换；**此仓库不会由 CI 自动设为公开**。
- README 应保持预览版风险提示；勿将尚未验收的功能宣传为稳定可用。

## 准备 Apple Developer 签名

需要 Apple Developer Program 会员、有效的 **Developer ID Application** 证书（导出包含私钥的 `.p12`）以及有公证权限的 App Store Connect API Key（`.p8`，Key ID、Issuer ID）。绝不提交私钥和 Token 到 Git。若没有这些凭据，`scripts/build-app.sh` 仍可生成本地开发用 App，但**不应将其作为普通用户安装的正式 DMG 发布**。

在 GitHub 仓库 Settings → Environments 中创建 `release`，配置 required reviewers（以及允许部署的 tag 规则）。将下列值作为该 environment 的 secrets 保存：

| Secret | 值 |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | `.p12` 文件的 Base64 内容，单行无换行（macOS: `base64 -i certificate.p12 | tr -d '\n'`） |
| `CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `NOTARY_KEY_P8_BASE64` | `.p8` 文件的 Base64 内容，单行无换行 |
| `NOTARY_KEY_ID` | App Store Connect Key ID |
| `NOTARY_ISSUER_ID` | App Store Connect Issuer ID |

例如 `.p8` 可用 `base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n'` 编码。请在 GitHub 中保护 `main` 并限制谁能推送 `v*` 标签；环境审批不能代替标签保护。工作流只在 `v数字.数字.数字` 标签触发，对每个架构分别签名、公证 App（装订票据）、制作并公证 DMG（装订票据），两边完成才发布 Pre-release。签名凭据仅注入受审批保护的打包 job。留意 GitHub Actions macOS runner 与 Apple 公证会占用时间，API key 不应输出到日志。

## 发布

1. 完成源码审查、构建和本机检查，在 Apple Silicon 与 Intel 机器（或测试环境）分别验证架构和功能；特别检查 DMG 挂载、拖入「应用程序」后的首次打开、通知权限、菜单栏入口、重启与覆盖升级。真机验收结果记入 [清单](design/mac-v1-acceptance-checklist.md)。未完成则只发预览版。
2. 确认 `main` 已提交目标代码，推送不可重复使用的新标签，例如 `git tag v0.1.0 && git push origin v0.1.0`。不要移动/复用已有发布标签；修复请递增版本。
3. 审批 GitHub Actions 的 `release` environment。检查两个架构均通过、公证成功、Release 附件有两个 DMG 及对应 `.sha256`，再人工检查 Release 文案、安装、哈希和 Gatekeeper。工作流不会自动推送代码或修改仓库可见性。
4. 在隔离或全新 macOS 用户环境下载 **GitHub 上的附件**，用 `shasum -a 256 -c MySecretary-*.dmg.sha256` 校验，挂载并安装，确认 `spctl --assess --type execute --verbose /Applications/MySecretary.app` 通过。通知、睡眠唤醒、勿扰等完整验收仍需真实桌面环境。

本地签名/公证排错时：`APP_VERSION=0.1.0 APP_BUILD_NUMBER=3 SIGNING_IDENTITY='Developer ID Application: ...' scripts/build-app.sh`，接着设置 `NOTARY_KEY_FILE`、`NOTARY_KEY_ID`、`NOTARY_ISSUER_ID` 和 `APP_VERSION` 执行 `scripts/package-release.sh`。公证要求 App 的 Developer ID 签名及 hardened runtime；绝不能把本地 ad-hoc 签名包改名冒充正式发行版。

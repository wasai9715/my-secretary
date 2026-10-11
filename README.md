# My Secretary

个人 Mac 轻量承诺提醒助手。收到零碎请求时，按快捷键输入原话即可离开；智能识别时间，按计划提醒，失败时保住原话并显式提示。**当前是可构建的早期实现，不符合完整 V1 验收；请勿依赖其承担重要承诺提醒。**

## 下载安装

⚠️ [GitHub Releases](https://github.com/wasai9715/my-secretary/releases) 提供的是 **未经 Apple Developer ID 签名、未经 Apple 公证的实验性预览版 DMG**。只在信任此仓库并理解风险时安装；请勿将其当作已获 Apple 验证的软件，亦勿依赖其承担重要提醒。Apple Silicon 选 `arm64`，Intel Mac 选 `x86_64`，要求 macOS 14 或更新版本。可用同名 `.sha256` 文件核对下载完整性（它不能证明发布者身份）。打开 DMG 并阅读其中的 `READ-ME-FIRST.txt`，将 `MySecretary.app` 拖入「应用程序」。如果首次启动被 macOS 拦截，**仅在确认来源可信后**尝试启动一次，再到「系统设置 → 隐私与安全性」为 MySecretary 选择「仍要打开」；不要全局关闭 Gatekeeper，也不要执行网上提供的批量移除隔离属性命令。它是菜单栏应用，不会出现常驻 Dock 图标。首次启动需要在设置中提供**你自己的 DeepSeek API Token**、测试连接，并在「系统设置 → 通知」允许提醒；调用模型可能产生费用。

应用将事项与配置保存于本机 `~/Library/Application Support/MySecretary/`，模型请求会将输入发送至你在设置中配置的 HTTPS 模型服务。Token 目前保存在本地 `model.json`（仅当前用户权限），**尚未使用钥匙串**；不提供同步、云端备份或自动更新。更新时退出菜单栏应用，下载新版本并覆盖旧 `.app`，数据目录不会因覆盖应用而删除。卸载时退出应用，删除 `.app`；如需彻底清除本地数据，再手动删除上述目录。不要将其中的文件上传到 Issue。

项目采用 [MIT 许可证](LICENSE)。贡献与发布流程参见 [发布指南](docs/releasing.md)。

## 从哪里开始

- [产品与交互基线](docs/design/personal-reminder-v1.md)：访谈确认的 V1 体验、非目标与边界。
- [领域语言](CONTEXT.md)：事项、明确截止、建议完成、待识别等术语。
- [提示词 V10/V11 与留出集](docs/design/reminder-prompt-evaluation-v10-v11.md)：逐行动结构的 64 条既有＋24 条新句实测；[当前应用使用的 V11 适配版提示词](Sources/SecretaryCore/Resources/interpretation-prompt.txt) 去掉了冻结测试日期，并在多个独立行动时提示分次录入。实验原稿仍仅供追溯。
- [活跃变更](openspec/changes/bootstrap-personal-reminder/)：`proposal.md`、`design.md`、`tasks.md` 与四项能力的 `specs/*/spec.md`。这些是**拟实现的要求**，不是已经上线的主规格。
- [OpenSpec 配置](openspec/config.yaml)：文档语言、写作与归档约束。`openspec/specs/` 目前为空；实现并验收后再归档变更生成主规格。

## 本地构建与目前进度

在已安装 macOS Command Line Tools 的 Mac 上运行：

```bash
swift build
swift run SecretaryCoreChecks
swift run SecretaryPresetChecks
swift run SecretaryCommandChecks
# 无真实事项/系统通知：模拟派发失败、重开补发、每日汇总及系统时钟变化
scripts/build-app.sh
for check in reminder-dispatch reminder-recovery reminder-digest clock-recompute item-lifecycle recognition-race capture-enter management-list command-actions success-banner post-save-route permission-ui notification-route real-notification login-launch; do
  ./dist/MySecretary.app/Contents/MacOS/MySecretary --check-"$check"
done
scripts/check-window-lifecycle.sh
scripts/check-capture-keyboard.sh
# 使用已配置的 DeepSeek 与虚构测试句；会消耗少量 API 请求，不更改事项
swift run SecretaryAISmoke
swift run SecretaryCommandSmoke
scripts/build-app.sh
# 可选：不写入真实事项，检查处理中仅菜单状态、成功仅一次提示卡
./dist/MySecretary.app/Contents/MacOS/MySecretary --check-feedback-flow
open dist/MySecretary.app
```

首次运行从菜单栏打开「设置」，填入 DeepSeek Token 并测试连接，**同时在 macOS 系统设置中允许 MySecretary 发送通知**；然后再使用菜单栏「记下一件事」或默认 `⌃⇧9`。设置页可点击「录制快捷键」并直接按自定义组合，注册成功才会保存；若冲突则保留旧快捷键。若通知被拒绝，连接模型成功也无法弹出到期提醒；新版菜单栏会持续标记通知不可用。配置和事项存于 `~/Library/Application Support/MySecretary/`；Token 存本地配置文件（仅当前用户权限），请自行妥善保管。生成的 `dist/` 不纳入版本控制。`scripts/build-app.sh` 产生的是 **ad-hoc 临时签名应用**，`scripts/package-preview.sh` 仅将它打包为明确标注 UNNOTARIZED 的预览版；两者都不是已获 Apple 公证的发行版。

**已实现的基础链路：** Swift 原生菜单栏/录入浮层、SQLite 事项存储、模型测试、V11 逐行动理解后单项安排（多个独立行动提示分次录入）、有限结构/时序校验纠错、通知调度的初版、基础管理列表及本地检查。历史事项不自动重识别。**未实现或未验收：** 通知权限关闭/恢复与通知点击、合并通知截断的完整真机验收；登录启动及睡眠/勿扰的实际桌面验收；两周试用。识别失败人工重试、日期预设、自然语言多动作与列表分组已提供，但仍须经过实际使用验证。参见 [真机验收记录模板](docs/design/mac-v1-acceptance-checklist.md)。OpenSpec 任务未勾选表示尚未满足其完整验收条件。

## 开发工作流

1. 阅读产品基线、领域语言与活跃变更，先确认待做的任务和验收场景。
2. 用 Pi 中的 `/opsx-update` 调整变更，或用 `openspec` CLI 查看；实现时用 `/opsx-apply` 按 `tasks.md` 逐项执行。Pi 与共享 `.agents/skills/` 是 OpenSpec 初始化生成的入口。
3. 使用 `openspec status --change bootstrap-personal-reminder` 和 `openspec validate bootstrap-personal-reminder --strict` 检查工件；任务全部完成、真机验收后再使用 `/opsx-archive`。

V1 的首个模型验收目标为 DeepSeek。首版不做跨设备同步、导出、语音、聊天抓取，也不把 Pi Agent 作为提醒运行时。

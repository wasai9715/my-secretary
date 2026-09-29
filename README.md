# My Secretary

个人 Mac 轻量承诺提醒助手。收到零碎请求时，按快捷键输入原话即可离开；智能识别时间，按计划提醒，失败时保住原话并显式提示。**当前是可构建的早期实现，不符合完整 V1 验收；请勿依赖其承担重要承诺提醒。**

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
scripts/check-window-lifecycle.sh
scripts/check-capture-keyboard.sh
# 使用已配置的 DeepSeek 与虚构测试句；会消耗少量 API 请求，不更改事项
swift run SecretaryAISmoke
scripts/build-app.sh
# 可选：不写入真实事项，检查处理中仅菜单状态、成功仅一次提示卡
./dist/MySecretary.app/Contents/MacOS/MySecretary --check-feedback-flow
open dist/MySecretary.app
```

首次运行从菜单栏打开「设置」，填入 DeepSeek Token 并测试连接，**同时在 macOS 系统设置中允许 MySecretary 发送通知**；然后再使用菜单栏「记下一件事」或默认 `⌃⇧9`。设置页可点击「录制快捷键」并直接按自定义组合，注册成功才会保存；若冲突则保留旧快捷键。若通知被拒绝，连接模型成功也无法弹出到期提醒；新版菜单栏会持续标记通知不可用。配置和事项存于 `~/Library/Application Support/MySecretary/`；Token 存本地配置文件（仅当前用户权限），请自行妥善保管。生成的 `dist/` 不纳入版本控制。

**已实现的基础链路：** Swift 原生菜单栏/录入浮层、SQLite 事项存储、模型测试、V11 逐行动理解后单项安排（多个独立行动提示分次录入）、有限结构/时序校验纠错、通知调度的初版、基础管理列表及本地检查。历史事项不自动重识别。**未实现或未验收：** 通知点击完整交互验收、自定义快捷键实际桌面录制验收与提醒预设、自然语言修改、多动作原子执行、历史恢复日期选择、错过通知完整重算、睡眠/权限/勿扰真机验证、两周试用。OpenSpec 任务未勾选表示尚未满足其完整验收条件。

## 开发工作流

1. 阅读产品基线、领域语言与活跃变更，先确认待做的任务和验收场景。
2. 用 Pi 中的 `/opsx-update` 调整变更，或用 `openspec` CLI 查看；实现时用 `/opsx-apply` 按 `tasks.md` 逐项执行。Pi 与共享 `.agents/skills/` 是 OpenSpec 初始化生成的入口。
3. 使用 `openspec status --change bootstrap-personal-reminder` 和 `openspec validate bootstrap-personal-reminder --strict` 检查工件；任务全部完成、真机验收后再使用 `/opsx-archive`。

V1 的首个模型验收目标为 DeepSeek。首版不做跨设备同步、导出、语音、聊天抓取，也不把 Pi Agent 作为提醒运行时。

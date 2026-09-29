#!/usr/bin/env python3
"""Render action-array prompt experiments and untouched holdout evidence."""
import collections
import datetime as dt
import json
from pathlib import Path

base=Path('docs/design/evidence')
v10=json.loads((base/'prompt-evaluation-v10.json').read_text())
v11=json.loads((base/'prompt-evaluation-v11.json').read_text())
hold=json.loads((base/'prompt-holdout-v11.json').read_text())
review={
  2:('需复核','稍后返回待确认安全，但产品需要保证不会因此彻底沉默。'),
  16:('需复核','“今晚调整配置”是计划时段，模型仍可能把它变成完成期限。'),
  30:('需复核','明早10点前交数据，8点提醒是否有足够准备时间因人而异。'),
  31:('需复核','今晚20点前交却19:50才首次提醒，可能来不及准备。'),
  33:('错误','下午13点前是具体截止时刻，却被写成 period；提醒12:45本身可用。'),
  37:('需复核','本周内完成却返回uncertain待确认；仅知道周范围也可以在周内做一次检查提醒。'),
  39:('需复核','周末之前期限不明确，但返回null/待确认会增加额外操作。'),
  43:('错误','明天08点是会议开始，并非参加会议必须08点前完成的deadline=instant。'),
  47:('可接受','拆成周五上线与下周一检查两项，均有自己的提醒。'),
  55:('错误','依赖明天确认完成才可发，却又给该行动直接设09:00的reminderAt；确认和排期互相矛盾。'),
  58:('需复核','同样的今天给领导报表，17:32才首次提醒，可能错过工作时段。'),
  60:('需复核','十点下班有明确时刻却反而待确认，同句其他重复能排到22点。'),
  63:('需复核','下班前交付却17:30才首次提醒，若下班更早或需时间处理会错过。'),
  64:('需复核','同一句下班后买菜又变待确认，三次输出不稳定。'),
}
hold_review={
  1:('错误','12:40录入、13点前发邮件，却返回11:00提醒，已过去。'),
  3:('错误','12:40录入、12:30已截止，却返回12:25提醒且标无需确认；至少应识别已过期。'),
  10:('需复核','周四之前交付，周四10点首次提醒，若“周四之前”不包含周四则太晚。'),
  16:('错误','付款依赖财务完成核对却仍安排明天10点；模型同时标requiresConfirmation=true，返回值自相矛盾。'),
  19:('需复核','周五体检本身被标为day截止，原话只是赴约计划，不是完成期限。'),
  22:('需复核','周二上午联系被标为period截止，原话表达计划时段而非完成约束。'),
}
def clean(x):return str(x).replace('|','\\|').replace('\n',' ') if x is not None else '—'
def time(x):
 if not x:return '—'
 try:return dt.datetime.fromisoformat(x).strftime('%m-%d %H:%M')
 except (TypeError,ValueError):return clean(x)
def actions(r):
 pieces=[]
 for a in r.get('actions') or []:
  d=a.get('deadline') or {}
  value=time(d.get('at')) if d.get('kind')=='instant' else d.get('day') or d.get('period') or '—'
  pieces.append(f'{a.get("action", "—")} ⇒ {time(a.get("reminderAt"))} [{a.get("reminderSource", "—")}]；期限 {d.get("kind", "—")}: {value}')
 return '<br>'.join(map(clean,pieces))
lines=['# 个人提醒提示词 V10/V11：按行动拆解与留出集实验','',
 '> 仅候选实验，未修改当前 App、真实事项或现有 OpenSpec 实现。所有输入均为虚构句子。', '',
 '## 实验设计','',
 '- V2～V9输出只有一个提醒字段；[V10候选提示词](evidence/reminder-prompt-v10.txt)改为先列 `actions[]`，每个行动分别有计划日、首次提醒、完成期限、引文；[V11提示词](evidence/reminder-prompt-v11.txt)针对V10的结构与日期回归增加约束。',
 '- 与既有实验相同：固定 `2026-09-29T12:40+08:00`、同一DeepSeek配置，同批56种合成句＋4句重复两次。V11完成之后才加入**24条新写的留出语句**。分别保留[V10原始64条](evidence/prompt-evaluation-v10.json)、[V11原始64条](evidence/prompt-evaluation-v11.json)、[留出集24条](evidence/prompt-holdout-v11.json)。每个模型结果只请求一次，无应用端纠错。',
 '', '## 最关键结果','',
 '- **有意义的进步**：V11将“周五上线、下周一检查”（#47）拆成两个行动，两次分别提醒；“明天报告、今天先准备”（#44）也能给今天和明天各安排一次，说明此前单提醒字段确实限制了表达。',
 '- **同批回归**：#33 把13点前的明确截止降格为period；#43将08点开会误标为08点完成截止；#55一边要求用户确认外部反馈，一边仍输出假定的09:00提醒。',
 '- **留出集揭示实质风险**：24条新句中 #1 和 #3 各返回一个**已过去的提醒**；#16有未知财务反馈前置条件，却同时标待确认并安排固定提醒。提示词明确要求未来时刻仍不能保证。',
 '- 结论：多行动数组缓解了字段容量不足，但提示词自身不能保证时间有效、语义出处和状态一致；**保留通用程序校验是必要的**。程序不用写“明天/后天/买菜”的语义匹配，但必须拒绝过去时间、精确截止顺序错误、不合法枚举以及自相矛盾的待确认状态。',
 '', '## V10与V11关键用例对比','',
 '| # | 合成原话 | V10关键问题 | V11结果 |', '|---:|---|---|---|',
 '| 19 | 明天九点提醒我去开会 | 误把九点提醒时刻当成精确完成截止 | 截止改为none（正确） |',
 '| 29 | 月底要把文档交付给产品 | 月底算到10月31日 | 改为9月30日 |',
 '| 37 | 本周内完成核对 | 无时间默认15分钟、漏掉本周期限 | 保留period期限，却返回待确认（仍不理想） |',
 '| 42 | 客户三点开会后问结论 | 三点零五提醒，假定已有结论 | 返回待确认，不猜会议结束时刻 |',
 '| 45 | 后天交数据，明早核对 | 第二行动误用无时间默认15分钟 | 两行动分别在明早与后天提醒 |',
 '| 47 | 周五上线、下周一检查 | 成功拆成两个行动 | 同样拆为两个行动并分别安排 |',
 '| 55 | 今天不发，明天确认后再说 | 构造“今天继续暂缓”的多余行动 | 去掉假行动，但确认状态与固定提醒矛盾 |',
 '', '## V11逐句输出（既有64条）','',
 '| # | 类别 | 合成原话 | 模型标题 | 是否需确认 | 按行动分别输出：行动 ⇒ 提醒 [来源]；期限 | 人工复核 |',
 '|---:|---|---|---|---|---|---|']
for x in v11['cases']:
 r=x['result'];label,reason=review.get(x['id'],('可接受','本次未观察到明显冲突；不代表重复调用也稳定。'))
 lines.append('| '+' | '.join([f'{x["id"]:02d}',clean(x['category']),clean(x['input']),clean(r.get('title')),
   clean(r.get('requiresConfirmation')),actions(r),f'**{label}**：{clean(reason)}'])+' |')
lines+=['','## 新增留出集（24条，不参与V10/V11改稿）','',
 '| # | 类别 | 合成原话 | 是否需确认 | 按行动分别输出 | 人工复核 |', '|---:|---|---|---|---|---|']
for x in hold['cases']:
 r=x['result'];label,reason=hold_review.get(x['id'],('可接受','本次未观察到明显冲突；不代表总是正确。'))
 lines.append('| '+' | '.join([f'{x["id"]:02d}',clean(x['category']),clean(x['input']),clean(r.get('requiresConfirmation')),actions(r),f'**{label}**：{clean(reason)}'])+' |')
lines+=['','## 审核后的下一步','',
 '- **不把V10/V11直接用在现有App。** 当前Swift解析器还是一个事项/一个提醒；结构化输出不兼容，需要先决定是否支持多行动提醒与各行动完成状态。',
 '- 单靠继续叠加提示词无法承诺所有输入可靠。测试必须有程序级不依赖业务关键词的校验：时间含偏移量、提醒晚于现在、精确截止不能与提醒同刻/早于提醒、enum合法、用户原话依据可验证、待确认不得伪装为已安排。校验失败时最多纠错重试一次，再进入待识别。',
 '- 提醒时间是否“有用”需要另行确定用户可接受的提前量与反馈机制；仅检查时间顺序并不能保证体验。','',
 '## 局限','',
 '- 独立API请求：V10 64次、V11 64次、留出24次；没有测试实际系统通知、App解析器或网络重试；模型可能变动且无固定随机种子。',
 '- 输出与人工判定均针对合成语句；本地真实事项从未作为本轮模型输入。','']
path=Path('docs/design/reminder-prompt-evaluation-v10-v11.md');path.write_text('\n'.join(lines)+'\n');print(path,'main',len(v11['cases']),'holdout',len(hold['cases']))

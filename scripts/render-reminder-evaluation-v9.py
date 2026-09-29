#!/usr/bin/env python3
"""Render V9 synthetic prompt-only evaluation, preserving observed regressions."""
import collections
import datetime as dt
import json
from pathlib import Path

p=json.loads(Path('docs/design/evidence/prompt-evaluation-v9.json').read_text())
issues={
  2:('需复核','“稍后”返回待确认；用户原本期望轻量录入，需明确如何兜底。'),
  9:('需复核','“记得写”误标为提醒意图，但安排在正确日期。'),
  15:('需复核','下班时间未知，12:45提醒明晚买菜较早。'),
  20:('错误','只说10月2号提醒，temporalIntent竟为none；字段语义自相矛盾。'),
  35:('错误','“下班前”明确表达到某个时段前完成，但deadline=none，真实期限被遗漏。'),
  43:('需复核','先准备材料正确；明日会议无第二提醒，是否需要由产品决定。'),
  47:('需复核','检测到两个行动，返回待确认而不静默漏掉；仍无法自动安排两次提醒。'),
  50:('错误','JSON虽能解析，temporalIntent/reminderBasis/deadline等关键字段均为null，违反固定枚举和完整结构要求。'),
  51:('错误','下周五或周六仍未确定，竟安排本周五10月2号提醒，提前一周且不在两个候选日期。'),
  52:('错误','“今天不用做，明天再处理”却返回reminder=null/no_time_default，会错误落到今天15分钟。'),
  60:('需复核','把下班十点当提醒参考合理，但不应称知道用户买菜需要的时刻。'),
  64:('错误','十点是下班钟点，用户并未明确指定提醒时刻；模型误标reminderBasis=explicit。'),
}
def fmt(s):
 if not s:return '—'
 try:return dt.datetime.fromisoformat(s).strftime('%m-%d %H:%M')
 except (TypeError,ValueError):return str(s)
def esc(s):return str(s).replace('|','\\|').replace('\n',' ') if s is not None else '—'
def due(d):
 if d.get('kind')=='none':return '无'
 v=fmt(d.get('at')) if d.get('kind')=='instant' else (d.get('day') or '')
 if d.get('kind')=='period':v=(v+' '+str(d.get('period') or '')).strip()
 return esc(f'{d.get("kind")}: {v} [{d.get("basis")}]')
score=collections.Counter(issues.get(x['id'],('可接受',''))[0] for x in p['cases'])
lines=['# 个人提醒提示词 V9：重点边界复测','',
 '> 仅候选实验，未修改当前 App 提示词、代码或用户事项。', '',
 '## 结果和决策','',
 '- [V9实际完整提示词](evidence/reminder-prompt-v9.txt) = [V8](evidence/reminder-prompt-v8.txt) + [双行动/时段边界补充](evidence/reminder-prompt-v9-appendix.txt)。[64次原始输出](evidence/prompt-evaluation-v9.json)。固定2026-09-29 12:40 +08:00，同一批合成句和同一DeepSeek模型，每句单次，无纠错重试。',
 '- 与[V8逐条复测](reminder-prompt-evaluation-v5-v8.md)对比：#38“中午前”不再成为精确12:00，#47“周五上线＋下周一检查”改成待确认，不再假装只提醒后者即可覆盖全句。',
 '- **新退步更危险**：#51不确定的下周五或周六竟提前到本周五；#52否定“今天”仍落回今天默认15分钟；#35漏了明确“下班前”期限；#50虽然是JSON，关键枚举字段全为null；#64把下班十点误当用户明确要求的提醒。',
 f'- 本轮人工判定：可接受{score["可接受"]}、需复核{score["需复核"]}、错误{score["错误"]}。原样本标签属于人工审查，不是可泛化准确率；不能因为某个版次在少量样例上赢了就部署。',
 '- **结论**：继续往长提示词追加例外，明显出现回归和结构失效。V9不建议替换生产提示词。下一步应把一个输入中的行动分别抽取，再让提醒引擎基于多个行动安排通知；程序保留与语义无关的schema、日期、时序硬校验。',
 '', '## 64条逐句输出','',
 '| # | 类别 | 合成原话 | 模型标题 | 意图 | 首次提醒 [来源] | 截止 [来源] | 建议完成 | 时间证据 | 不确定说明 | 人工判定 |',
 '|---:|---|---|---|---|---|---|---|---|---|---|']
for c in p['cases']:
 r=c['result']; label,why=issues.get(c['id'],('可接受','本次未观察到明显冲突，不代表未来请求稳定正确。'))
 row=[f'{c["id"]:02d}',esc(c['category']),esc(c['input']),esc(r.get('title')),esc(r.get('temporalIntent')),
      esc(fmt(r.get('reminder'))+' ['+str(r.get('reminderBasis'))+']'),due(r.get('deadline') or {}),fmt(r.get('suggestedCompletion')),
      esc('；'.join(e.get('quote','') for e in r.get('timeEvidence') or []) or '—'),esc(r.get('uncertainty')),
      '**'+label+'**：'+esc(why)]
 lines.append('| '+' | '.join(row)+' |')
lines+=['','## 限制','',
 '- 与V2–V8相同，均为虚构原话、单一固定时刻、单一模型；只有四句各重复三次。人工标签不能代表生产数据准确率。',
 '- V9输出结构不同于现有Swift解析器；即使自然语言语义改善，也不能直接把候选提示词复制到App。','']
path=Path('docs/design/reminder-prompt-evaluation-v9.md');path.write_text('\n'.join(lines)+'\n');print(path,dict(score))

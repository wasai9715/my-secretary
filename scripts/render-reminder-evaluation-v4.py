#!/usr/bin/env python3
"""Render the V4 prompt-only retry from recorded synthetic results."""
import collections
import datetime as dt
import json
from pathlib import Path

p=json.loads(Path('docs/design/evidence/prompt-evaluation-v4.json').read_text())
# Independent review: 'acceptable' means no observed conflict in this one sample.
FINDINGS={
  2:('需复核','“稍后”待确认安全，但未安排时间；产品需决定是否同时给15分钟兜底检查。'),
  9:('需复核','“记得写周报”仍标为明确提醒意图，而不是计划；具体时间虽是推断。'),
  15:('需复核','未知道用户下班几点，17:30仍是无依据的猜测。'),
  28:('需复核','提前一天晚上20:00提醒申请，可能打扰；用户未提供偏好的空档。'),
  33:('错误','12:40录入、13:00截止，却在13:00才提醒且标explicit：没有提前量，不能称用户明确要求此刻提醒。'),
  38:('需复核','明天中午前交材料，选今晚21:40提醒；或许有用，但可能不适当。'),
  40:('需复核','十点下班后买菜有执行线索却直接返回null/uncertain；与同句#60/#64矛盾。'),
  42:('需复核','三点是会议开始，15:30问结论仍是假设会议30分钟结束；较V3改善但无事实依据。'),
  47:('错误','只提醒下周一复查，周五上线的承诺可能遗漏；同句两阶段行动单字段无法完整表达。'),
  49:('需复核','“晚点把资料给他”标 reminder 意图，用户没明确说提醒；null/uncertain本身安全。'),
  50:('需复核','下周找时间处理仅返回null；若没有待确认的持续提示仍可能遗忘。'),
  53:('错误','“不是今天发客户，后天再发”仍缺后天交付的仅日期截止，与类似交付句不一致。'),
  54:('需复核','下周一前不提醒、周二联系的日历周解释合理，但具体钟点由AI推断。'),
  55:('需复核','等待明天确认的结果是前置条件；返回null合理，但需确保事项不会静默消失。'),
}

def text(s):return str(s).replace('|','\\|').replace('\n',' ') if s is not None else '—'
def when(s):
    if not s:return '—'
    try:return dt.datetime.fromisoformat(s).strftime('%m-%d %H:%M')
    except (ValueError,TypeError):return text(s)
def due(d):
    if d.get('kind')=='none':return '无'
    value=when(d.get('at')) if d.get('kind')=='instant' else (d.get('day') or '')
    if d.get('kind')=='period':value=(value+' '+str(d.get('period') or '')).strip()
    return text(f'{d.get("kind")}: {value} [{d.get("basis")}]')
counts=collections.Counter(FINDINGS.get(c['id'],('可接受',''))[0] for c in p['cases'])
lines=[
 '# 个人提醒提示词 V4：第二轮改稿实测', '',
 '> 候选实验，未修改当前 App 的提示词、事项或提醒安排。所有输入是虚构合成语句。', '',
 '## 设置及对照', '',
 '- 在 [V3 候选](evidence/reminder-prompt-v3.txt) 之后添加 [V4 自检要求](evidence/reminder-prompt-v4-appendix.txt)，得出 [实际发送的 V4 完整提示词](evidence/reminder-prompt-v4.txt)。',
 '- 与 [V2](reminder-prompt-evaluation-v1.md) 和 [V3](reminder-prompt-evaluation-v3.md) 使用同一固定时间 `2026-09-29 12:40 +08:00`、同一模型、相同 64 次合成输入；V4 完整原始 JSON 与提示词见 [证据](evidence/prompt-evaluation-v4.json)。每次独立调用，不作纠错重试。',
 '', '| 版本 | 可接受 | 需复核 | 错误 | 过去时刻 | 接口失败 |', '|---|---:|---:|---:|---:|---:|',
 '| V2 | 38 | 15 | 11 | 1（#33） | 0 |',
 '| V3 | 48 | 11 | 5 | 1（#29） | 0 |',
 f'| V4 | {counts["可接受"]} | {counts["需复核"]} | {counts["错误"]} | 0 | 0 |',
 '',
 '**改善**：#19 不再把提醒九点当截止；#25“后天发布”有日期交付；#29月底提醒不再过去；#43先提醒今天准备材料；重复的“后天买东西”#8/#57/#61均无硬截止且在后天提醒。',
 '**仍失败**：#33提醒与13:00截止同刻且误标明确提醒，违反“提前有用”目标；#47两阶段动作只提醒事后检查；#53仍把“后天再发给客户”当无交付约束。#40同句重复前后语义不一致。',
 '**结论**：提示词能显著改善分类，但不足以保证每次可靠。尤其是单个 reminder 字段无法同时承载“先上线、后复查”两个需要提醒的行动，继续堆文字不能解决字段容量问题。',
 '', '## 每句输出与人工判定', '',
 '| # | 类别 | 合成原话 | 模型标题 | 意图 | 首次提醒 [来源] | 截止 [来源] | 建议完成 | 原话时间依据 | 不确定说明 | 判定 |',
 '|---:|---|---|---|---|---|---|---|---|---|---|',
]
for c in p['cases']:
 r=c['result'];label,why=FINDINGS.get(c['id'],('可接受','本轮未观察到明显冲突，不代表能稳定复现。'))
 fields=[f'{c["id"]:02d}',text(c['category']),text(c['input']),text(r.get('title')),text(r.get('temporalIntent')),
         text(when(r.get('reminder'))+' ['+str(r.get('reminderBasis'))+']'),due(r.get('deadline') or {}),
         when(r.get('suggestedCompletion')),
         text('；'.join(e.get('quote','') for e in r.get('timeEvidence') or []) or '—'),
         text(r.get('uncertainty')),f'**{label}**：{text(why)}']
 lines.append('| '+' | '.join(fields)+' |')
lines += ['', '## 相同句子的三次结果', '',
 '| 原话 | 一 | 二 | 三 |', '|---|---|---|---|']
for utterance in ['后天给阿姨买东西','今天给领导一份报表','明天下班前配置导出任务','晚上十点下班后买菜回家']:
 same=[c for c in p['cases'] if c['input']==utterance]
 vals=[f'#{c["id"]} {when(c["result"].get("reminder"))} / 截止{c["result"].get("deadline",{}).get("kind")}' for c in same]
 lines.append('| '+' | '.join([text(utterance),*vals])+' |')
lines += ['', '## 后续（待确认，不写入 App）', '',
 '1. 先确认多动作输入应该拆成多项、单项多次提醒，还是标待确认；当前单 `reminder` + 单 `deadline` 不足以表达 #47。',
 '2. 通用程序校验仍应保留：合法日期、证据是否属于原话、提醒晚于录入时刻、与明确截止的先后及是否留有最小处理时间。它只验结构与安全边界，不写“后天/买菜/上线”等语义正则。',
 '3. 再测更多时区、午夜、重复稳定性；本轮仅有64次独立样本、一个时间锚点和一个模型。人工分类不是总体准确率。',
]
path=Path('docs/design/reminder-prompt-evaluation-v4.md')
path.write_text('\n'.join(lines)+'\n')
print(path,'scores',dict(counts),'requests',len(p['cases']))

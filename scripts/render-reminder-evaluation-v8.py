#!/usr/bin/env python3
"""Render the recorded V8 same-set rerun; flags are a manual review, not an accuracy metric."""
import collections
import datetime as dt
import json
from pathlib import Path

p=json.loads(Path('docs/design/evidence/prompt-evaluation-v8.json').read_text())
issues={
  2:('需复核','“稍后”未给可执行提醒，安全但可能漏掉承诺；需产品兜底。'),
  9:('需复核','“记得写”再次误标为提醒意图，时间为建议值。'),
  15:('需复核','假定18:00下班，真实下班时间未知。'),
  25:('需复核','有日期交付，但意图mixed并未解释第二种意图。'),
  28:('需复核','申请提交当天9点提醒；若上午很早截止可能来不及，原话没有截止钟点。'),
  34:('需复核','“十分钟内”应可从录入时间换算为精确截止；模型只保留period。'),
  38:('错误','“明天中午前”没有精确钟点，不能把默认中午点位当用户承诺的instant截止。'),
  43:('需复核','今天准备材料已先提醒，但明天会议没有独立提醒；需产品决定是否双提醒。'),
  46:('需复核','同时有明确提醒与明确截止，temporalIntent却仅为reminder。'),
  47:('错误','周五上线、下周一检查：首次只提醒下周一，周五阶段被静默遗漏。'),
  50:('需复核','在下周一先提示“下周找时间”可接受，但用户没有选定处理日，需标清只是检查提醒。'),
  53:('需复核','后天发送客户已识别日期截止，但仍标计划意图而非交付意图。'),
}

def fmt(v):
 if not v:return '—'
 try:return dt.datetime.fromisoformat(v).strftime('%m-%d %H:%M')
 except:return str(v)
def esc(v):return str(v).replace('|','\\|').replace('\n',' ') if v is not None else '—'
def due(d):
 if d.get('kind')=='none':return '无'
 time=fmt(d.get('at')) if d.get('kind')=='instant' else (d.get('day') or '')
 if d.get('kind')=='period':time=(time+' '+str(d.get('period') or '')).strip()
 return esc(f'{d.get("kind")}: {time} [{d.get("basis")}]')
score=collections.Counter(issues.get(x['id'],('可接受',''))[0] for x in p['cases'])
lines=['# 个人提醒提示词 V5–V8：继续精炼与退步审计','',
 '> 仅候选实验；当前 App、用户事项和 OpenSpec 实现均未修改。全部为合成原话。','',
 '## 测试方法与总体观察','',
 '- 统一使用 `2026-09-29T12:40:00+08:00`、同一 DeepSeek 模型、同一批56种合成句式＋4句各额外重复两次。每版64次独立调用，不进行程序纠错。','- 原始响应及实际发送的完整提示词：[V5 JSON](evidence/prompt-evaluation-v5.json) · [V6 JSON](evidence/prompt-evaluation-v6.json) · [V7 JSON](evidence/prompt-evaluation-v7.json) · [V8 JSON](evidence/prompt-evaluation-v8.json)。各版提示词见同目录 `reminder-prompt-v5.txt` 至 `reminder-prompt-v8.txt`。',
 '- V4人工结果作为基线：[V4 文档](reminder-prompt-evaluation-v4.md)，64次中50可接受、11需复核、3错误；以下每版都不是同一请求的确定性改进，仅可观察误判是否转移。','',
 '| 版次 | 明显进步 | 新出现的错误/退步 |', '|---|---|---|',
 '| V5 | 多阶段句识别变好（#47待确认），#33不再返回过去或同刻 | #7给买水果造期限；#9写周报变待确认；#42会议开始时问结论；#54违反“下周一前不用提醒”；#56“后天”算成10月2日 |',
 '| V6 | #54相对日期与否定修正正确；#47待确认 | #33提醒等于13:00截止；#3无时间本应默认15分钟却被标待确认；#37、#59本来可建议时间却变null |',
 '| V7 | #33严格早于截止；#47待确认；相对日期正确 | #50把下周计划提醒提前到明天；#58同句“今天给报表”变null/待确认；#14计划见设计师被误设时间段截止 |',
 '| V8 | #33提前到12:55；#53识别后天交付；无过去时刻 | #38“中午前”被写成精确钟点；#47仍静默只提醒下周一；#25/#46出现意图标签不一致 |',
 '',
 f'- V8逐条人工标注：可接受{score["可接受"]}、需复核{score["需复核"]}、错误{score["错误"]}；**不因这个数字单独判定V8优于V4**，因为错误类型不同，漏提醒优先级更高。',
 '- 结论：长篇自检一边修复案例，一边让模型在相似输入上退步。继续单纯添加提示词规则不能保证精确截止、多阶段提醒和模糊表达全部稳定。',
 '', '## V8逐句实际结果', '',
 '| # | 类别 | 合成原话 | 标题 | 意图 | 提醒 [来源] | 截止 [来源] | 建议完成 | 时间依据 | 不确定说明 | 人工判定 |',
 '|---:|---|---|---|---|---|---|---|---|---|---|']
for c in p['cases']:
 r=c['result'];label,reason=issues.get(c['id'],('可接受','本次未见明显冲突，不表示重复输入也稳定。'))
 fields=[f'{c["id"]:02d}',esc(c['category']),esc(c['input']),esc(r.get('title')),esc(r.get('temporalIntent')),
         esc(fmt(r.get('reminder'))+' ['+str(r.get('reminderBasis'))+']'),due(r.get('deadline') or {}),fmt(r.get('suggestedCompletion')),
         esc('；'.join(e.get('quote','') for e in r.get('timeEvidence') or []) or '—'),esc(r.get('uncertainty')),
         '**'+label+'**：'+esc(reason)]
 lines.append('| '+' | '.join(fields)+' |')
lines+=['','## 下一步建议','',
 '1. 暂不替换生产提示词。V4虽较短但仍会返回过去时刻，所以无论选哪版，程序都必须校验合法日期、未来时刻、明确截止先后；这类**结构和时序验证**不同于硬编码“明天/后天/发布”的语义匹配。',
 '2. 对“先上线，后来检查”先决定**单条事项能否包含两个分别提醒的行动**，否则模型即使理解正确也没有足够的输出槽位；返回待确认只能防止静默漏事，不能提供理想体验。',
 '3. 若继续实验，优先采用有序的中间语义结构（行动及其约束→提醒建议），而非继续在单个扁平JSON上追加自检段；增加未用于改稿的新句作为独立留出集，多次重复测波动，再由用户审阅。',
 '', '## 局限','',
 '- 人工标注、单一时间锚点、每个独特原话一轮返回；没有测试系统通知、超时重试、旧 App 的真实解析器。分数不是生产准确率。',
 '- V5–V8输出格式是规划中的候选schema，不是当前Swift App支持的结构；直接替换提示词会破坏解析。','']
path=Path('docs/design/reminder-prompt-evaluation-v5-v8.md');path.write_text('\n'.join(lines)+'\n');print(path,dict(score))

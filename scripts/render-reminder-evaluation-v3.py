#!/usr/bin/env python3
"""Render V3 synthetic model evidence, preserving each input and full response link."""
import collections
import datetime as dt
import json
from pathlib import Path

source = Path('docs/design/evidence/prompt-evaluation-v3.json')
out = Path('docs/design/reminder-prompt-evaluation-v3.md')
p = json.loads(source.read_text())
ISSUES = {
  2: ('需复核', '“稍后处理”未定几点；返回待确认安全，但产品是否允许提示一个建议需决定。'),
  9: ('需复核', '“记得写周报”仍标为 reminder 意图，而不是计划执行；时间建议无误。'),
  15: ('需复核', '“下班后”被猜成17:30；若用户下班时间不同会误提醒。'),
  23: ('错误', '今天给领导交报表却到19:00才首次提醒；模型未留出常见工作时间内交付的机会。'),
  25: ('错误', '“后天发布新版本”仍只标计划，无后天达成结果的仅日期截止，语义与“今天上线”不一致。'),
  28: ('需复核', '交付日期为10月3日，提前一天提醒可能合理，但原话没要求提前；应显示为AI建议。'),
  29: ('错误', '12:40录入却返回9月25日10:00提醒，时间已过去。'),
  34: ('需复核', '“十分钟内”由录入时刻起算通常合理，但只提前5分钟提醒可能不够处理。'),
  39: ('需复核', '“周末之前”范围模糊；当前保留 period，首次提醒在周五上午可用。'),
  42: ('错误', '三点是会议开始时间，不是会议结果可询问时间；三点提醒“问结论”过早。'),
  46: ('需复核', '正确抽取19:30提醒和20:00截止，但 temporalIntent 写成 reminder 而不是 mixed。'),
  47: ('错误', '周五上线、下周一检查；只在下周一首次提醒，可能错过周五上线。单事项多动作需要分别提醒或明确标注范围。'),
  50: ('需复核', '“下周找时间”判为待确认，避免强猜，但完全没有下周提醒可能仍让用户忘记。'),
  53: ('需复核', '“后天再发给客户”仍只是计划，不含仅日期交付；和“明天交给客户”的解释不同。'),
  57: ('需复核', '同一句后天买东西的提醒从10:00变成09:00，日期一致但具体钟点未稳定。'),
  62: ('需复核', '“今天交给领导”同一输入的提醒从14:00变成12:55；时间有波动但未越截止日。'),
}

def short(s):
    if not s:return '—'
    try:return dt.datetime.fromisoformat(s).strftime('%m-%d %H:%M')
    except (ValueError,TypeError):return str(s)

def safe(s):return str(s).replace('|','\\|').replace('\n',' ') if s is not None else '—'

def deadline(result):
    x=result.get('deadline') or {}
    if x.get('kind') == 'none':return '无'
    value=short(x.get('at')) if x.get('kind')=='instant' else (x.get('day') or '')
    if x.get('kind')=='period':value=(value+' '+str(x.get('period') or '')).strip()
    return safe(f'{x.get("kind")}: {value} [{x.get("basis")}]')

results=p['cases']
scores=collections.Counter(ISSUES.get(x['id'],('可接受',''))[0] for x in results)
lines=[
 '# 个人提醒提示词 V3：同集复测与 V2 对照', '',
 '> **仅候选实验**：本轮没有修改正在运行的 App、用户事项和 OpenSpec 实现。所有输入为虚构句子。', '',
 '## 方法', '',
 '- 提示词：[V3 候选全文](evidence/reminder-prompt-v3.txt)；[64 条请求的完整 JSON 与实际提示词](evidence/prompt-evaluation-v3.json)。固定时间 `2026-09-29T12:40:00+08:00`、时区 `Asia/Shanghai`、同一 `deepseek-chat` 配置。',
 '- 与 [V2 实测](reminder-prompt-evaluation-v1.md) 使用相同的 56 句合成原话和 4 句各重复 2 次，共 64 次；每句一次独立请求，不做程序纠错重试。模型请求并发 4，因此比较的是单轮样本，而非严格受控的模型随机种子实验。',
 '- 人工按原话和产品边界判「可接受／需复核／错误」；无自动金标或通用准确率。`reminderBasis=explicit` 表示模型声称用户给了确切时刻，`inferred` 才是模型建议时刻。',
 '', '## 对照结论', '',
 '| 版本 | 可接受 | 需复核 | 错误 | 时间已过去 | 请求失败 |', '|---|---:|---:|---:|---:|---:|',
 '| V2 | 38 | 15 | 11 | 1（#33） | 0 |',
 f'| V3 | {scores["可接受"]} | {scores["需复核"]} | {scores["错误"]} | 1（#29） | {sum("error" in x for x in results)} |',
 '',
 '- V3 改进：#19 不再将“提醒九点”误当截止；#33 的过去时刻已改为12:45；#43 优先照顾今天先准备材料；#50 不再把“下周找时间处理”冒充完成期限；#57/#61 的后天买东西没有再提前到明天，也不再造硬截止。',
 '- V3 仍不可直接上线：#29 返回过去日期；#25 将“后天发布”漏判为日期交付；#42 把会议开始当成“问结论”的时刻；#47 面对交付+事后检查的两动作，仅提醒后者；#23 今天给领导报表却19:00才首次提醒。',
 '- 重复语句的**语义分类**较 V2 稳定，但同句选择的提醒钟点仍会变。这是模型推荐时间的不确定性；UI 须明确标注为建议，不能当成用户指定。',
 '', '## 逐句模型输出及评审', '',
 '时间为北京时间的 `月-日 时:分`；截止的 `day/period/instant` 为模型填报的精度，不代表已人工认可。证据片段、标题、uncertainty 均逐条列出；如需全部字段及原始 ISO8601 值见 JSON。', '',
 '| # | 类别 | 合成原话 | 标题 | 意图 | 提醒 [来源] | 截止 [来源] | 建议完成 | 模型依据 | 模型不确定说明 | 人工判定 |',
 '|---:|---|---|---|---|---|---|---|---|---|---|',
]
for x in results:
    r=x.get('result')
    if r is None:
        lines.append('| '+' | '.join([str(x['id']).zfill(2),safe(x['category']),safe(x['input'])]+['—']*7+[safe(x.get('error'))])+' |')
        continue
    label,reason=ISSUES.get(x['id'],('可接受','本轮未发现与目标冲突；不代表该句所有场景都正确。'))
    values=[str(x['id']).zfill(2),safe(x['category']),safe(x['input']),safe(r.get('title')),safe(r.get('temporalIntent')),
            safe(short(r.get('reminder'))+' ['+str(r.get('reminderBasis'))+']'),deadline(r),short(r.get('suggestedCompletion')),
            safe('；'.join(t.get('quote','') for t in r.get('timeEvidence') or []) or '—'),safe(r.get('uncertainty')),
            '**'+label+'**：'+safe(reason)]
    lines.append('| '+' | '.join(values)+' |')
lines += ['', '## 四句重复输入的稳定性', '',
 '| 原话 | 第一次 | 第二次 | 第三次 |', '|---|---|---|---|']
for text in ['后天给阿姨买东西','今天给领导一份报表','明天下班前配置导出任务','晚上十点下班后买菜回家']:
    subset=[x for x in results if x['input']==text]
    details=[f'#{x["id"]} {short(x["result"].get("reminder"))}／截止 {x["result"].get("deadline",{}).get("kind")}' for x in subset]
    lines.append('| '+' | '.join([safe(text),*details])+' |')
lines += ['', '## 下一轮建议（尚未实施）', '',
 '1. 在模型输出增加**行动列表**：一条原话含交付和事后检查时，各自有行动与时间；先按事实拆解，再决定单条事项是否能容纳多次提醒。仅靠单个 `reminder` 字段无法完整承载 #47。',
 '2. 对模糊期限只表达**日期/时间段及来源**；去除“给领导19:00”这类晚到无用的首次提醒，用通用的“离当日完成日越近，提醒越应留足处理时间”约束，而非列举人名。',
 '3. 在应用层保留**通用校验**：不得返回过去提醒、非法日期、不可能的截止顺序；校验未通过纠错一次后标待识别。提示词无法 100% 保证这些硬约束。',
 '4. “下周找时间／等反馈／晚点”需要产品规则决定是提供一条**定期检查提醒**还是标待确认；否则模型会安全地返回 null，事项可能仍被忘记。',
 '', '## 局限', '',
 '- 样本全为编写的合成语句，不使用真实用户事项，不包含模型错误后的二次纠正或真正的系统通知验证；比较分数来自人工观察，不是科学准确率。',
 '- 本次提示词和 JSON schema 仍只是候选稿。现有 Swift 代码不识别 V3 的新结构，直接替换字符串会造成应用解析失败。',
]
out.write_text('\n'.join(lines)+'\n')
print(out, 'counts',dict(scores), 'rows',len(results))

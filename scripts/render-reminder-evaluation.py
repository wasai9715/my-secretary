#!/usr/bin/env python3
"""Render the recorded synthetic DeepSeek evaluation without making network calls."""
import collections
import datetime as dt
import json
from pathlib import Path

source = Path('docs/design/evidence/prompt-evaluation-v1.json')
out = Path('docs/design/reminder-prompt-evaluation-v1.md')
data = json.loads(source.read_text())

# Human review of expected semantics; every id not listed passed the reviewed checks.
FINDINGS = {
  2: ('错误', '“稍后”无确定时间，却自选14:40与18:00；不应当作确定计划。'),
  7: ('需复核', '买水果建议20:00完成缺少依据，虽是建议也容易显得武断。'),
  8: ('错误', '提醒与建议完成都为12:00，没有留出买东西的处理时间。'),
  9: ('需复核', '“记得写”被分类为提醒意图，但没有明确提醒时刻；09:30为推断。'),
  13: ('错误', '“明早去银行”是计划执行，凭“明早”额外造出了期限。'),
  19: ('错误', '“九点提醒”是提醒时间，模型却也把九点作为明确完成截止。'),
  20: ('需复核', '只说了提醒日期，09:00是模型选择；reminderBasis不应标为explicit精确时刻。'),
  22: ('需复核', '“早上”无具体钟点，09:00可以建议，但不能把具体时刻标成explicit。'),
  23: ('需复核', '当天交付识别正确，但basis=explicit过强，应是语义推断。'),
  24: ('错误', '提醒18:00晚于自己建议的17:00完成；虽非硬截止，仍不实用。'),
  26: ('需复核', '今天上线识别到仅日期截止，但basis=explicit混淆了日期明示与完成约束推断。'),
  27: ('需复核', '周五发名单的提醒与建议完成同为10:00，缺少行动时间。'),
  29: ('需复核', '“月底”保留时间段，但建议完成被赋予18:00；需明确是模型建议。'),
  33: ('错误', '12:40录入却安排今天11:00提醒，返回过去时间。'),
  37: ('需复核', '“本周内”被建议周日17:00完成；没有工作日历，不应声称这是约定时刻。'),
  39: ('需复核', '将“周末之前”推断为周五下班前；已标不确定，但存在多种解释。'),
  43: ('错误', '“今天先准备材料”被忽略，首次提醒反而排到明天07:40。'),
  45: ('需复核', '明天早上未指定09:00，模型已写不确定但reminderBasis=explicit精确时刻。'),
  47: ('需复核', '明确要求下周一复查，晚于周五上线是正常后续动作；单条事项混两步，普通截止先后校验会误拦。'),
  50: ('错误', '“下周找时间处理”被误标成下周须完成的期限，计划日期与截止混淆。'),
  51: ('需复核', '周五还是周六未决定，reminder=null正确，但仍给了确定的周五建议完成。'),
  53: ('需复核', '“后天再发”可能是后天交付，当前只作为计划执行；交付边界不稳定。'),
  55: ('需复核', '要等明天别人确认才行动，09:00提醒是猜测；模型也承认时刻未知。'),
  57: ('错误', '同一句“后天买东西”这次提前到明天下午提醒，用户未要求提前。'),
  60: ('错误', '把下班十点误标成明确提醒时刻，用户并未说“提醒我”。'),
  61: ('错误', '同一句这次凭空补了“后天必须完成”的截止，20:00提醒又与建议完成相同。'),
}

def short_time(value):
    if not value: return '—'
    try: return dt.datetime.fromisoformat(value).strftime('%m-%d %H:%M')
    except (TypeError, ValueError): return str(value)

def clean(value): return str(value).replace('|','\\|').replace('\n',' ') if value is not None else '—'

def due(r):
    d=r.get('deadline') or {}
    kind=d.get('kind', '—')
    if kind=='none': return '无'
    value = short_time(d.get('at')) if kind=='instant' else (d.get('day') or '')
    if kind=='period': value = (value + ' ' + str(d.get('period') or '')).strip()
    return clean(f'{kind}: {value} [{d.get("basis", "—")}]')

lines = [
 '# 个人提醒提示词 V2：合成语句实测', '',
 '> 仅评估提案，不改变生产 App 的提示词、数据或事项时间。本报告中的原话全部是虚构测试语句。', '',
 '## 实验设置', '',
 f'- 固定本地当前时间：`{data["timestamp"]}`；时区 `{data["timeZone"]}`。相对日期均以此为准。',
 f'- 使用用户本机已配置的 `{data["model"]}` 接口，单次请求、JSON object 模式；并发 4，超时 35 秒；不发历史事项，未写入用户事项数据库。',
 '- **提示词、64 次请求完整 JSON 与耗时**：[`evidence/prompt-evaluation-v1.json`](evidence/prompt-evaluation-v1.json)；可运行 `python3 scripts/evaluate-reminder-prompt.py` 重测（会重新调用模型，花费 Token）。',
 '- 56 条不同的合成语句，另将 4 条关键句各重复两次，共 **64 次调用**；首次单句结果不能代表稳定性。测试时保留模型原始输出，下面的「错误／需复核／可接受」是人工按产品目标标注，不是模型自评分。',
 '', '## 结论（先看这些）', '',
]
counts=collections.Counter(FINDINGS.get(x['id'],('可接受',''))[0] for x in data['cases'])
lines += [f'- 64 次接口调用成功 {sum("result" in x for x in data["cases"])} 次；人工判定：**可接受 {counts["可接受"]}／需复核 {counts["需复核"]}／错误 {counts["错误"]}**。这些是本轮样本判定，不是总体准确率估计。',
 '- 系统性问题：**把计划误认成截止**（#13、#50、#61）；**把提醒时刻误认成截止**（#19）；**忽略同句更早的准备动作**（#43）；**输出过去时间**（#33）。',
 '- 重复性不稳：完全相同的“后天给阿姨买东西”在 #8/#57/#61 分别得到当天中午、前一天15:00、当天20:00，且第三次凭空出现截止日期。',
 '- 此提示词尚不能直接替换生产版：即使文本解释正确，还必须审查模型返回的状态、依据与时间顺序；程序对时间格式/过去时刻/期限关系的通用验证仍必要。',
 '', '## 逐句结果', '',
 '字段说明：提醒时间用本地 `月-日 时:分`；`[explicit/inferred/…]` 是模型返回的来源标签；截止的 `day/period/instant` 是模型返回的精度，并非评审认可；「依据」取模型 `timeEvidence.quote`。原始 JSON 包含完整标题、uncertainty、evidence meaning/precision、period、at、suggestedCompletion 等所有字段。', '',
 '| # | 类别 | 输入原话 | 模型标题 | 意图 | 首次提醒 [来源] | 截止 [依据分类] | 建议完成 | 时间依据 | 模型的不确定说明 | 判定与原因 |',
 '|---:|---|---|---|---|---|---|---|---|---|---|',
]
for c in data['cases']:
    r=c.get('result')
    if r is None:
        lines.append(f'| {c["id"]:02d} | {c["category"]} | {clean(c["input"])} | — | — | — | — | — | — | — | 请求错误：{clean(c.get("error"))} |')
        continue
    judgement,reason=FINDINGS.get(c['id'],('可接受','未发现与本轮目标冲突；不是保证输出永远正确。'))
    evidence='；'.join(e.get('quote','') for e in r.get('timeEvidence') or []) or '—'
    reminder=short_time(r.get('reminder')) + ' ['+str(r.get('reminderBasis','—'))+']'
    lines.append('| '+ ' | '.join([str(c['id']).zfill(2),clean(c['category']),clean(c['input']),clean(r.get('title')),clean(r.get('temporalIntent')),clean(reminder),due(r),clean(short_time(r.get('suggestedCompletion'))),clean(evidence),clean(r.get('uncertainty')),f'**{judgement}**：{clean(reason)}'])+' |')
lines += ['', '## 重复实验对照', '',
 '| 原话 | 首次结果 | 第二次 | 第三次 |', '|---|---|---|---|']
for text in ['后天给阿姨买东西', '今天给领导一份报表', '明天下班前配置导出任务', '晚上十点下班后买菜回家']:
    repeats=[c for c in data['cases'] if c['input']==text]
    desc=[]
    for c in repeats:
        r=c['result'];d=r.get('deadline') or {}
        desc.append(f'#{c["id"]} 提醒 {short_time(r.get("reminder"))}，截止 {d.get("kind","—")}')
    lines.append('| '+ ' | '.join([clean(text),*map(clean,desc)])+' |')
lines += ['', '## 上线前改进建议（等待用户审核）', '',
 '1. 将提示词中不一致的例句改成**有优先级的语义原则**：先确定行动对象和是否多动作，再分别抽取明确提醒、行动计划、交付义务、背景时间；「记得」与「十点下班」不得凭空升级为明确提醒/截止。',
 '2. 时间数据先保留**原话中的精度和出处**：仅日期、时间段、精确时刻；`basis=explicit` 仅指原话明确了这一类约束，不等于模型建议的具体钟点也由用户说出。修改 schema 时区分“日期明示”与“义务推断”。',
 '3. 增加通用一致性约束：首次提醒须在当前时刻之后；除用户明确要求“提前准备”或“事后复查”，不得把明日/后日计划静默前置到另一日；提醒不能与建议完成同刻，更不能晚于建议完成；带多个动作时不能只为次要动作设首次提醒。',
 '4. 对没有具体时刻的模糊词/依赖别人反馈的句子保留不确定性；不要自作主张设精确小时。出现无法确保有用提醒时返回 `uncertain`，应用显示待确认而不是静默接受。',
 '5. 重写提示词后保留同样的 56 条测试语句，再加入更多多动作、否定和截止跨天用例；至少复跑 3 次核心例句，分别统计**提取完整、意图分类、时间有效、时间实用、跨次稳定**，而不是只看 JSON 合法。',
 '', '## 局限', '',
 '- 单个时间锚点、单个模型、每个独特句子仅一次请求；4 句关键句重复 3 次。本次无法代表所有用户表达，也没有测真正提醒派发。',
 '- 提示词作为单一 system 消息发送，user 消息是 `原话：<虚构句子>`；无工具调用、无模型自行搜索；未执行生产变更。',
 '- 部分“今天给领导报表”是否算明确截止取决于产品语义；本表暂认为“仅日期交付”可推断，必须标注推断来源，不可当作原话说了具体几点。',
]
out.write_text('\n'.join(lines)+'\n')
print(out, 'cases',len(data['cases']),'scores',dict(counts))

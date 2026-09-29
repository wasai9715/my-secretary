#!/usr/bin/env python3
"""Offline prompt evaluation against user-configured model; synthetic inputs only.

Usage: python3 scripts/evaluate-reminder-prompt.py [output-json-path]
Reads local app model config in-memory; never prints/persists the token.
"""
import concurrent.futures
import datetime as dt
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request

NOW = dt.datetime(2026, 9, 29, 12, 40, tzinfo=dt.timezone(dt.timedelta(hours=8)))
TIMEZONE = "Asia/Shanghai"
PROMPT = """你是个人事项提醒助手。用户会输入一句简短的原话，请理解其中的行动和时间语义，并为该事项建议首次提醒时间。

当前本地时间：{current_local_datetime}
本地时区：{timezone}

只返回一个合法 JSON 对象，不输出 Markdown 或解释性文字。结构如下：

{{
  "title": "忠实压缩原话的短标题",
  "timeEvidence": [
    {{
      "quote": "原话中支持该时间判断的连续片段",
      "meaning": "reminder | planned_action | completion_deadline | contextual_time",
      "precision": "instant | day | period"
    }}
  ],
  "temporalIntent": "none | reminder | planned_action | completion_deadline | mixed | uncertain",
  "reminder": "带时区偏移量的 ISO8601 日期时间，或 null",
  "reminderBasis": "explicit | inferred | no_time_default | uncertain",
  "deadline": {{
    "kind": "none | day | period | instant",
    "day": "YYYY-MM-DD，或 null",
    "period": "原话中的时间段，例如「下班前」；没有则为 null",
    "at": "带时区偏移量的 ISO8601 日期时间，或 null",
    "basis": "explicit | context_inferred | none",
    "evidence": "原话中的依据；没有则为 null"
  }},
  "suggestedCompletion": "带时区偏移量的 ISO8601 日期时间，或 null",
  "uncertainty": "无疑问则为 null；否则简述不能确定的时间含义"
}}

判断原则：

1. 始终保留原话的含义。title 只能忠实缩写，不得添加任务对象、执行步骤或承诺。

2. 先分别识别：
   - 用户明确要求何时「提醒我」；
   - 用户打算何时执行一件事；
   - 一件事必须在何日、哪个时间段或哪个具体时刻之前达成；
   - 只是背景信息的时间，例如「晚上十点下班」不必然是「买菜必须在十点前完成」。
   一句话可以同时包含多种时间含义，不要因为有日期就自动把它解释为精确截止时刻。

3. 根据整个句子的行动语义判断完成期限，而不是只匹配「截止」「之前」等关键词。
   「今天给领导数据」「今天发布系统」可能表达当天须交付的结果，可标为仅日期截止，但 basis 应为 context_inferred，不能冒充原话明确给出的精确时刻。
   「明天记得写周报」主要表达明天计划处理；除非还有交付约束，不应凭空补一个明确截止。
   如果两种解释都有可能，使用 temporalIntent=uncertain 并说明分歧，不假装确定。

4. 严格保留时间精度：
   - 只知道哪一天：deadline.kind=day，仅填 day。
   - 说的是「下班前」「今晚」等时间段：deadline.kind=period，保留原词和日期，不擅自把它换成 17:00、18:00 或 23:59 的用户承诺。
   - 只有原话给出具体钟点，并且它确实约束完成时间：deadline.kind=instant，才填 at。
   模型为了安排提醒自行选择的时刻，不属于用户明确给出的截止时刻。

5. 安排 reminder：
   - 用户明确说了提醒时间：优先遵照，reminderBasis=explicit。
   - 有计划执行日期但未指定提醒时刻：在该计划日期选择有用的提醒时刻，reminderBasis=inferred；不得把未来日期的事项静默安排成今天的「无时间默认提醒」。
   - 有完成期限：根据期限远近及事项语义建议一个有用的首次提醒，尽量给用户留出处理时间；不得晚于明确的期限。建议提醒的时刻不是用户承诺的截止时刻。
   - 完全没有时间线索：reminder=null，reminderBasis=no_time_default，由应用在录入后 15 分钟提醒。
   - 时间含义无法可靠确定：reminder=null，reminderBasis=uncertain；不要借用 no_time_default 掩盖歧义。

6. 相对日期必须以提供的本地时间和时区计算。所有输出时刻必须包含时区偏移量。不得返回已经过去的首次提醒时间；若合理的计划时刻已经过去，应说明不确定性，而不是默默安排到过去。

7. suggestedCompletion 只能是帮助用户规划的建议，不能替代 deadline，也不能在没有依据时为每件事编造一个「今天下班前完成」。""".format(current_local_datetime=NOW.isoformat(), timezone=TIMEZONE)

# Use a separately versioned candidate without changing the original V2 prompt.
if os.environ.get("PROMPT_FILE"):
    PROMPT = (Path(os.environ["PROMPT_FILE"]).read_text()
              .replace("{current_local_datetime}", NOW.isoformat())
              .replace("{timezone}", TIMEZONE))

# Synthetic only: no real user content is read from the app's item database.
CASES = [
    ("无时间", "帮我查一下订单为什么没支付"),
    ("无时间", "领导让导一份销售数据，稍后处理"),
    ("无时间", "记得回运营的问题"),
    ("无时间", "把这个接口错误看一下"),
    ("无时间", "帮同事把测试账号开一下"),
    ("无时间", "收到需求后记得找产品确认"),
    ("计划日期", "明天帮妈妈买水果"),
    ("计划日期", "后天给阿姨买东西"),
    ("计划日期", "明天记得写周报"),
    ("计划日期", "周五整理报表"),
    ("计划日期", "下周二查一下库存差异"),
    ("计划日期", "10月2号去取快递"),
    ("计划日期", "明早去银行办事"),
    ("计划日期", "后天下午和设计师聊一下"),
    ("计划日期", "明天下班后顺路买菜"),
    ("计划日期", "今天晚上调整测试环境配置"),
    ("明确提醒", "下午三点提醒我回复运营"),
    ("明确提醒", "十分钟后叫我发邮件"),
    ("明确提醒", "明天九点提醒我去开会"),
    ("明确提醒", "10月2号提醒我买票"),
    ("明确提醒", "后天买东西，今天下午四点提醒我列清单"),
    ("明确提醒", "周五早上提醒我整理数据"),
    ("仅日期交付", "今天给领导一份报表"),
    ("仅日期交付", "明天把方案交给客户"),
    ("仅日期交付", "后天发布新版本"),
    ("仅日期交付", "今天上线策略系统"),
    ("仅日期交付", "周五发给运营最终名单"),
    ("仅日期交付", "10月3日提交申请"),
    ("仅日期交付", "月底要把需求文档交付给产品"),
    ("精确截止", "明天10点前给运营数据"),
    ("精确截止", "今晚八点之前把报表发给领导"),
    ("精确截止", "周五下午三点截止报名，提醒我提交"),
    ("精确截止", "下午一点前把 bug 修完"),
    ("精确截止", "十分钟内给我发截图"),
    ("时间段", "明天下班前配置导出任务"),
    ("时间段", "今晚把工作总结发出去"),
    ("时间段", "本周内完成财务核对"),
    ("时间段", "明天中午前整理好会议材料"),
    ("时间段", "周末之前给负责人反馈"),
    ("上下文时间", "晚上十点下班后买菜回家"),
    ("上下文时间", "等运营明天反馈后再查这个问题"),
    ("上下文时间", "客户三点开会，记得问一下结论"),
    ("上下文时间", "明天八点开会，今天先准备材料"),
    ("混合", "明天十点交报告，今天四点提醒我准备"),
    ("混合", "后天交数据，明天早上提醒我核对"),
    ("混合", "今晚八点前确认结果，七点半提醒我"),
    ("混合", "周五上线，下周一再提醒我检查结果"),
    ("歧义", "有空的时候提醒我看看合同"),
    ("歧义", "晚点把资料给他"),
    ("歧义", "下周找时间处理账单"),
    ("歧义", "下周五还是周六找客户聊一下"),
    ("否定与修正", "今天不用做，明天再处理退款"),
    ("否定与修正", "不是今天发给客户，是后天再发"),
    ("否定与修正", "下周一前不用提醒，周二再联系供应商"),
    ("否定与修正", "今天先别发报表，等明天确认后再说"),
    ("否定与修正", "明天十点前交的事取消了，后天再重新确认"),
]
REPEAT = [("重复稳定性", "后天给阿姨买东西"), ("重复稳定性", "今天给领导一份报表"), ("重复稳定性", "明天下班前配置导出任务"), ("重复稳定性", "晚上十点下班后买菜回家")]


def request_one(index, kind, text, cfg):
    body = {
        "model": cfg["model"],
        "messages": [
            {"role": "system", "content": PROMPT},
            {"role": "user", "content": "原话：" + text},
        ],
        "response_format": {"type": "json_object"},
        "stream": False,
    }
    req = urllib.request.Request(
        cfg["endpoint"],
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": "Bearer " + cfg["token"], "Content-Type": "application/json"},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=35) as response:
            envelope = json.load(response)
        output = json.loads(envelope["choices"][0]["message"]["content"])
        return {"id": index, "category": kind, "input": text, "result": output, "seconds": round(time.monotonic()-started, 2)}
    except urllib.error.HTTPError as error:
        return {"id": index, "category": kind, "input": text, "error": "HTTP " + str(error.code)}
    except Exception as error:
        return {"id": index, "category": kind, "input": text, "error": type(error).__name__}


def main():
    config_path = Path.home() / "Library/Application Support/MySecretary/model.json"
    cfg = json.loads(config_path.read_text())
    if not cfg.get("token") or not cfg.get("verified") or not cfg.get("endpoint", "").startswith("https://"):
        raise SystemExit("Model configuration unavailable or not verified")
    cases = CASES + REPEAT * 2
    output_path = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/design/evidence/prompt-evaluation-v1.json")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(request_one, index, kind, text, cfg) for index, (kind, text) in enumerate(cases, 1)]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
            print(f"{len(results)}/{len(cases)}", flush=True)
    output = {"timestamp": NOW.isoformat(), "timeZone": TIMEZONE, "model": cfg["model"], "prompt": PROMPT, "cases": sorted(results, key=lambda r: r["id"])}
    output_path.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    print("saved", output_path, "success", sum("result" in r for r in results), "errors", sum("error" in r for r in results))


if __name__ == "__main__":
    main()

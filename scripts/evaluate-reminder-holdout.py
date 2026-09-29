#!/usr/bin/env python3
"""Held-out synthetic utterances not used when designing candidate V10/V11."""
import concurrent.futures
import json
from pathlib import Path
import runpy

namespace=runpy.run_path('scripts/evaluate-reminder-prompt.py')
CASES=[
 ('近期限','今天下午一点前给同事发确认邮件'),
 ('近期限','十五分钟内把报告发给经理'),
 ('近期限','今天十二点半前把截图交上去'),
 ('明确提醒','明天下午两点提醒我看会议纪要'),
 ('明确提醒','下周三提醒我去取证件'),
 ('计划日期','后天去超市买洗衣液'),
 ('计划日期','周六找时间给电脑清灰'),
 ('计划日期','明晚要去接朋友'),
 ('仅日期交付','明天上线支付系统'),
 ('仅日期交付','周四之前把清单发给财务'),
 ('仅日期交付','月底提交技术方案'),
 ('时间段','明天午饭前把文档交给产品'),
 ('时间段','今晚睡觉前复盘今天的异常'),
 ('背景时间','客户下午四点开始培训，结束后问他感受'),
 ('背景时间','晚上九点下班后买个充电器'),
 ('依赖触发','等财务明天核对完再提醒我付款'),
 ('多行动','周五上线功能，下周二检查报错'),
 ('多行动','今天整理清单，明天十点前发给客户'),
 ('多行动','明天预约体检，周五去医院检查'),
 ('否定修正','不要今天提醒我，明天下午再处理售后'),
 ('否定修正','昨天说的周三交付取消了，改成周五交给运营'),
 ('相对日期','下周一之前不要叫我，周二上午联系代理商'),
 ('歧义','下周五或者周六找人确认地址'),
 ('无时间','帮运营看一下退款数据'),
]
base=Path.home()/'Library/Application Support/MySecretary/model.json'
config=json.loads(base.read_text())
assert config.get('verified') and config.get('endpoint','').startswith('https://') and config.get('token')
results=[]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    futures=[pool.submit(namespace['request_one'],i,category,text,config) for i,(category,text) in enumerate(CASES,1)]
    for f in concurrent.futures.as_completed(futures):results.append(f.result())
path=Path('docs/design/evidence/prompt-holdout-v11.json')
path.write_text(json.dumps({'timestamp':namespace['NOW'].isoformat(),'timeZone':namespace['TIMEZONE'],'model':config['model'],'prompt':namespace['PROMPT'],'cases':sorted(results,key=lambda r:r['id'])},ensure_ascii=False,indent=2)+'\n')
print(path,'cases',len(results),'errors',sum('error' in x for x in results))

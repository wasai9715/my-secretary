import Foundation
import SecretaryCore

func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw RecognitionError.invalid("校验失败：\(label)") }
    print("✓ \(label)")
}

func run() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = try LocalFiles(directory: directory)
    try files.saveConfiguration(.init(token: "fake-test-key"))
    try check(try files.loadConfiguration().token == "fake-test-key", "模型配置读写")
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("model.json").path)
    try check(attributes[.posixPermissions] as? Int == 0o600, "Token 文件仅用户可读写")
    try check(try files.loadSettings().shortcutKey == 25, "默认快捷键避开系统搜索")
    var old = ReminderSettings()
    old.shortcutKey = 49
    old.shortcutModifiers = 3
    try files.saveSettings(old)
    let migrated = try files.loadSettings()
    try check(migrated.shortcutKey == 25 && migrated.shortcutModifiers == 0x1200, "旧版冲突快捷键自动迁移")
    var custom = migrated
    custom.shortcutKey = 40
    custom.shortcutModifiers = 0x900
    custom.shortcutDisplay = "⌥⌘K"
    try files.saveSettings(custom)
    let restoredShortcut = try files.loadSettings()
    try check(restoredShortcut.shortcutKey == 40 && restoredShortcut.shortcutModifiers == 0x900
              && restoredShortcut.shortcutDisplay == "⌥⌘K", "自由录制快捷键持久保存并在重启后恢复")

    let captured = Date(timeIntervalSince1970: 1_801_000_344) // pinned UTC instant
    let shanghai = TimeZone(secondsFromGMT: 8 * 3600)!
    let context = DeepSeekClient.timeContext(now: captured, timeZone: shanghai)
    try check(context.contains("+08:00") && !context.contains("Z，时区"), "模型收到带偏移量的本地当前时间")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try ItemStore(path: files.databasePath)
    var item = ReminderItem(text: "明天10点前给数据", now: now)
    try store.upsert(item)
    try store.upsert(ReminderItem(text: item.text, now: now))
    try check(try store.all().count == 2, "重复原话分别保存")
    let deadline = now.addingTimeInterval(20 * 3600)
    do {
        try item.apply(.init(title: "给数据", reminder: deadline.addingTimeInterval(3600), deadline: deadline, suggestedCompletion: nil), now: now)
        throw RecognitionError.invalid("未拒绝晚于截止的首次提醒")
    } catch RecognitionError.invalid(let error) {
        try check(error == "明确截止事项必须有早于截止的首次提醒", "明确截止校验")
    }
    try item.apply(.init(title: "给数据", reminder: deadline.addingTimeInterval(-3600), deadline: deadline, suggestedCompletion: nil), now: now)
    try check(item.deadline == deadline && item.suggestedCompletion == nil, "明确截止不冒充建议完成")
    try store.upsert(item)
    try check(try ItemStore(path: files.databasePath).all().contains(where: { $0.id == item.id && $0.deadline == deadline }), "重启后恢复事项")
    var legacyPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
    for key in ["deadlinePeriod", "deadlinePeriodDay", "scheduledDay", "reminderSource", "timeEvidence", "needsSeparateEntries"] {
        legacyPayload.removeValue(forKey: key)
    }
    let oldDecoded = try JSONDecoder().decode(ReminderItem.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
    try check(oldDecoded.id == item.id && oldDecoded.deadlinePeriod == nil && oldDecoded.needsSeparateEntries == nil,
              "旧版事项不含新字段仍可恢复")

    let clicked = now.addingTimeInterval(1200)
    do {
        try item.snooze(until: deadline.addingTimeInterval(3600), now: clicked)
        throw RecognitionError.invalid("未警告越过截止")
    } catch RecognitionError.deadlineConflict { print("✓ 越过明确截止须确认") }
    try item.snooze(until: clicked.addingTimeInterval(1800), now: clicked)
    try check(item.nextReminder == clicked.addingTimeInterval(1800) && item.notificationsSent == 0, "点击时起算并重置轮次")

    let dateOnlyNow = Date()
    let dayOnly = DateFormatter()
    dayOnly.dateFormat = "yyyy-MM-dd"
    let today = dayOnly.string(from: dateOnlyNow)
    var launch = ReminderItem(text: "今天上线策略系统", now: dateOnlyNow)
    try launch.apply(.init(title: "上线策略系统", reminder: dateOnlyNow.addingTimeInterval(900), deadline: nil, deadlineDay: today, suggestedCompletion: nil), now: dateOnlyNow)
    try check(launch.deadlineDay == today && launch.deadline == nil, "仅日期截止保留今天，不伪造截止时刻")
    try check(launch.firstReminder == dateOnlyNow.addingTimeInterval(900), "仅日期截止与15分钟首次提醒可并存")
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"
    let plannedDay = dayFormatter.string(from: tomorrow)
    let iso = ISO8601DateFormatter()
    iso.timeZone = .current
    let reminderISO = iso.string(from: tomorrow)
    func action(_ label: String, day: String?, reminder: String?, source: String,
                evidence: String, cutoff: [String: Any]? = nil) -> [String: Any] {
        ["action": label, "actionEvidence": evidence,
         "scheduledDay": day as Any? ?? NSNull(), "reminderAt": reminder as Any? ?? NSNull(),
         "reminderSource": source, "reminderEvidence": NSNull(),
         "deadline": cutoff ?? ["kind":"none", "day":NSNull(), "period":NSNull(), "at":NSNull(), "basis":"none", "evidence":NSNull()],
         "uncertainty": NSNull()]
    }
    func payload(_ actions: [[String: Any]], confirmation: Bool = false) throws -> String {
        let raw: [String: Any] = ["title":"买东西", "actions":actions,
            "requiresConfirmation": confirmation,
            "confirmationReason": confirmation ? "时间需要确认" : NSNull()]
        return String(data: try JSONSerialization.data(withJSONObject: raw), encoding: .utf8)!
    }
    let futureAction = action("给阿姨买东西", day: plannedDay, reminder: reminderISO,
                              source: "inferred", evidence: "给阿姨买东西")
    let futureText = "明天给阿姨买东西"
    switch try DeepSeekClient.decodeInterpretation(payload([futureAction]), originalText: futureText, now: now) {
    case .schedule(let interpretation):
        try check(interpretation.scheduledDay == plannedDay && interpretation.reminder == tomorrow,
                  "计划日期由模型提供，程序不匹配明天关键词")
    default: throw RecognitionError.invalid("有效单行动未安排")
    }
    var absent = futureAction
    absent["reminderAt"] = NSNull()
    do {
        _ = try DeepSeekClient.decodeInterpretation(payload([absent]), originalText: futureText, now: now)
        throw RecognitionError.invalid("计划日期缺提醒却被默认为15分钟")
    } catch RecognitionError.invalid(let reason) {
        try check(reason.contains("有时间线索"), "未来计划空提醒拒绝静默兜底")
    }
    let doubleText = "今天列清单，明天给阿姨买东西"
    let firstAction = action("列清单", day: today, reminder: iso.string(from: now.addingTimeInterval(1800)),
                             source: "inferred", evidence: "列清单")
    switch try DeepSeekClient.decodeInterpretation(payload([firstAction, futureAction]), originalText: doubleText, now: now) {
    case .separateEntries(let reason):
        try check(reason.contains("分两次录入"), "两个行动仅提示分录，不静默安排后者")
        var pending = ReminderItem(text: doubleText, now: now)
        pending.fail(reason, now: now, needsSeparateEntries: true)
        try store.upsert(pending)
        try check(try store.all().contains(where: { $0.id == pending.id && $0.needsSeparateEntries == true && $0.recognition == .needsAttention }), "分录提示持久保留且可见")
    default: throw RecognitionError.invalid("两个行动被当作一项安排")
    }
    do {
        _ = try DeepSeekClient.decodeInterpretation(payload([futureAction], confirmation: true), originalText: futureText, now: now)
        throw RecognitionError.invalid("待确认却错误安排具体提醒")
    } catch RecognitionError.invalid(let reason) {
        try check(reason.contains("待确认"), "待确认不得冒充已安排")
    }
    var uncertainty = futureAction
    uncertainty["reminderAt"] = NSNull()
    uncertainty["reminderSource"] = "uncertain"
    switch try DeepSeekClient.decodeInterpretation(payload([uncertainty], confirmation: true), originalText: futureText, now: now) {
    case .needsConfirmation: print("✓ 不确定时间安全保留待处理")
    default: throw RecognitionError.invalid("不确定时间错误安排")
    }
    let cutoffISO = iso.string(from: now.addingTimeInterval(24 * 3600))
    let beforeCutoffISO = iso.string(from: now.addingTimeInterval(23 * 3600))
    let cutoffFields: [String: Any] = ["kind":"instant", "day":plannedDay,
        "period":NSNull(), "at":cutoffISO, "basis":"explicit", "evidence":"明天10点前"]
    let cutoffAction = action("给运营数据", day: plannedDay, reminder: beforeCutoffISO,
                              source: "inferred", evidence: "给运营数据", cutoff: cutoffFields)
    switch try DeepSeekClient.decodeInterpretation(payload([cutoffAction]), originalText: "明天10点前给运营数据", now: now) {
    case .schedule(let parsed):
        try check(parsed.deadline == now.addingTimeInterval(24 * 3600) && parsed.reminder == now.addingTimeInterval(23 * 3600),
                  "精确截止与提前提醒分别识别")
    default: throw RecognitionError.invalid("精确截止没有被安排")
    }
    let periodFields: [String: Any] = ["kind":"period", "day":plannedDay,
        "period":"下班前", "at":NSNull(), "basis":"explicit", "evidence":"明天下班前"]
    let periodAction = action("交任务", day: plannedDay, reminder: beforeCutoffISO,
                              source: "inferred", evidence: "交任务", cutoff: periodFields)
    switch try DeepSeekClient.decodeInterpretation(payload([periodAction]), originalText: "明天下班前交任务", now: now) {
    case .schedule(let parsed):
        try check(parsed.deadline == nil && parsed.deadlinePeriod == "下班前" && parsed.deadlinePeriodDay == plannedDay,
                  "模糊下班前保留原话时段，不虚构精确时刻")
    default: throw RecognitionError.invalid("时间段截止没有被安排")
    }
    let emptyTime = action("查订单", day: nil, reminder: nil, source: "default_15min", evidence: "查订单")
    switch try DeepSeekClient.decodeInterpretation(payload([emptyTime]), originalText: "查订单", now: now) {
    case .schedule(let parsed):
        var captured = ReminderItem(text: "查订单", now: now)
        try captured.apply(parsed, now: now)
        try check(captured.firstReminder == now.addingTimeInterval(900), "确实无时间线索才使用15分钟默认值")
    default: throw RecognitionError.invalid("无时间事项未进入默认提醒")
    }
    let prompt = try DeepSeekClient.systemPrompt(now: now)
    try check(!prompt.contains("今天2026-09-29") && prompt.contains("时区") && prompt.contains("分两次录入"), "生产提示词没有写死实验日期且说明分录")

    // Replay selected *recorded* model responses: no network, no user records.
    for (file, expected) in [
        ("docs/design/evidence/prompt-evaluation-v11.json", [47: "split"]),
        ("docs/design/evidence/prompt-holdout-v11.json", [1: "reject", 3: "reject", 16: "reject"]),
    ] {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: Any]
        let capture = ISO8601DateFormatter().date(from: fixture["timestamp"] as! String)!
        let cases = fixture["cases"] as! [[String: Any]]
        for (id, outcome) in expected {
            let testcase = cases.first(where: { $0["id"] as? Int == id })!
            let text = String(data: try JSONSerialization.data(withJSONObject: testcase["result"]!), encoding: .utf8)!
            do {
                let decision = try DeepSeekClient.decodeInterpretation(text, originalText: testcase["input"] as! String, now: capture)
                guard outcome == "split", case .separateEntries = decision else {
                    throw RecognitionError.invalid("模型危险输出被错误接受：样本\(id)")
                }
            } catch RecognitionError.invalid {
                guard outcome == "reject" else { throw RecognitionError.invalid("多行动样本没有提示分录") }
            }
        }
    }
    print("✓ 实录模型输出：多行动分录，过去时间和待确认冲突均被拦截")
    var noTime = ReminderItem(text: "查订单", now: now)
    try noTime.apply(.init(title: "查订单", reminder: nil, deadline: nil, suggestedCompletion: nil), now: now)
    try check(noTime.nextReminder == now.addingTimeInterval(900) && noTime.suggestedCompletion == nil, "无时间线索默认15分钟")
    var failed = ReminderItem(text: "明天给数据", now: now)
    failed.fail("请求失败", now: now)
    try check(failed.recognition == .needsAttention && failed.nextReminder == now.addingTimeInterval(900), "待识别与默认提醒区分")
}

do {
    try run()
    print("全部核心检查通过")
} catch {
    fputs("核心检查失败：\(error)\n", stderr)
    exit(1)
}

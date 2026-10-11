import Foundation
import SecretaryCore
import CSQLite3

func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw RecognitionError.invalid("校验失败：\(label)") }
    print("✓ \(label)")
}

func run() async throws {
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
    // Exercise migration from actual persisted legacy rows, not just an in-memory decode.
    let legacyPath = directory.appendingPathComponent("legacy.sqlite3").path
    let legacyStore = try ItemStore(path: legacyPath)
    try legacyStore.upsert(item)
    var legacyDB: OpaquePointer?
    guard sqlite3_open(legacyPath, &legacyDB) == SQLITE_OK else { throw RecognitionError.invalid("无法建立迁移测试数据库") }
    let legacyJSON = try JSONSerialization.data(withJSONObject: legacyPayload)
    var legacyStatement: OpaquePointer?
    guard sqlite3_prepare_v2(legacyDB, "UPDATE items SET payload=? WHERE id=?", -1, &legacyStatement, nil) == SQLITE_OK else {
        sqlite3_close(legacyDB)
        throw RecognitionError.invalid("无法准备旧数据")
    }
    let legacyBind = legacyJSON.withUnsafeBytes { sqlite3_bind_blob(legacyStatement, 1, $0.baseAddress, Int32(legacyJSON.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    let legacyID = item.id.uuidString
    let idBind = legacyID.withCString { sqlite3_bind_text(legacyStatement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    let legacyStep = legacyBind == SQLITE_OK && idBind == SQLITE_OK ? sqlite3_step(legacyStatement) : SQLITE_ERROR
    sqlite3_finalize(legacyStatement)
    sqlite3_close(legacyDB)
    try check(legacyStep == SQLITE_DONE, "构造磁盘旧版本事项")
    let migratedItem = try ItemStore(path: legacyPath).all().first
    try check(migratedItem?.id == item.id && migratedItem?.nextReminder == item.nextReminder && migratedItem?.notificationsSent == item.notificationsSent,
              "旧版本事项磁盘重开保留提醒状态")
    let previous = try legacyStore.all().first!
    var updated = previous
    updated.notificationsSent = 2
    updated.nextReminder = now.addingTimeInterval(7200)
    try legacyStore.upsert(updated)
    let persistedUpdate = try ItemStore(path: legacyPath).all().first
    try check(persistedUpdate?.notificationsSent == 2 && persistedUpdate?.nextReminder == updated.nextReminder,
              "提醒轮次与下次提醒同一记录原子更新")
    var blockedDB: OpaquePointer?
    guard sqlite3_open(legacyPath, &blockedDB) == SQLITE_OK else { throw RecognitionError.invalid("无法准备原子失败测试") }
    let trigger = sqlite3_exec(blockedDB, "CREATE TRIGGER block_update BEFORE UPDATE ON items BEGIN SELECT RAISE(ABORT, 'test abort'); END", nil, nil, nil)
    sqlite3_close(blockedDB)
    try check(trigger == SQLITE_OK, "准备写入中断测试")
    updated.notificationsSent = 3
    updated.nextReminder = nil
    do {
        try legacyStore.upsert(updated)
        throw RecognitionError.invalid("写入中断未报告错误")
    } catch RecognitionError.connection { print("✓ 写入中断显式报错") }
    let afterAbort = try ItemStore(path: legacyPath).all().first
    try check(afterAbort?.notificationsSent == 2 && afterAbort?.nextReminder == persistedUpdate?.nextReminder,
              "写入失败后轮次与时间均保留旧值")

    let corruptPath = directory.appendingPathComponent("corrupt.sqlite3").path
    let corruptStore = try ItemStore(path: corruptPath)
    try corruptStore.upsert(item)
    var corruptDB: OpaquePointer?
    guard sqlite3_open(corruptPath, &corruptDB) == SQLITE_OK else { throw RecognitionError.invalid("无法建立损坏测试数据库") }
    let corruptStep = sqlite3_exec(corruptDB, "UPDATE items SET payload=x'7b'", nil, nil, nil)
    sqlite3_close(corruptDB)
    try check(corruptStep == SQLITE_OK, "构造损坏的事项记录")
    do {
        _ = try ItemStore(path: corruptPath).all()
        throw RecognitionError.invalid("损坏数据被当作空列表")
    } catch RecognitionError.connection(let message) {
        try check(message.contains("数据损坏") && message.contains(item.id.uuidString), "损坏事项明确报错而非静默丢失")
    }

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
    do {
        _ = try DeepSeekClient.decodeInterpretation("not JSON", originalText: futureText, now: now)
        throw RecognitionError.invalid("无效 JSON 被接受")
    } catch RecognitionError.invalid(let reason) {
        try check(reason.contains("结构"), "无效 JSON 被通用结构校验拒绝")
    }
    var invalidDate = futureAction
    invalidDate["reminderAt"] = "2027-02-30T09:00:00+08:00"
    do {
        _ = try DeepSeekClient.decodeInterpretation(payload([invalidDate]), originalText: futureText, now: now)
        throw RecognitionError.invalid("非法日历日期被接受")
    } catch RecognitionError.invalid { print("✓ 非法日历日期被拒绝") }
    var invalidEvidence = futureAction
    invalidEvidence["actionEvidence"] = "原话中不存在的语句"
    do {
        _ = try DeepSeekClient.decodeInterpretation(payload([invalidEvidence]), originalText: futureText, now: now)
        throw RecognitionError.invalid("虚构出处被接受")
    } catch RecognitionError.invalid(let reason) {
        try check(reason.contains("依据"), "出处必须为原话连续片段")
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
    // Exercise the actual interpretation pipeline with deterministic model responses.
    // No network, credentials or user database are touched.
    actor Replies {
        var values: [Result<String, RecognitionError>]
        var calls = 0
        init(_ values: [Result<String, RecognitionError>]) { self.values = values }
        func next() throws -> String {
            calls += 1
            return try values.removeFirst().get()
        }
    }
    let corrected = try payload([futureAction])
    let correctionReplies = Replies([.success("not JSON"), .success(corrected)])
    let correctingClient = DeepSeekClient(configuration: .init()) { _, _ in try await correctionReplies.next() }
    guard case .schedule = try await correctingClient.interpret(futureText, now: now) else {
        throw RecognitionError.invalid("纠错后没有安排有效事项")
    }
    let correctionCount = await correctionReplies.calls
    try check(correctionCount == 2, "假模型无效 JSON 仅纠错一次")

    let invalidReplies = Replies([.success("not JSON"), .success("still invalid")])
    let invalidClient = DeepSeekClient(configuration: .init()) { _, _ in try await invalidReplies.next() }
    var invalidPending = ReminderItem(text: futureText, now: now)
    do {
        _ = try await invalidClient.interpret(futureText, now: now)
        throw RecognitionError.invalid("两次无效 JSON 未报错")
    } catch RecognitionError.invalid {
        invalidPending.fail("模型结构无效", now: now)
        try store.upsert(invalidPending)
    }
    let invalidCount = await invalidReplies.calls
    try check(invalidCount == 2 &&
              (try store.all()).contains(where: { $0.id == invalidPending.id && $0.originalText == futureText && $0.recognition == .needsAttention && $0.firstReminder == nil }),
              "假模型两次无效后原话持久待识别，未静默排期")

    let timeoutReplies = Replies([.failure(.connection("请求超时"))])
    let timeoutClient = DeepSeekClient(configuration: .init()) { _, _ in try await timeoutReplies.next() }
    var timeoutPending = ReminderItem(text: futureText, now: now)
    do {
        _ = try await timeoutClient.interpret(futureText, now: now)
        throw RecognitionError.invalid("超时未报错")
    } catch RecognitionError.connection {
        timeoutPending.fail("请求超时", now: now)
        try store.upsert(timeoutPending)
    }
    let timeoutCount = await timeoutReplies.calls
    try check(timeoutCount == 1 &&
              (try store.all()).contains(where: { $0.id == timeoutPending.id && $0.originalText == futureText && $0.recognition == .needsAttention && $0.firstReminder == nil }),
              "假模型超时不纠错，原话持久待识别")

    let splitReplies = Replies([.success(try payload([firstAction, futureAction]))])
    let splitClient = DeepSeekClient(configuration: .init()) { _, _ in try await splitReplies.next() }
    guard case .separateEntries = try await splitClient.interpret(doubleText, now: now) else {
        throw RecognitionError.invalid("多行动没有提示分录")
    }
    let splitCount = await splitReplies.calls
    try check(splitCount == 1, "假模型多行动直接分录，不尝试纠错")

    var expiredDuringResponse = ReminderItem(text: futureText, now: now)
    try expiredDuringResponse.apply(.init(title: "已到时间", reminder: now.addingTimeInterval(30),
                                            deadline: nil, suggestedCompletion: nil),
                                    now: now.addingTimeInterval(120))
    try check(expiredDuringResponse.nextReminder == now.addingTimeInterval(120),
              "模型响应期间刚过期的提醒立即到期，不进入失败状态")

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

    let dueAt = now.addingTimeInterval(900)
    var scheduled = ReminderItem(text: "需要三轮提醒", now: now)
    try scheduled.apply(.init(title: "三轮提醒", reminder: dueAt, deadline: nil, suggestedCompletion: nil), now: now)
    try check(ReminderSchedule.due([scheduled], at: dueAt.addingTimeInterval(-1)).isEmpty, "未到期不派发")
    try check(ReminderSchedule.due([scheduled], at: dueAt).count == 1, "首次到期")
    let firstSent = ReminderSchedule.afterDispatch(scheduled, at: dueAt)
    try check(firstSent.notificationsSent == 1 && firstSent.nextReminder == dueAt.addingTimeInterval(1800), "首次真实派发后30分钟重试")
    let secondAt = firstSent.nextReminder!
    let secondSent = ReminderSchedule.afterDispatch(firstSent, at: secondAt)
    try check(secondSent.notificationsSent == 2 && secondSent.nextReminder == secondAt.addingTimeInterval(7200), "第二次真实派发后2小时重试")
    let thirdSent = ReminderSchedule.afterDispatch(secondSent, at: secondSent.nextReminder!)
    try check(thirdSent.notificationsSent == 3 && thirdSent.nextReminder == nil && thirdSent.status == .open, "第三次派发后停止单条重试但保留未完成")
    var postponed = thirdSent
    try postponed.snooze(until: secondAt.addingTimeInterval(900), now: secondAt)
    try check(postponed.notificationsSent == 0 && postponed.nextReminder == secondAt.addingTimeInterval(900), "主动推迟新轮次从操作时起算")
    var pendingRecognition = failed
    try check(ReminderSchedule.due([pendingRecognition], at: now.addingTimeInterval(900)).count == 1, "待识别15分钟提示")
    pendingRecognition = ReminderSchedule.afterDispatch(pendingRecognition, at: now.addingTimeInterval(900))
    try check(pendingRecognition.notificationsSent == 1 && pendingRecognition.nextReminder == nil, "待识别提示不反复发送")
    var digestCalendar = Calendar(identifier: .gregorian)
    digestCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var digestSettings = ReminderSettings()
    let firstDigest = digestCalendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 17, minute: 0))!
    try check(!ReminderSchedule.shouldSendDigest(at: firstDigest.addingTimeInterval(-60), settings: digestSettings, calendar: digestCalendar) &&
              ReminderSchedule.shouldSendDigest(at: firstDigest, settings: digestSettings, calendar: digestCalendar),
              "每日默认17:00到点才汇总")
    var legacySettingsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(digestSettings)) as! [String: Any]
    legacySettingsJSON.removeValue(forKey: "lastDigestSlot")
    let decodedLegacy = try JSONDecoder().decode(ReminderSettings.self, from: JSONSerialization.data(withJSONObject: legacySettingsJSON))
    try check(decodedLegacy.lastDigestSlot == nil, "旧设置文件可读取")
    digestSettings.lastDigestDay = ReminderSchedule.digestDay(at: firstDigest, calendar: digestCalendar)
    try check(!ReminderSchedule.shouldSendDigest(at: firstDigest.addingTimeInterval(60), settings: digestSettings, calendar: digestCalendar),
              "旧设置当天已汇总时升级不补发")
    digestSettings.lastDigestSlot = ReminderSchedule.digestSlot(at: firstDigest, settings: digestSettings, calendar: digestCalendar)
    try check(!ReminderSchedule.shouldSendDigest(at: firstDigest.addingTimeInterval(3600), settings: digestSettings, calendar: digestCalendar) &&
              ReminderSchedule.shouldSendDigest(at: firstDigest.addingTimeInterval(24 * 3600), settings: digestSettings, calendar: digestCalendar),
              "同一设定时间只汇总一次，隔日继续")
    // Changing today's configured time creates a new occurrence, not a second
    // send of the same occurrence. A legacy day marker must not suppress it.
    digestSettings.digestHour = 18
    digestSettings.digestMinute = 34
    try check(!ReminderSchedule.shouldSendDigest(at: firstDigest.addingTimeInterval(93 * 60), settings: digestSettings, calendar: digestCalendar) &&
              ReminderSchedule.shouldSendDigest(at: firstDigest.addingTimeInterval(94 * 60), settings: digestSettings, calendar: digestCalendar),
              "当天改汇总时间后新时间到点可汇总")
    digestSettings.lastDigestSlot = ReminderSchedule.digestSlot(at: firstDigest.addingTimeInterval(94 * 60), settings: digestSettings, calendar: digestCalendar)
    try check(!ReminderSchedule.shouldSendDigest(at: firstDigest.addingTimeInterval(95 * 60), settings: digestSettings, calendar: digestCalendar),
              "同一时间只汇总一次")
    digestSettings.digestHour = 9
    digestSettings.digestMinute = 35
    try check(ReminderSchedule.shouldSendDigest(at: firstDigest.addingTimeInterval(24 * 3600 - 7 * 3600 - 25 * 60), settings: digestSettings, calendar: digestCalendar),
              "自定义每日时分生效")
    let digestAt = dueAt.addingTimeInterval(6 * 3600)
    var futureSnoozed = scheduled
    try futureSnoozed.snooze(until: digestAt.addingTimeInterval(24 * 3600), now: dueAt)
    try check(ReminderSchedule.digestPending([scheduled, futureSnoozed, pendingRecognition], at: digestAt).map(\.id) == [scheduled.id, pendingRecognition.id],
              "每日汇总排除未来主动推迟，保留已到期与待识别")
    try check(ReminderSchedule.digestPending([scheduled, pendingRecognition], at: digestAt.addingTimeInterval(24 * 3600)).count == 2,
              "跨日汇总仍包含未处理事项")
    let reopened = dueAt.addingTimeInterval(2 * 24 * 3600)
    var other = ReminderItem(text: "另一个逾期事项", now: now)
    try other.apply(.init(title: "另一个", reminder: dueAt, deadline: nil, suggestedCompletion: nil), now: now)
    let catchUp = ReminderSchedule.due([scheduled, other], at: reopened)
    try check(catchUp.count == 2 && catchUp.allSatisfy { $0.notificationsSent == 0 }, "退出两天未虚算提醒轮次")
    let caughtUp = catchUp.map { ReminderSchedule.afterDispatch($0, at: reopened) }
    try check(caughtUp.allSatisfy { $0.notificationsSent == 1 && $0.nextReminder == reopened.addingTimeInterval(1800) } &&
              ReminderSchedule.due(caughtUp, at: reopened).isEmpty, "重开只合并当前到期项一次，不补历史轮次")
    var six: [ReminderItem] = []
    for index in 1...6 {
        var entry = ReminderItem(text: "原话 \(index)", now: now)
        try entry.apply(.init(title: "事项\(index)", reminder: dueAt, deadline: nil, suggestedCompletion: nil), now: now)
        six.append(entry)
    }
    let mixed = [firstSent, other] + six
    let mixedDue = ReminderSchedule.due(mixed, at: firstSent.nextReminder!)
    try check(mixedDue.count == 8 && Set(mixedDue.map(\.id)).count == 8 &&
              mixedDue.contains(where: { $0.notificationsSent == 1 }) && mixedDue.contains(where: { $0.notificationsSent == 0 }),
              "首次与重试同轮合并，保留全部关联标识")
    try check(ReminderSchedule.summary(six) == "事项1 · 事项2 · 事项3 · 另有 3 件" && six.count == 6,
              "通知正文短标题溢出，完整事项集合另行关联")
}

do {
    try await run()
    print("全部核心检查通过")
} catch {
    fputs("核心检查失败：\(error)\n", stderr)
    exit(1)
}

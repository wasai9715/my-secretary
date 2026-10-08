import Foundation
import SecretaryCore

func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    guard condition() else { throw RecognitionError.invalid(label) }
    print("✓ \(label)")
}
func payload(kind: String = "update", reminder: Any = NSNull(), cutoff: Any = NSNull(),
             day: Any = NSNull(), precision: String = "none", unsupported: Bool = false,
             reason: Any = NSNull(), evidence: [String]) throws -> String {
    let fields: [String: Any] = ["kind": kind, "reminderAt": reminder, "deadlineKind": precision,
                                 "deadlineAt": cutoff, "deadlineDay": day,
                                 "unsupportedContent": unsupported, "reason": reason, "evidence": evidence]
    return String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}
func rejects(_ json: String, instruction: String, now: Date, _ label: String) throws {
    do {
        _ = try TimeEditDecoder.decode(json, instruction: instruction, now: now)
        throw RecognitionError.connection("错误接受：\(label)")
    } catch RecognitionError.invalid { print("✓ \(label)") }
}
do {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reminder = now.addingTimeInterval(86_400)
    let cutoff = now.addingTimeInterval(3 * 86_400)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let bothInput = "明天九点提醒我，截止改为明天下午六点"
    let bothJSON = try payload(reminder: formatter.string(from: reminder), cutoff: formatter.string(from: cutoff),
                               precision: "instant", evidence: ["明天九点提醒我", "截止改为明天下午六点"])
    guard case .update(let edit) = try TimeEditDecoder.decode(bothJSON, instruction: bothInput, now: now),
          edit.reminder == reminder, edit.deadline == .instant(cutoff) else {
        throw RecognitionError.invalid("两个时间没有分别识别")
    }
    var item = ReminderItem(text: "查订单", now: now)
    try item.apply(.init(title: "查订单", reminder: now.addingTimeInterval(3600),
                         deadline: now.addingTimeInterval(7200), suggestedCompletion: nil), now: now)
    let original = item
    let changed = try edit.proposedChange(to: item, now: now)
    try check(changed.nextReminder == reminder && changed.deadline == cutoff &&
              changed.originalText == original.originalText && changed.text == original.text && item == original,
              "提醒与截止原子提交，模型不能修改内容")
    guard case .update(let onlyReminder) = try TimeEditDecoder.decode(
        payload(reminder: formatter.string(from: reminder), evidence: ["明天九点提醒我"]),
        instruction: "明天九点提醒我", now: now), onlyReminder.deadline == nil else {
        throw RecognitionError.invalid("只说提醒误修改截止")
    }
    print("✓ 只说提醒不修改截止")
    guard case .update(let onlyDeadline) = try TimeEditDecoder.decode(
        payload(cutoff: formatter.string(from: cutoff), precision: "instant", evidence: ["截止改为明天下午六点"]),
        instruction: "截止改为明天下午六点", now: now), onlyDeadline.reminder == nil else {
        throw RecognitionError.invalid("只说截止误修改提醒")
    }
    print("✓ 只说截止不修改提醒")
    guard case .update(let dayEdit) = try TimeEditDecoder.decode(
        payload(day: "2030-01-02", precision: "day", evidence: ["截止改到2号"]),
        instruction: "截止改到2号", now: now), dayEdit.deadline == .day("2030-01-02") else {
        throw RecognitionError.invalid("仅日期截止被错误转换")
    }
    print("✓ 仅日期截止不伪造时分")
    let mixed = "今天下午五点再提醒我，案例批次号为 ABC123"
    do {
        _ = try TimeEditDecoder.decode(try payload(reminder: formatter.string(from: reminder), unsupported: true,
            evidence: ["今天下午五点再提醒我", "案例批次号为 ABC123"]), instruction: mixed, now: now)
        throw RecognitionError.connection("混合内容被错误接受")
    } catch RecognitionError.invalid(let message) {
        try check(message.contains("内容框"), "夹带批次号拒绝部分改时并引导内容框手动编辑")
    }
    try rejects(try payload(reminder: formatter.string(from: reminder), evidence: ["今天下午五点再提醒我"]),
                instruction: mixed, now: now, "模型遗漏内容片段时拒绝部分提交")
    try rejects(try payload(reminder: formatter.string(from: reminder), cutoff: "2030-02-30T18:00:00+08:00",
                precision: "instant", evidence: ["明天九点提醒我", "截止改为明天下午六点"]),
                instruction: bothInput, now: now, "截止非法日期时两种时间都不提交")
    let vague = try TimeEditDecoder.decode(try payload(kind: "choose_preset", evidence: ["晚点再提醒"]),
                                           instruction: "晚点再提醒", now: now)
    try check(vague == .choosePreset, "晚点不静默猜时间")
    actor Replies {
        var values: [String]
        var calls = 0
        init(_ values: [String]) { self.values = values }
        func next() -> String { calls += 1; return values.removeFirst() }
    }
    let replies = Replies(["not JSON", bothJSON])
    let client = DeepSeekClient(configuration: .init()) { _, _ in await replies.next() }
    guard case .update(let corrected) = try await client.interpretTimeEdit(bothInput, item: item, now: now),
          corrected == edit else { throw RecognitionError.invalid("一次纠错未完整恢复两种时间") }
    let count = await replies.calls
    try check(count == 2, "无效模型结构最多自动纠错一次")
    print("全部时间指令检查通过")
} catch {
    fputs("时间指令检查失败：\(error)\n", stderr)
    exit(1)
}

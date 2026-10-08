import Foundation
import SecretaryCore

func verify(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    guard condition() else { throw RecognitionError.invalid(label) }
    print("✓ \(label)")
}

do {
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 15, minute: 31))!
    let duration = ReminderPreset(minutes: 15)
    let firstDuration = try duration.resolve(at: now, calendar: calendar)
    try verify(firstDuration == now.addingTimeInterval(900), "相对时长从点击时计算")
    let nextDay = ReminderPreset(dayOffset: 1, hour: 9, minute: 0)
    let tomorrow = try nextDay.resolve(at: now, calendar: calendar)
    try verify(calendar.component(.day, from: tomorrow) == 2 && calendar.component(.hour, from: tomorrow) == 9,
               "明天九点规则在点击时计算")
    let later = calendar.date(byAdding: .day, value: 5, to: now)!
    let nextWeek = try nextDay.resolve(at: later, calendar: calendar)
    try verify(calendar.component(.day, from: nextWeek) == 7,
               "重复使用不保存过期绝对日期")
    var settings = ReminderSettings()
    let oldSchedule = try duration.resolve(at: now, calendar: calendar)
    settings.presetRules = [nextDay]
    try verify(settings.resolvedPresets == [nextDay] && oldSchedule == now.addingTimeInterval(900),
               "修改预设不改变既有安排")
    let legacy = try JSONEncoder().encode(ReminderSettings())
    let legacySettings = try JSONDecoder().decode(ReminderSettings.self, from: legacy)
    try verify(legacySettings.resolvedPresets.count == 3,
               "旧设置沿用默认三项预设")
    do {
        _ = try ReminderPreset(dayOffset: 1, hour: 25, minute: 0).resolve(at: now, calendar: calendar)
        throw RecognitionError.invalid("非法时刻意外接受")
    } catch RecognitionError.invalid { print("✓ 无效本地时刻被拒绝") }
    var readyDue = ReminderItem(text: "现在处理", now: now)
    try readyDue.apply(.init(title: "现在", reminder: now.addingTimeInterval(120), deadline: nil,
                             suggestedCompletion: nil), now: now)
    var readyLater = readyDue
    readyLater.id = UUID()
    readyLater.nextReminder = now.addingTimeInterval(3600)
    var pending = ReminderItem(text: "识别失败", now: now)
    pending.fail("超时", now: now)
    var history = readyDue
    history.id = UUID()
    history.status = .completed
    let groups = ItemBuckets([readyDue, readyLater, pending, history], now: now.addingTimeInterval(300))
    try verify(groups.current.map(\.id) == [readyDue.id] && groups.later.map(\.id) == [readyLater.id]
               && groups.needsRecognition.map(\.id) == [pending.id] && groups.history.map(\.id) == [history.id],
               "当前、稍后、待识别和历史互不混淆")
    print("全部预设与列表分组检查通过")
} catch {
    fputs("预设检查失败：\(error)\n", stderr)
    exit(1)
}

import Foundation

public enum DeadlineEdit: Sendable, Equatable {
    case instant(Date)
    case day(String)
}

public struct TimeEdit: Sendable, Equatable {
    public let reminder: Date?
    public let deadline: DeadlineEdit?

    public init(reminder: Date? = nil, deadline: DeadlineEdit? = nil) {
        self.reminder = reminder
        self.deadline = deadline
    }

    /// Validate both fields before touching persisted state. Caller saves this copy once.
    public func proposedChange(to item: ReminderItem, now: Date = .now,
                               overrideDeadline: Bool = false) throws -> ReminderItem {
        guard item.status == .open, item.needsSeparateEntries != true,
              reminder != nil || deadline != nil else {
            throw RecognitionError.invalid("当前事项没有可提交的时间修改")
        }
        var changed = item
        if let deadline {
            switch deadline {
            case .instant(let at):
                guard at > now else { throw RecognitionError.invalid("明确截止时间必须在将来") }
                changed.deadline = at
                changed.deadlineDay = nil
            case .day(let day):
                guard let end = ReminderItem.endOfLocalDay(day), end > now else {
                    throw RecognitionError.invalid("明确截止日期无效或已经过去")
                }
                changed.deadline = nil
                changed.deadlineDay = day
            }
            changed.deadlinePeriod = nil
            changed.deadlinePeriodDay = nil
        }
        if let reminder {
            try changed.snooze(until: reminder, now: now, overrideDeadline: overrideDeadline)
            changed.reminderSource = "manual"
        } else {
            changed.manualVersion += 1
        }
        if let next = changed.nextReminder {
            let beyondInstant = changed.deadline.map { next > $0 } == true
            let beyondDay = changed.deadlineDay.flatMap(ReminderItem.endOfLocalDay).map { next >= $0 } == true
            if (beyondInstant || beyondDay) && !overrideDeadline {
                throw RecognitionError.invalid("提醒晚于明确截止，请确认后再保存")
            }
        }
        return changed
    }
}

public enum TimeEditDecision: Sendable, Equatable {
    case update(TimeEdit)
    case choosePreset
    case unclear(String)
}

public enum TimeEditDecoder {
    public static func decode(_ json: String, instruction: String, now: Date = .now) throws -> TimeEditDecision {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = raw["kind"] as? String,
              let deadlineKind = raw["deadlineKind"] as? String,
              let unsupported = raw["unsupportedContent"] as? Bool,
              let evidence = raw["evidence"] as? [String], !evidence.isEmpty,
              ["reminderAt", "deadlineAt", "deadlineDay", "reason"].allSatisfy(raw.keys.contains),
              ["reminderAt", "deadlineAt", "deadlineDay", "reason"].allSatisfy({ raw[$0] is NSNull || raw[$0] is String }) else {
            throw RecognitionError.invalid("时间指令结构不完整")
        }
        guard evidence.allSatisfy({ !$0.isEmpty && instruction.contains($0) }) else {
            throw RecognitionError.invalid("时间操作依据不是输入中的连续片段")
        }
        var uncovered = instruction
        for quote in evidence {
            if let range = uncovered.range(of: quote) { uncovered.removeSubrange(range) }
        }
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        guard uncovered.unicodeScalars.allSatisfy({ ignored.contains($0) }) else {
            throw RecognitionError.invalid("指令有未覆盖部分，不能只执行部分修改")
        }
        guard !unsupported else {
            throw RecognitionError.invalid("这句话还要求修改事项内容；请在上方内容框手动编辑，这里只处理提醒与截止时间")
        }
        let reminderText = raw["reminderAt"] as? String
        let deadlineText = raw["deadlineAt"] as? String
        let deadlineDay = raw["deadlineDay"] as? String
        let reason = raw["reason"] as? String
        switch kind {
        case "choose_preset":
            guard reminderText == nil, deadlineText == nil, deadlineDay == nil,
                  deadlineKind == "none" else { throw RecognitionError.invalid("含糊时间不可自动安排") }
            return .choosePreset
        case "unclear":
            guard reminderText == nil, deadlineText == nil, deadlineDay == nil,
                  deadlineKind == "none", let reason, !reason.isEmpty else {
                throw RecognitionError.invalid("未明确的时间不得部分执行")
            }
            return .unclear(reason)
        case "update":
            guard reason == nil else { throw RecognitionError.invalid("有歧义时不能安排时间") }
            let reminder = try reminderText.map(parseInstant)
            let deadline: DeadlineEdit?
            switch deadlineKind {
            case "none":
                guard deadlineText == nil, deadlineDay == nil else { throw RecognitionError.invalid("截止结构冲突") }
                deadline = nil
            case "instant":
                guard let deadlineText, deadlineDay == nil else { throw RecognitionError.invalid("明确截止时刻不完整") }
                deadline = .instant(try parseInstant(deadlineText))
            case "day":
                guard let deadlineDay, deadlineText == nil,
                      ReminderItem.endOfLocalDay(deadlineDay) != nil else {
                    throw RecognitionError.invalid("明确截止日期无效")
                }
                deadline = .day(deadlineDay)
            default: throw RecognitionError.invalid("截止精度无效")
            }
            guard reminder != nil || deadline != nil else { throw RecognitionError.invalid("没有要修改的时间") }
            if let reminder, reminder <= now { throw RecognitionError.invalid("提醒时间必须在将来") }
            if case .instant(let at) = deadline, at <= now { throw RecognitionError.invalid("明确截止时刻已经过去") }
            if case .day(let day) = deadline,
               let end = ReminderItem.endOfLocalDay(day), end <= now {
                throw RecognitionError.invalid("明确截止日期已经过去")
            }
            return .update(TimeEdit(reminder: reminder, deadline: deadline))
        default: throw RecognitionError.invalid("未知时间操作类型")
        }
    }

    private static func parseInstant(_ value: String) throws -> Date {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw RecognitionError.invalid("时间须为带时区的合法日期时间")
        }
        let zone: TimeZone
        if value.hasSuffix("Z") { zone = TimeZone(secondsFromGMT: 0)! }
        else {
            let suffix = String(value.suffix(6))
            let components = suffix.dropFirst().split(separator: ":")
            guard components.count == 2, let hour = Int(components[0]), let minute = Int(components[1]),
                  hour <= 23, minute <= 59,
                  let parsed = TimeZone(secondsFromGMT: (hour * 60 + minute) * 60 * (suffix.first == "-" ? -1 : 1)) else {
                throw RecognitionError.invalid("时区偏移无效")
            }
            zone = parsed
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = zone
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw RecognitionError.invalid("日历日期或时间无效")
        }
        return date
    }
}

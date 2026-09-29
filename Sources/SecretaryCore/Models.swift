import Foundation

public enum ItemStatus: String, Codable, Sendable { case open, completed, cancelled }
public enum RecognitionStatus: String, Codable, Sendable { case interpreting, ready, needsAttention }

public struct ReminderItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var originalText: String
    public var text: String
    public var title: String
    public var createdAt: Date
    public var status: ItemStatus
    public var recognition: RecognitionStatus
    public var firstReminder: Date?
    public var nextReminder: Date?
    public var deadline: Date?
    public var deadlineDay: String?
    public var deadlinePeriod: String?
    public var deadlinePeriodDay: String?
    public var scheduledDay: String?
    public var reminderSource: String?
    public var timeEvidence: [String]?
    public var needsSeparateEntries: Bool?
    public var suggestedCompletion: Date?
    public var failure: String?
    public var notificationsSent: Int
    public var lastUserSnooze: Date?
    public var manualVersion: Int

    public init(text: String, now: Date = .now) {
        id = UUID()
        originalText = text
        self.text = text
        title = text
        createdAt = now
        status = .open
        recognition = .interpreting
        firstReminder = nil
        nextReminder = nil
        deadline = nil
        deadlineDay = nil
        deadlinePeriod = nil
        deadlinePeriodDay = nil
        scheduledDay = nil
        reminderSource = nil
        timeEvidence = nil
        needsSeparateEntries = nil
        suggestedCompletion = nil
        failure = nil
        notificationsSent = 0
        lastUserSnooze = nil
        manualVersion = 0
    }

    public mutating func apply(_ result: Interpretation, now: Date = .now) throws {
        guard status == .open else { return }
        guard result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw RecognitionError.invalid("短标题为空")
        }
        if [result.deadline != nil, result.deadlineDay != nil, result.deadlinePeriod != nil].filter({ $0 }).count > 1 {
            throw RecognitionError.invalid("不能同时设置多种截止精度")
        }
        if result.reminder == nil && result.reminderSource != nil && result.reminderSource != "default_15min" {
            throw RecognitionError.invalid("有时间线索却未给出可用提醒")
        }
        if result.reminder == nil && (result.scheduledDay != nil || result.deadline != nil || result.deadlineDay != nil || result.deadlinePeriod != nil) {
            throw RecognitionError.invalid("计划或截止不能退回无时间默认15分钟")
        }
        if let deadline = result.deadline {
            guard let reminder = result.reminder, reminder < deadline else {
                throw RecognitionError.invalid("明确截止事项必须有早于截止的首次提醒")
            }
        }
        if let date = result.reminder, date.timeIntervalSince(now) < -60 {
            throw RecognitionError.invalid("建议提醒时间已过")
        }
        var first = max(result.reminder ?? createdAt.addingTimeInterval(15 * 60), now)
        if let day = result.deadlineDay {
            guard let end = Self.endOfLocalDay(day), now < end else {
                throw RecognitionError.invalid("仅日期截止无效或已经过期")
            }
            if first >= end {
                guard result.reminder == nil else { throw RecognitionError.invalid("提醒晚于明确截止日期") }
                first = now
            }
        }
        title = result.title
        firstReminder = first
        nextReminder = first
        deadline = result.deadline
        deadlineDay = result.deadlineDay
        deadlinePeriod = result.deadlinePeriod
        deadlinePeriodDay = result.deadlinePeriodDay
        scheduledDay = result.scheduledDay
        reminderSource = result.reminderSource
        timeEvidence = result.timeEvidence
        needsSeparateEntries = false
        suggestedCompletion = result.suggestedCompletion
        recognition = .ready
        failure = nil
        notificationsSent = 0
    }

    public static func endOfLocalDay(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let start = formatter.date(from: day), formatter.string(from: start) == day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(byAdding: .day, value: 1, to: start)
    }

    public mutating func fail(_ message: String, now: Date = .now, needsSeparateEntries: Bool = false) {
        guard status == .open else { return }
        recognition = .needsAttention
        self.needsSeparateEntries = needsSeparateEntries
        failure = message
        nextReminder = now.addingTimeInterval(15 * 60)
        notificationsSent = 0
    }

    public mutating func snooze(until date: Date, now: Date = .now, overrideDeadline: Bool = false) throws {
        guard needsSeparateEntries != true else {
            throw RecognitionError.invalid("此原话包含多个需分别提醒的行动，请分两次录入")
        }
        guard date > now else { throw RecognitionError.invalid("提醒时间须在将来") }
        if let deadline, date > deadline && !overrideDeadline {
            throw RecognitionError.deadlineConflict(deadline)
        }
        if let deadlineDay, let end = Self.endOfLocalDay(deadlineDay), date >= end && !overrideDeadline {
            throw RecognitionError.invalid("所选提醒晚于明确截止日期：\(deadlineDay)")
        }
        nextReminder = date
        notificationsSent = 0
        lastUserSnooze = date
        manualVersion += 1
        // A manually set time resolves the need for automatic interpretation.
        recognition = .ready
        needsSeparateEntries = false
        failure = nil
    }
}

public struct Interpretation: Sendable, Equatable {
    public var title: String
    public var reminder: Date?
    public var deadline: Date?
    public var deadlineDay: String?
    public var deadlinePeriod: String?
    public var deadlinePeriodDay: String?
    public var scheduledDay: String?
    public var reminderSource: String?
    public var timeEvidence: [String]?
    public var suggestedCompletion: Date?

    public init(title: String, reminder: Date?, deadline: Date?, deadlineDay: String? = nil,
                deadlinePeriod: String? = nil, deadlinePeriodDay: String? = nil, scheduledDay: String? = nil,
                reminderSource: String? = nil, timeEvidence: [String]? = nil, suggestedCompletion: Date?) {
        self.title = title
        self.reminder = reminder
        self.deadline = deadline
        self.deadlineDay = deadlineDay
        self.deadlinePeriod = deadlinePeriod
        self.deadlinePeriodDay = deadlinePeriodDay
        self.scheduledDay = scheduledDay
        self.reminderSource = reminderSource
        self.timeEvidence = timeEvidence
        self.suggestedCompletion = suggestedCompletion
    }
}

public enum RecognitionError: Error, LocalizedError {
    case invalid(String)
    case deadlineConflict(Date)
    case connection(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let value): value
        case .deadlineConflict(let date): "所选时间晚于明确截止时间：\(date.formatted(date: .abbreviated, time: .shortened))"
        case .connection(let value): value
        }
    }
}

public struct AIConfiguration: Codable, Sendable {
    public var endpoint: String
    public var model: String
    public var token: String
    public var verified: Bool

    public init(endpoint: String = "https://api.deepseek.com/chat/completions", model: String = "deepseek-chat", token: String = "", verified: Bool = false) {
        self.endpoint = endpoint
        self.model = model
        self.token = token
        self.verified = verified
    }
}

public struct ReminderSettings: Codable, Sendable {
    public var digestHour: Int = 17
    public var digestMinute: Int = 0
    public var shortcutKey: UInt32 = 25 // 9 on a US physical keyboard
    public var shortcutModifiers: UInt32 = 0x1200 // control + shift (Carbon key modifier flags)
    public var shortcutDisplay: String? = nil
    public var presetsMinutes: [Int] = [15, 30, 60]
    public var lastDigestDay: String = ""
    public init() {}
}

import Foundation

/// A reusable rule is resolved when clicked; it is never an absolute date saved in settings.
public struct ReminderPreset: Codable, Sendable, Equatable {
    public enum Rule: String, Codable, Sendable { case duration, relativeDayTime }
    public var rule: Rule
    public var minutes: Int?
    public var dayOffset: Int?
    public var hour: Int?
    public var minute: Int?

    public init(minutes: Int) {
        rule = .duration
        self.minutes = minutes
        dayOffset = nil
        hour = nil
        minute = nil
    }

    public init(dayOffset: Int, hour: Int, minute: Int) {
        rule = .relativeDayTime
        minutes = nil
        self.dayOffset = dayOffset
        self.hour = hour
        self.minute = minute
    }

    public func resolve(at now: Date = .now, calendar: Calendar = .current) throws -> Date {
        switch rule {
        case .duration:
            guard let minutes, minutes > 0, minutes <= 60 * 24 * 30,
                  dayOffset == nil, hour == nil, minute == nil else {
                throw RecognitionError.invalid("相对时长须介于 1 分钟与 30 天之间")
            }
            return now.addingTimeInterval(TimeInterval(minutes) * 60)
        case .relativeDayTime:
            guard minutes == nil, let dayOffset, (1...30).contains(dayOffset),
                  let hour, (0...23).contains(hour), let minute, (0...59).contains(minute),
                  let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)),
                  let resolved = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                               matchingPolicy: .strict),
                  calendar.isDate(resolved, inSameDayAs: day) else {
                throw RecognitionError.invalid("预设日期或时分无效，请选择有效的本地时间")
            }
            return resolved
        }
    }

    public var label: String {
        switch rule {
        case .duration:
            guard let minutes else { return "无效时长" }
            return minutes % 60 == 0 ? "\(minutes / 60) 小时后" : "\(minutes) 分钟后"
        case .relativeDayTime:
            guard let dayOffset, let hour, let minute else { return "无效日期规则" }
            return "\(dayOffset == 1 ? "明天" : "\(dayOffset) 天后") \(String(format: "%02d:%02d", hour, minute))"
        }
    }
}

public extension ReminderSettings {
    /// Older settings files omit this key; nil means the original default duration rules.
    var resolvedPresets: [ReminderPreset] {
        presetRules ?? presetsMinutes.map { ReminderPreset(minutes: $0) }
    }
}

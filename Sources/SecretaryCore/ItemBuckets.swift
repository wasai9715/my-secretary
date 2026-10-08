import Foundation

public struct ItemBuckets: Sendable {
    public let current: [ReminderItem]
    public let later: [ReminderItem]
    public let needsRecognition: [ReminderItem]
    public let history: [ReminderItem]

    public init(_ items: [ReminderItem], now: Date = .now) {
        current = items.filter { $0.status == .open && $0.recognition == .ready &&
            ($0.nextReminder ?? $0.firstReminder).map { $0 <= now } == true }
        later = items.filter { $0.status == .open && $0.recognition == .ready &&
            ($0.nextReminder ?? $0.firstReminder).map { $0 > now } == true }
        needsRecognition = items.filter { $0.status == .open && $0.recognition != .ready }
        history = items.filter { $0.status != .open }
    }
}

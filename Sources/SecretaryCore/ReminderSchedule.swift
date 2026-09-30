import Foundation

/// A single dispatch pass sends one notification for all items currently due.
/// Only successful dispatch advances the retry cycle; elapsed time while the app
/// was unavailable never counts as a sent reminder.
public enum ReminderSchedule {
    public static func due(_ items: [ReminderItem], at now: Date) -> [ReminderItem] {
        items.filter {
            $0.status == .open &&
            $0.nextReminder.map { $0 <= now } == true &&
            $0.notificationsSent < ($0.recognition == .needsAttention ? 1 : 3)
        }
    }

    public static func digestPending(_ items: [ReminderItem], at now: Date) -> [ReminderItem] {
        items.filter { item in
            guard item.status == .open else { return false }
            if item.recognition == .needsAttention { return true }
            guard item.firstReminder.map({ $0 <= now }) == true || item.nextReminder.map({ $0 <= now }) == true else { return false }
            return item.lastUserSnooze.map { $0 <= now } ?? true
        }
    }

    /// Bounded preview; the notification's itemIDs always carries the entire set.
    public static func digestDay(at now: Date, calendar: Calendar = .current) -> String {
        calendar.startOfDay(for: now).formatted(.iso8601)
    }

    public static func shouldSendDigest(at now: Date, settings: ReminderSettings, calendar: Calendar = .current) -> Bool {
        let time = (calendar.component(.hour, from: now), calendar.component(.minute, from: now))
        return time >= (settings.digestHour, settings.digestMinute) && digestDay(at: now, calendar: calendar) != settings.lastDigestDay
    }

    public static func summary(_ items: [ReminderItem], maxTitles: Int = 3) -> String {
        let shown = items.prefix(max(1, maxTitles)).map(\.title).joined(separator: " · ")
        let remaining = items.count - min(items.count, max(1, maxTitles))
        return shown + (remaining > 0 ? " · 另有 \(remaining) 件" : "")
    }

    public static func afterDispatch(_ item: ReminderItem, at now: Date) -> ReminderItem {
        var updated = item
        updated.notificationsSent += 1
        if updated.recognition == .needsAttention || updated.notificationsSent >= 3 {
            updated.nextReminder = nil
        } else {
            updated.nextReminder = now.addingTimeInterval(updated.notificationsSent == 1 ? 30 * 60 : 2 * 60 * 60)
        }
        return updated
    }
}

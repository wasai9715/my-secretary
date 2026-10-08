import AppKit
import SwiftUI
import Carbon
import UserNotifications
import ServiceManagement
import SecretaryCore

struct CaptureFeedback {
    let id = UUID()
    let itemID: UUID
    let title: String
    let reminder: Date?
    let deadline: Date?
    let deadlineDay: String?
    let suggestedCompletion: Date?

    init(item: ReminderItem) {
        itemID = item.id
        title = item.title
        reminder = item.nextReminder
        deadline = item.deadline
        deadlineDay = item.deadlineDay
        suggestedCompletion = item.suggestedCompletion
    }
}

@MainActor
final class SecretaryModel: ObservableObject {
    @Published var items: [ReminderItem] = []
    @Published var configuration = AIConfiguration()
    @Published var settings = ReminderSettings()
    @Published var message = ""
    @Published var notificationGranted = false
    @Published var focusedNotificationIDs: Set<UUID>?
    private(set) var lastCapturedID: UUID?
    var onCaptureFeedback: (@MainActor (CaptureFeedback) -> Void)?
    var onItemsChanged: (@MainActor () -> Void)?
    var onPermissionRestored: (@MainActor () -> Void)?
    private var dispatchingIDs: Set<UUID> = []
    private var digestInFlight = false
    private var recognitionAttempts: [UUID: UUID] = [:]
    private var commandAttempts: [UUID: UUID] = [:]
    private var pendingReminderPreview: [UUID: (version: Int, reminder: Date)] = [:]
    private var pendingEditPreview: [UUID: (version: Int, edit: TimeEdit)] = [:]
    private var pendingTimeDeadline: [UUID: (version: Int, edit: TimeEdit)] = [:]
    // Diagnostics replace the transport, not the scheduling/commit path.
    var notificationOverride: ((String, String, [UUID], @escaping @MainActor (Bool) -> Void) -> Void)?
    var interpretationOverride: ((String, Date) async throws -> InterpretationDecision)?
    var timeEditOverride: ((String, ReminderItem) async throws -> TimeEditDecision)?
    let files: LocalFiles
    let store: ItemStore

    init(files: LocalFiles? = nil) throws {
        self.files = try files ?? LocalFiles()
        store = try ItemStore(path: self.files.databasePath)
        items = try store.all()
        configuration = try self.files.loadConfiguration()
        settings = try self.files.loadSettings()
    }

    @discardableResult
    func update(_ item: ReminderItem) -> Bool {
        do {
            try store.upsert(item)
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
            else { items.insert(item, at: 0) }
            onItemsChanged?()
            return true
        } catch {
            message = "本机保存失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func add(_ input: String) -> Bool {
        guard configuration.verified else { message = "请先测试 DeepSeek 连接"; return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let item = ReminderItem(text: text)
        do { try store.upsert(item); items.insert(item, at: 0); lastCapturedID = item.id; onItemsChanged?() }
        catch { message = "本机保存失败：\(error.localizedDescription)"; return false }
        message = "已记下，正在安排提醒"
        startRecognition(for: item)
        return true
    }

    // Reuse the capture path for explicit retries; only the captured attempt may commit.
    private func startRecognition(for item: ReminderItem) {
        let version = item.manualVersion
        let attempt = UUID()
        recognitionAttempts[item.id] = attempt
        let transport = interpretationOverride
        let client = DeepSeekClient(configuration: configuration)
        Task {
            do {
                let result: InterpretationDecision
                if let transport {
                    result = try await transport(item.originalText, item.createdAt)
                } else {
                    result = try await client.interpret(item.originalText, now: item.createdAt)
                }
                guard var current = items.first(where: { $0.id == item.id }),
                      current.manualVersion == version, current.status == .open,
                      current.recognition == .interpreting,
                      recognitionAttempts[item.id] == attempt else { return }
                switch result {
                case .schedule(let interpretation):
                    try current.apply(interpretation)
                    guard update(current) else { return }
                    // Success is shown once in the short feedback card; do not
                    // leave a permanent banner in the shared management message.
                    message = ""
                    onCaptureFeedback?(CaptureFeedback(item: current))
                case .separateEntries(let reason):
                    current.fail(reason, needsSeparateEntries: true)
                    guard update(current) else { return }
                    message = reason
                    sendNotification(title: "请分两次录入", body: "原话已保存，包含多个分别需要提醒的行动。点击查看。", ids: [current.id])
                case .needsConfirmation(let reason):
                    current.fail(reason)
                    guard update(current) else { return }
                    message = reason
                    sendNotification(title: "时间待确认", body: "\(current.title) — 点击查看或设置时间", ids: [current.id])
                }
            } catch {
                guard var current = items.first(where: { $0.id == item.id }),
                      current.manualVersion == version, current.status == .open,
                      current.recognition == .interpreting,
                      recognitionAttempts[item.id] == attempt else { return }
                current.fail(error.localizedDescription)
                guard update(current) else { return }
                message = "识别失败：\(current.title)"
                sendNotification(title: "提醒尚未安排", body: "\(current.title) — 点击设置时间或重试", ids: [current.id])
            }
        }
    }

    @discardableResult
    func retryRecognition(_ id: UUID) -> Bool {
        guard configuration.verified else { message = "请先测试 DeepSeek 连接"; return false }
        guard var item = items.first(where: { $0.id == id }), item.status == .open,
              item.recognition == .needsAttention, item.needsSeparateEntries != true else {
            message = "只有识别失败的待处理事项可以重试；多行动请分别录入"
            return false
        }
        // A manual edit, including one without a reminder, must never be undone by AI.
        guard item.manualVersion == 0, item.text == item.originalText else {
            message = "事项已手动修改，请手动设置提醒时间"
            return false
        }
        item.recognition = .interpreting
        item.failure = nil
        item.nextReminder = nil
        guard update(item) else { return false }
        message = "正在重新识别"
        startRecognition(for: item)
        return true
    }

    @discardableResult
    func undoCapture(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }),
              item.status == .open, Date().timeIntervalSince(item.createdAt) < 120 else {
            message = "撤销时间已结束"
            return false
        }
        do {
            try store.delete(id)
            items.removeAll { $0.id == id }
            if lastCapturedID == id { lastCapturedID = nil }
            onItemsChanged?()
            message = "已撤销录入"
            return true
        } catch { message = "撤销失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult
    func clearHistory() -> Bool {
        let history = items.filter { $0.status != .open }
        do {
            for entry in history { try store.delete(entry.id) }
            items.removeAll { $0.status != .open }
            onItemsChanged?()
            message = "已清空历史事项"
            return true
        } catch {
            items = (try? store.all()) ?? items
            message = "清空历史未完成：\(error.localizedDescription)"
            onItemsChanged?()
            return false
        }
    }

    enum CommandOutcome {
        case applied
        case preview(Date)
        case previewEdit(TimeEdit)
        case choosePreset
        case needsDeadlineConfirmation
        case rejected(String)
    }

    func previewReminderCommand(_ id: UUID, instruction: String) async -> CommandOutcome {
        guard configuration.verified, let item = items.first(where: { $0.id == id }), item.status == .open else {
            return .rejected("模型未连接或事项不再待处理")
        }
        let attempt = UUID()
        commandAttempts[id] = attempt
        pendingReminderPreview[id] = nil
        do {
            let decision: TimeEditDecision
            if let timeEditOverride { decision = try await timeEditOverride(instruction, item) }
            else { decision = try await DeepSeekClient(configuration: configuration).interpretTimeEdit(instruction, item: item) }
            guard commandAttempts[id] == attempt,
                  let current = items.first(where: { $0.id == id }),
                  current.status == .open, current.manualVersion == item.manualVersion else {
                return .rejected("事项已变化，请重新解析时间")
            }
            switch decision {
            case .update(let edit) where edit.reminder != nil && edit.deadline == nil:
                let date = edit.reminder!
                guard date > .now else { return .rejected("请选择将来的提醒时间") }
                pendingReminderPreview[id] = (current.manualVersion, date)
                return .preview(date)
            case .update: return .rejected("这里仅调整下次提醒；截止时间请在编辑窗口中修改")
            case .choosePreset: return .choosePreset
            case .unclear(let reason): return .rejected(reason)
            }
        } catch { return .rejected("时间理解失败：\(error.localizedDescription)") }
    }

    func previewEditCommand(_ id: UUID, instruction: String) async -> CommandOutcome {
        guard configuration.verified, let item = items.first(where: { $0.id == id }), item.status == .open else {
            return .rejected("模型未连接或事项不再待处理")
        }
        let attempt = UUID()
        commandAttempts[id] = attempt
        pendingEditPreview[id] = nil
        do {
            let decision: TimeEditDecision
            if let timeEditOverride { decision = try await timeEditOverride(instruction, item) }
            else { decision = try await DeepSeekClient(configuration: configuration).interpretTimeEdit(instruction, item: item) }
            guard commandAttempts[id] == attempt,
                  let current = items.first(where: { $0.id == id }), current.status == .open,
                  current.manualVersion == item.manualVersion else {
                return .rejected("事项已变化，请重新解析")
            }
            switch decision {
            case .update(let edit):
                guard edit.reminder == nil || edit.reminder! > .now else { return .rejected("请选择将来的提醒时间") }
                pendingEditPreview[id] = (current.manualVersion, edit)
                return .previewEdit(edit)
            case .unclear(let reason): return .rejected(reason)
            case .choosePreset: return .choosePreset
            }
        } catch { return .rejected("操作理解失败：\(error.localizedDescription)") }
    }

    func confirmEditPreview(_ id: UUID) -> CommandOutcome {
        guard let pending = pendingEditPreview.removeValue(forKey: id),
              let current = items.first(where: { $0.id == id }), current.status == .open,
              current.manualVersion == pending.version else {
            return .rejected("事项已变化，请重新解析")
        }
        do {
            let proposed = try pending.edit.proposedChange(to: current)
            return update(proposed) ? .applied : .rejected(message)
        } catch {
            let reason = error.localizedDescription
            if reason.contains("提醒晚于明确截止") || { if case RecognitionError.deadlineConflict = error { return true }; return false }() {
                pendingTimeDeadline[id] = pending
                return .needsDeadlineConfirmation
            }
            return .rejected(reason)
        }
    }

    func confirmReminderPreview(_ id: UUID) -> CommandOutcome {
        guard let pending = pendingReminderPreview.removeValue(forKey: id),
              let current = items.first(where: { $0.id == id }), current.status == .open,
              current.manualVersion == pending.version else {
            return .rejected("事项已变化，请重新解析时间")
        }
        let beyondInstant = current.deadline.map { pending.reminder > $0 } == true
        let beyondDay = current.deadlineDay.flatMap(ReminderItem.endOfLocalDay)
            .map { pending.reminder >= $0 } == true
        if beyondInstant || beyondDay {
            pendingTimeDeadline[id] = (current.manualVersion, TimeEdit(reminder: pending.reminder))
            return .needsDeadlineConfirmation
        }
        return snooze(current, until: pending.reminder) ? .applied : .rejected(message)
    }

    func confirmDeadlineCommand(_ id: UUID) -> CommandOutcome {
        if let pendingTime = pendingTimeDeadline.removeValue(forKey: id),
           let current = items.first(where: { $0.id == id }), current.status == .open,
           current.manualVersion == pendingTime.version {
            do {
                let proposed = try pendingTime.edit.proposedChange(to: current, overrideDeadline: true)
                return update(proposed) ? .applied : .rejected(message)
            } catch { return .rejected(error.localizedDescription) }
        }
        return .rejected("事项已发生变化，请重新解析时间")
    }

    func testAndSave(endpoint: String, model: String, token: String) async {
        var candidate = AIConfiguration(endpoint: endpoint, model: model, token: token)
        do {
            try await DeepSeekClient(configuration: candidate).testConnection()
            candidate.verified = true
            try files.saveConfiguration(candidate)
            configuration = candidate
            message = "连接成功，可以开始记录"
        } catch { message = "连接失败：\(error.localizedDescription)" }
    }

    func saveSettings() {
        do { try files.saveSettings(settings) }
        catch { message = "设置保存失败：\(error.localizedDescription)" }
    }

    // Validate the whole form before a single persisted update. The original capture is
    // immutable; editing never starts another AI interpretation.
    func editDetails(_ item: ReminderItem, title: String, text: String, reminder: Date?,
                     deadline: Date?, deadlineDay: String?, clearPeriod: Bool,
                     resolvesSingleAction: Bool, restoreSplit: Bool = false,
                     overrideDeadline: Bool = false) -> Bool {
        guard let current = items.first(where: { $0.id == item.id }) else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !text.isEmpty else { message = "标题和内容不能为空"; return false }
        if current.needsSeparateEntries == true {
            guard resolvesSingleAction, text != current.text, let reminder else {
                message = "请先将内容核对为一件事、确认单项行动并设置新的提醒；或分开录入后取消原记录"
                return false
            }
            guard reminder > .now else { message = "请选择将来的提醒时间"; return false }
        }
        var updated = current
        updated.title = title
        if text != current.text {
            if updated.initialCaptureText == nil { updated.initialCaptureText = current.originalText }
            updated.originalText = text
        }
        updated.text = text
        if text != current.text && reminder == current.nextReminder {
            updated.timeUnchangedAfterContentEdit = true
        }
        if restoreSplit && current.needsSeparateEntries == true { updated.status = .open }
        updated.deadline = deadline
        updated.deadlineDay = deadlineDay
        if clearPeriod { updated.deadlinePeriod = nil; updated.deadlinePeriodDay = nil }
        if let reminder, reminder != current.nextReminder || current.needsSeparateEntries == true {
            if current.needsSeparateEntries == true { updated.needsSeparateEntries = false }
            do { try updated.snooze(until: reminder, overrideDeadline: overrideDeadline) }
            catch { message = error.localizedDescription; return false }
        } else {
            updated.nextReminder = reminder
            updated.manualVersion += 1
        }
        guard update(updated) else { return false }
        message = ""
        return true
    }

    @discardableResult
    func changeStatus(_ item: ReminderItem, to status: ItemStatus) -> Bool {
        guard let current = items.first(where: { $0.id == item.id }), current.status == .open else { return false }
        var updated = current
        updated.status = status
        updated.manualVersion += 1
        if status != .open { updated.nextReminder = nil }
        guard update(updated) else { return false }
        message = ""
        return true
    }

    // Immediate undo restores the previous schedule without resurrecting an older AI result.
    func undoStatus(_ previous: ReminderItem) -> Bool {
        guard let current = items.first(where: { $0.id == previous.id }), current.status != .open else { return false }
        var restored = previous
        restored.manualVersion = current.manualVersion + 1
        guard update(restored) else { return false }
        message = ""
        return true
    }

    @discardableResult
    func snooze(_ item: ReminderItem, until date: Date, overrideDeadline: Bool = false) -> Bool {
        guard let current = items.first(where: { $0.id == item.id }), current.status == .open else { return false }
        var updated = current
        do {
            try updated.snooze(until: date, overrideDeadline: overrideDeadline)
            guard update(updated) else { return false }
            message = ""
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func restore(_ item: ReminderItem, until date: Date, overrideDeadline: Bool = false) -> Bool {
        guard let current = items.first(where: { $0.id == item.id }), current.status != .open else { return false }
        var updated = current
        updated.status = .open
        do {
            try updated.snooze(until: date, overrideDeadline: overrideDeadline)
            guard update(updated) else { return false }
            message = ""
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func refreshPermission(requestIfUndetermined: Bool = false) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
            let undetermined = settings.authorizationStatus == .notDetermined
            Task { @MainActor in
                let wasGranted = self.notificationGranted
                self.notificationGranted = granted
                self.onItemsChanged?()
                if granted && !wasGranted { self.onPermissionRestored?() }
                if undetermined && requestIfUndetermined { self.requestPermission() }
            }
        }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .denied:
                Task { @MainActor in
                    self.message = "macOS 已拒绝通知权限；再次请求不会弹窗，请在系统设置 → 通知中为 MySecretary 开启通知。"
                    self.refreshPermission()
                    Self.openSystemNotificationSettings()
                }
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                    Task { @MainActor in self.refreshPermission() }
                }
            default:
                Task { @MainActor in
                    self.message = "当前通知权限已开启；如果没有收到通知，请检查系统勿扰和横幅设置。"
                    self.refreshPermission()
                }
            }
        }
    }

    static func openSystemNotificationSettings() {
        // Open the actual notifications pane; per-app deep links are not stable
        // across macOS versions. The user chooses MySecretary in the app list.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    func sendNotification(title: String, body: String, ids: [UUID], completion: (@MainActor (Bool) -> Void)? = nil) {
        guard notificationGranted else { completion?(false); return }
        if let notificationOverride {
            notificationOverride(title, body, ids, completion ?? { _ in })
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["itemIDs": ids.map(\.uuidString)]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                completion?(true)
            } catch {
                message = "系统通知发送失败，请检查通知权限"
                refreshPermission()
                completion?(false)
            }
        }
    }

    func checkDue(now: Date = .now) {
        let due = ReminderSchedule.due(items, at: now).filter { !dispatchingIDs.contains($0.id) }
        guard !due.isEmpty, notificationGranted else { return }
        let summary = ReminderSchedule.summary(due)
        let ids = due.map(\.id)
        dispatchingIDs.formUnion(ids)
        let needsSplit = due.count == 1 && due[0].needsSeparateEntries == true
        sendNotification(title: needsSplit ? "请分两次录入" : "有 \(due.count) 件事需要处理",
                         body: needsSplit ? "原话仍待处理，尚未安排正常提醒" : summary,
                         ids: ids) { success in
            self.dispatchingIDs.subtract(ids)
            guard success else { return }
            for old in due {
                guard var item = self.items.first(where: { $0.id == old.id }), item.status == .open,
                      item.nextReminder == old.nextReminder, item.notificationsSent == old.notificationsSent else { continue }
                item = ReminderSchedule.afterDispatch(item, at: Date())
                self.update(item)
            }
        }
    }

    /// Returns true when the digest owns this tick, including an in-flight send.
    /// Due reminders included in the digest count as dispatched only on success.
    func sendDigest(now: Date = .now) -> Bool {
        guard notificationGranted else { return false }
        if digestInFlight { return true }
        let pending = ReminderSchedule.digestPending(items, at: now)
        let day = ReminderSchedule.digestDay(at: now)
        guard !pending.isEmpty else {
            settings.lastDigestDay = day
            saveSettings()
            return false
        }
        digestInFlight = true
        let due = ReminderSchedule.due(pending, at: now)
        let ids = pending.map(\.id)
        dispatchingIDs.formUnion(due.map(\.id))
        sendNotification(title: "还有 \(pending.count) 件事未完成", body: ReminderSchedule.summary(pending), ids: ids) { success in
            self.digestInFlight = false
            self.dispatchingIDs.subtract(due.map(\.id))
            guard success else { return }
            self.settings.lastDigestDay = day
            self.saveSettings()
            for old in due {
                guard let current = self.items.first(where: { $0.id == old.id }), current.status == .open,
                      current.nextReminder == old.nextReminder, current.notificationsSent == old.notificationsSent else { continue }
                self.update(ReminderSchedule.afterDispatch(current, at: Date()))
            }
        }
        return true
    }
}

@MainActor
final class CapturePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var model: SecretaryModel!
    private var statusItem: NSStatusItem!
    private var permissionItem: NSMenuItem?
    private var undoCaptureItem: NSMenuItem?
    private var processingItem: NSMenuItem?
    private var feedbackWindow: NSPanel?
    private var feedbackScreen: NSScreen?
    private var feedbackToken: UUID?
    private var panel: CapturePanel?
    private var management: NSWindow?
    private var managementWeb: ManagementWebHost?
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var nextHotKeyID: UInt32 = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDiagnostic = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--check-") }
        if !isDiagnostic, let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        do { model = try SecretaryModel() }
        catch {
            NSAlert(error: error).runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        model.refreshPermission(requestIfUndetermined: !isDiagnostic)
        createStatusMenu()
        model.onCaptureFeedback = { [weak self] feedback in self?.showCaptureFeedback(feedback) }
        model.onItemsChanged = { [weak self] in self?.updateStatusMenu() }
        model.onPermissionRestored = { [weak self] in self?.tick() }
        registerHotKey()
        if !isDiagnostic { tick() }
        // Sleeping, clock corrections, and time-zone changes can invalidate the
        // next scheduled tick; recalculate immediately on each transition.
        for name in [NSWorkspace.didWakeNotification, NSNotification.Name.NSSystemClockDidChange,
                     NSNotification.Name.NSSystemTimeZoneDidChange] {
            let center: NotificationCenter = name == NSWorkspace.didWakeNotification ? NSWorkspace.shared.notificationCenter : .default
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-capture-enter") {
            checkCaptureEnter()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-command-actions") {
            Task {
                do { try await checkCommandActions(); NSApp.terminate(nil) }
                catch { fputs("指令操作检查失败：\(error)\n", stderr); exit(114) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-permission-ui") {
            checkPermissionUI()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-login-launch") {
            checkLoginLaunchStatus()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-real-notification") {
            Task {
                do { try await checkRealNotification(); NSApp.terminate(nil) }
                catch { fputs("真实通知 API 检查失败：\(error)\n", stderr); exit(130) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-notification-route") {
            checkNotificationRoute()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-success-banner") {
            Task {
                do { try await checkSuccessBanner(); NSApp.terminate(nil) }
                catch { fputs("成功提示生命周期检查失败：\(error)\n", stderr); exit(137) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-post-save-route") {
            checkPostSaveRoute()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-management-list") {
            checkManagementList()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-recognition-race") {
            Task {
                do { try await checkRecognitionRace(); NSApp.terminate(nil) }
                catch { fputs("迟到识别检查失败：\(error)\n", stderr); exit(99) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-reminder-dispatch") {
            checkReminderDispatch()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-reminder-recovery") {
            checkReminderRecovery()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-reminder-digest") {
            checkReminderDigest()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-clock-recompute") {
            checkClockRecompute()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-item-lifecycle") {
            checkItemLifecycle()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-shortcut-conflict") {
            // Reserve a candidate with Carbon itself, then make sure the
            // rejected change never reaches the user's saved settings.
            let old = model.settings
            var reservation: EventHotKeyRef?
            let modifier = UInt32(controlKey | optionKey)
            var selected: UInt32?
            for code: UInt32 in [40, 38, 2] { // K, J, D
                let identifier = EventHotKeyID(signature: 0x54455354, id: code)
                if RegisterEventHotKey(code, modifier, identifier, GetApplicationEventTarget(), 0, &reservation) == noErr {
                    selected = code
                    break
                }
            }
            guard let code = selected, let reservation else { exit(59) }
            let succeeded = applyShortcut(RecordedShortcut(keyCode: code, modifiers: modifier, display: "冲突检查"))
            UnregisterEventHotKey(reservation)
            guard !succeeded, model.settings.shortcutKey == old.shortcutKey,
                  model.settings.shortcutModifiers == old.shortcutModifiers,
                  model.settings.shortcutDisplay == old.shortcutDisplay else { exit(60) }
            NSApp.terminate(nil)
        }
        if ProcessInfo.processInfo.arguments.contains("--check-shortcut-recorder") {
            let probe = ShortcutRecorderProbe()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ShortcutRecorderDiagnostic(probe: probe))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard window.firstResponder is ShortcutRecorder.RecorderView else { exit(56) }
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                   modifierFlags: [.command, .shift], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: "a", charactersIgnoringModifiers: "a",
                                                   isARepeat: false, keyCode: 0) else { exit(57) }
                (window.firstResponder as? NSView)?.keyDown(with: event)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard probe.recorded?.keyCode == 0,
                          probe.recorded?.modifiers == UInt32(cmdKey | shiftKey),
                          probe.isRecording == false else { exit(58) }
                    window.orderOut(nil)
                    NSApp.terminate(nil)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-feedback-flow") {
            let previousItems = model.items
            var example = ReminderItem(text: "检查一次性录入反馈")
            model.items = [example]
            model.onItemsChanged?()
            guard feedbackWindow == nil, processingItem?.isHidden == false else { exit(54) }
            example.recognition = .ready
            example.nextReminder = Date().addingTimeInterval(900)
            model.items = [example]
            model.onItemsChanged?()
            showCaptureFeedback(CaptureFeedback(item: example))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.feedbackWindow?.isVisible == true,
                      self.processingItem?.isHidden == true else { exit(55) }
                self.feedbackWindow?.orderOut(nil)
                self.model.items = previousItems
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-prompt-resource") {
            do {
                let prompt = try DeepSeekClient.systemPrompt()
                guard prompt.contains("分两次录入"), !prompt.contains("今天2026-09-29") else { exit(53) }
                NSApp.terminate(nil)
            } catch { exit(53) }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-notification-authorization") {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                print("authorizationStatus=\(settings.authorizationStatus.rawValue)")
                fflush(stdout)
                exit(settings.authorizationStatus == .authorized ? 0 : 44)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-capture-keyboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.showCapture()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let window = self.panel else { exit(48) }
                    guard window.isKeyWindow, window.firstResponder is NSTextView else {
                        fputs("录入框未取得焦点：key=\(window.isKeyWindow) active=\(NSApp.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown") responder=\(String(describing: window.firstResponder))\n", stderr)
                        exit(47)
                    }
                    guard self.statusItem.button != nil,
                          let screen = NSScreen.main ?? NSScreen.screens.first,
                          screen.visibleFrame.contains(window.frame) else {
                        fputs("菜单栏入口不可用或录入浮层不在当前屏幕可视范围\n", stderr)
                        exit(88)
                    }
                    self.sendDiagnosticEscape(to: window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        guard !window.isVisible else { exit(49) }
                        self.showCapture()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            guard window.isVisible else { exit(50) }
                            window.makeFirstResponder(window)
                            self.sendDiagnosticEscape(to: window)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                guard !window.isVisible else { exit(51) }
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-capture-feedback") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                var example = ReminderItem(text: "配置调节点出任务")
                example.title = "配置调节点出任务"
                example.nextReminder = Date().addingTimeInterval(3600)
                example.deadline = Date().addingTimeInterval(7200)
                self.showCaptureFeedback(CaptureFeedback(item: example))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let window = self.feedbackWindow, window.isVisible else { exit(45) }
                    let visible = (self.feedbackScreen ?? NSScreen.main)?.visibleFrame ?? .zero
                    guard window.frame.maxX <= visible.maxX, window.frame.maxY <= visible.maxY,
                          window.frame.minX >= visible.minX, window.frame.minY >= visible.minY,
                          visible.maxX - window.frame.maxX <= 24,
                          visible.maxY - window.frame.maxY <= 24 else { exit(46) }
                    window.orderOut(nil)
                    NSApp.terminate(nil)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-management-ui") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showManagement()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-management-escape") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showManagement()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, let window = self.management, let webView = self.managementWeb?.webView,
                          window.isVisible else { exit(62) }
                    webView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))") { _, error in
                        guard error == nil else { exit(63) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            guard !window.isVisible else {
                                fputs("管理页面按 Escape 后仍然打开\n", stderr)
                                exit(64)
                            }
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-management-drag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showManagement()
                guard let window = self?.management, let content = window.contentView else { exit(60) }
                guard window.styleMask.contains(.titled),
                      !window.styleMask.contains(.fullSizeContentView),
                      window.frame.height > content.frame.height else {
                    fputs("管理窗口没有独立的原生可拖动标题栏\n", stderr)
                    exit(61)
                }
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--check-management-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showManagement()
                guard self?.management?.isReleasedWhenClosed == false else {
                    fputs("管理窗口关闭后会释放，而菜单仍保留它的引用\n", stderr)
                    exit(42)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.management?.performClose(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.showManagement()
                        guard self?.management?.isVisible == true else {
                            fputs("关闭后未能重新打开管理窗口\n", stderr)
                            exit(43)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                    }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func checkRealNotification() async throws {
        let center = UNUserNotificationCenter.current()
        let authorization = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            center.getNotificationSettings { value in
                let raw = value.authorizationStatus.rawValue
                DispatchQueue.main.async { continuation.resume(returning: raw) }
            }
        }
        guard authorization == UNAuthorizationStatus.authorized.rawValue else {
            throw RecognitionError.invalid("通知未授权；不要在自动检查中修改用户权限")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryRealNotice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        model = try SecretaryModel(files: LocalFiles(directory: directory))
        model.notificationGranted = true
        let now = Date()
        var entries: [ReminderItem] = []
        for number in 1...6 {
            var item = ReminderItem(text: "虚构通知测试事项 \(number)", now: now.addingTimeInterval(-3600))
            try item.apply(.init(title: "测试项\(number)", reminder: now.addingTimeInterval(-10),
                                 deadline: nil, suggestedCompletion: nil), now: now.addingTimeInterval(-3600))
            if number == 1 { item.notificationsSent = 1 }
            guard model.update(item) else { throw RecognitionError.invalid("测试事项未保存") }
            entries.append(item)
        }
        let expected = Set(entries.map(\.id.uuidString))
        let title = "MySecretary 测试：6 件待处理"
        let body = ReminderSchedule.summary(entries)
        guard body.contains("另有 3 件") else { throw RecognitionError.invalid("短标题溢出未显示") }
        let sent = await withCheckedContinuation { continuation in
            model.sendNotification(title: title, body: body, ids: entries.map(\.id)) { success in
                continuation.resume(returning: success)
            }
        }
        guard sent else { throw RecognitionError.invalid("通知中心未接受测试通知") }
        let delivered = await withCheckedContinuation { (continuation: CheckedContinuation<[(String, String, [String])], Never>) in
            center.getDeliveredNotifications { value in
                let rows = value.map { notification in
                    let ids = notification.request.content.userInfo["itemIDs"] as? [String] ?? []
                    return (notification.request.identifier, notification.request.content.title, ids)
                }
                DispatchQueue.main.async { continuation.resume(returning: rows) }
            }
        }
        let matching = delivered.filter { _, notificationTitle, ids in
            notificationTitle == title && Set(ids) == expected
        }
        center.removeDeliveredNotifications(withIdentifiers: matching.map { $0.0 })
        guard matching.count == 1 else {
            print("真实通知 API 已接受测试请求；Notification Center 当前可查询到 \(matching.count) 条（可能受勿扰/系统折叠影响，不宣称已显示或被看见）")
            return
        }
        print("系统通知中心接受并记录一条带六项关联 ID 与短标题溢出的测试通知；已移除测试通知，未改真实事项")
    }

    private func checkNotificationRoute() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryRoute-\(UUID().uuidString)")
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            let now = Date()
            let entries = try (1...6).map { number -> ReminderItem in
                var entry = ReminderItem(text: "合并测试原话 \(number)", now: now.addingTimeInterval(-3600))
                try entry.apply(.init(title: "标题\(number)", reminder: now.addingTimeInterval(-10),
                                      deadline: nil, suggestedCompletion: nil), now: now.addingTimeInterval(-3600))
                guard model.update(entry) else { throw RecognitionError.invalid("无法保存合并测试事项") }
                return entry
            }
            let payload: [String: Any] = ["itemIDs": entries.map { $0.id.uuidString }]
            openNotificationPayload(payload)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let web = self.managementWeb?.webView else { exit(126) }
                let script = """
                (()=>{const rows=[...document.querySelectorAll('#c-rows .c-line')];return JSON.stringify({count:rows.length,focus:document.querySelector('#c-notices')?.innerText,titles:rows.map(row=>row.innerText.slice(0,10))})})()
                """
                web.evaluateJavaScript(script) { value, error in
                    guard error == nil, let text = value as? String, text.contains("\"count\":6"),
                          text.contains("仅显示这次提醒"), (1...6).allSatisfy({ text.contains("标题\($0)") }) else {
                        fputs("通知关联页面失败：\(String(describing: value)) \(String(describing: error))\n", stderr)
                        exit(127)
                    }
                    web.evaluateJavaScript("document.querySelector('#show-all').click()") { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            web.evaluateJavaScript("!document.querySelector('#show-all')") { restored, error in
                                try? FileManager.default.removeItem(at: directory)
                                guard error == nil, (restored as? NSNumber)?.boolValue == true else {
                                    fputs("通知恢复全部失败：\(String(describing: restored)) \(String(describing: error))\n", stderr)
                                    exit(128)
                                }
                                print("合并通知关联六项、路由完整集合并可切回全部：通过")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        } catch { fputs("通知关联测试失败：\(error)\n", stderr); exit(129) }
    }

    private func checkPermissionUI() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryPermission-\(UUID().uuidString)")
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            guard model.update(ReminderItem(text: "虚构待处理事项")) else { exit(119) }
            model.notificationGranted = false
            model.onItemsChanged = { [weak self] in self?.updateStatusMenu(); self?.managementWeb?.refresh() }
            updateStatusMenu()
            guard permissionItem?.isHidden == false,
                  permissionItem?.title.contains("1 件待处理") == true else { exit(120) }
            showManagement()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.model.notificationGranted = false
                self?.model.onItemsChanged?()
                self?.updateStatusMenu()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let web = self.managementWeb?.webView else { exit(121) }
                web.evaluateJavaScript("document.querySelector('#c-notices')?.innerText + ' / ' + !!document.querySelector('#permission')") { value, error in
                    guard error == nil, (value as? String)?.contains("通知未开启") == true && (value as? String)?.contains("/ true") == true else {
                        fputs("权限页面失败：\(String(describing: value)) \(String(describing: error))\n", stderr)
                        exit(122)
                    }
                    self.model.notificationGranted = true
                    self.model.onItemsChanged?()
                    self.updateStatusMenu()
                    guard self.permissionItem?.isHidden == true else { exit(123) }
                    web.evaluateJavaScript("!document.querySelector('#permission')") { restored, error in
                        try? FileManager.default.removeItem(at: directory)
                        guard error == nil, (restored as? NSNumber)?.boolValue == true else {
                            fputs("权限恢复页面失败：\(String(describing: restored)) \(String(describing: error))\n", stderr)
                            exit(124)
                        }
                        print("通知不可用时菜单计数与页面入口、恢复后状态消失：通过")
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch { fputs("权限 UI 准备失败：\(error)\n", stderr); exit(125) }
    }

    private func checkCaptureEnter() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryCapture-\(UUID().uuidString)")
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            model.configuration.verified = true
            model.interpretationOverride = { _, _ in .needsConfirmation("假模型待确认") }
            showCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, let panel = self.panel, let editor = panel.firstResponder as? NSTextView else { exit(115) }
                editor.string = "周五上线，下周一检查结果"
                guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                   modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: panel.windowNumber, context: nil,
                                                   characters: "\r", charactersIgnoringModifiers: "\r",
                                                   isARepeat: false, keyCode: 36) else { exit(116) }
                panel.sendEvent(enter)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let first = self.model.items.first
                    guard panel.isVisible == false, first?.originalText == "周五上线，下周一检查结果",
                          self.model.add("周五上线，下周一检查结果"),
                          self.model.items.count == 2,
                          Set(self.model.items.map(\.id)).count == 2,
                          (try? self.model.store.all().count) == 2 else { exit(117) }
                    try? FileManager.default.removeItem(at: directory)
                    print("录入 Enter 落盘即收起、复合原话完整、重复原话独立保存：通过")
                    NSApp.terminate(nil)
                }
            }
        } catch { fputs("录入检查准备失败：\(error)\n", stderr); exit(118) }
    }

    private func checkCommandActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryCommand-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        model = try SecretaryModel(files: LocalFiles(directory: directory))
        model.configuration.verified = true
        let initial = Date()
        var item = ReminderItem(text: "查订单", now: initial)
        try item.apply(.init(title: "查订单", reminder: initial.addingTimeInterval(3600),
                             deadline: initial.addingTimeInterval(7200), suggestedCompletion: nil))
        guard model.update(item) else { throw RecognitionError.invalid("准备指令测试失败") }
        let safePreviewDate = initial.addingTimeInterval(6000)
        model.timeEditOverride = { _, _ in .update(TimeEdit(reminder: safePreviewDate)) }
        guard case .preview = await model.previewReminderCommand(item.id, instruction: "稍早一些提醒"),
              model.items.first?.nextReminder == initial.addingTimeInterval(3600),
              case .applied = model.confirmReminderPreview(item.id),
              model.items.first?.nextReminder == safePreviewDate else {
            throw RecognitionError.invalid("普通提醒解析未按预览／确认两步执行")
        }
        model.timeEditOverride = { _, _ in .choosePreset }
        showManagement()
        try await Task.sleep(for: .seconds(2))
        guard let web = managementWeb?.webView else { throw RecognitionError.invalid("当前事项页面未打开") }
        let submitted = try await web.evaluateJavaScript("""
        (()=>{document.querySelector('[data-filter="later"]')?.click();document.querySelector('[data-action="snooze"]')?.click();const form=document.querySelector('#c-reminder-command');if(!form)return '未显示提醒输入';form.elements.instruction.value='晚点';form.requestSubmit();return 'submitted'})()
        """) as? String
        guard submitted == "submitted" else { throw RecognitionError.invalid(submitted ?? "指令输入未提交") }
        try await Task.sleep(for: .milliseconds(300))
        let shown = try await web.evaluateJavaScript("document.querySelector('#c-reminder-preview')?.innerText.includes('选择上面的预设')") as? Bool
        guard shown == true else { throw RecognitionError.invalid("晚点没有提示选择预设") }
        let previewDate = initial.addingTimeInterval(9300)
        model.timeEditOverride = { _, _ in .update(TimeEdit(reminder: previewDate)) }
        let submittedPreview = try await web.evaluateJavaScript("""
        (()=>{const form=document.querySelector('#c-reminder-command');form.elements.instruction.value='三小时后提醒';form.requestSubmit();return true})()
        """) as? Bool
        guard submittedPreview == true else { throw RecognitionError.invalid("未提交自然语言时间") }
        try await Task.sleep(for: .milliseconds(300))
        let hasPreview = try await web.evaluateJavaScript("document.querySelector('#c-reminder-preview')?.innerText.includes('将改为')") as? Bool
        guard hasPreview == true, model.items.first?.nextReminder == safePreviewDate else {
            throw RecognitionError.invalid("解析时间时提前修改了提醒")
        }
        _ = try await web.evaluateJavaScript("document.querySelector('#c-reminder-preview button')?.click()")
        try await Task.sleep(for: .milliseconds(200))
        let warning = try await web.evaluateJavaScript("document.querySelector('#c-reminder-preview')?.innerText.includes('晚于明确截止')") as? Bool
        guard warning == true, model.items.first?.nextReminder == safePreviewDate else {
            throw RecognitionError.invalid("超过截止未要求再次确认")
        }
        let revisedDeadline = initial.addingTimeInterval(10_800)
        model.timeEditOverride = { _, _ in .update(TimeEdit(reminder: initial.addingTimeInterval(9600),
                                                           deadline: .instant(revisedDeadline))) }
        let edited = try await web.evaluateJavaScript("""
        (()=>{document.querySelector('[data-filter="later"]')?.click();document.querySelector('[data-action="edit"]')?.click();const form=document.querySelector('#c-edit-command');if(!form)return '编辑中无指令输入';form.elements.instruction.value='明天九点提醒我，截止改为明天下午六点';form.requestSubmit();return 'submitted'})()
        """) as? String
        guard edited == "submitted" else { throw RecognitionError.invalid(edited ?? "编辑指令不可用") }
        try await Task.sleep(for: .milliseconds(300))
        let editPreview = try await web.evaluateJavaScript("document.querySelector('#c-edit-preview')?.innerText.includes('提醒改为') && document.querySelector('#c-edit-preview')?.innerText.includes('明确截止改为') && !document.querySelector('#c-edit-preview')?.innerText.includes('内容改为')") as? Bool
        guard editPreview == true, model.items.first?.text == "查订单",
              model.items.first?.deadline == item.deadline else {
            throw RecognitionError.invalid("编辑时间预览提前提交或修改了内容")
        }
        _ = try await web.evaluateJavaScript("document.querySelector('#c-edit-preview button')?.click()")
        try await Task.sleep(for: .milliseconds(200))
        guard model.items.first?.nextReminder == initial.addingTimeInterval(9600),
              model.items.first?.deadline == revisedDeadline, model.items.first?.text == "查订单" else {
            throw RecognitionError.invalid("提醒与截止未一起提交或误修改内容")
        }
        print("提醒与截止分别预览后原子提交，内容不受模型修改；含糊提醒不猜时间：通过")
    }

    private func checkSuccessBanner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretarySuccessBanner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        model = try SecretaryModel(files: LocalFiles(directory: directory))
        model.configuration.verified = true
        model.interpretationOverride = { _, _ in
            .schedule(Interpretation(title: "演示事项", reminder: Date().addingTimeInterval(3600),
                                     deadline: nil, suggestedCompletion: nil))
        }
        guard model.add("演示事项") else { throw RecognitionError.invalid("未保存测试事项") }
        for _ in 0..<100 {
            if model.items.first?.recognition == .ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.items.first?.recognition == .ready else { throw RecognitionError.invalid("假模型结果未完成") }
        showManagement()
        try await Task.sleep(for: .seconds(2))
        guard let web = managementWeb?.webView else { throw RecognitionError.invalid("管理页面未加载") }
        let banner = try await web.evaluateJavaScript("document.querySelector('#c-notices')?.innerText || ''") as? String ?? ""
        guard !banner.contains("已安排："), model.message.isEmpty else {
            throw RecognitionError.invalid("安排成功后旧消息持续留在管理页面：\(banner)")
        }
        print("成功仅使用短暂反馈卡，管理页面无常驻已安排消息：通过")
    }

    private func checkPostSaveRoute() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryPostSave-\(UUID().uuidString)")
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            let now = Date()
            var target = ReminderItem(text: "保存后仍应留在这里", now: now.addingTimeInterval(-3600))
            try target.apply(.init(title: "目标事项", reminder: now.addingTimeInterval(-60),
                                   deadline: nil, suggestedCompletion: nil), now: now.addingTimeInterval(-3600))
            var other = ReminderItem(text: "另一个稍后事项", now: now)
            try other.apply(.init(title: "其他事项", reminder: now.addingTimeInterval(60),
                                  deadline: nil, suggestedCompletion: nil), now: now)
            guard model.update(target), model.update(other) else { exit(132) }
            let id = target.id.uuidString
            showManagement()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let web = self.managementWeb?.webView else { exit(133) }
                let script = """
                (()=>{const row=document.querySelector('[data-item="\(id)"]');if(!row)return '目标不在当前待处理';row.click();document.querySelector('[data-action="snooze"]')?.click();const preset=document.querySelector('.c-snooze-popover .quick button');if(!preset)return '无预设';preset.click();return 'submitted'})()
                """
                web.evaluateJavaScript(script) { value, error in
                    guard error == nil, value as? String == "submitted" else { exit(134) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let assertion = """
                        (()=>{const row=document.querySelector('.c-line.selected');return JSON.stringify({tab:document.querySelector('[data-filter="later"]')?.classList.contains('chosen'),id:row?.dataset.item,title:document.querySelector('#c-detail h2')?.innerText,note:document.querySelector('.c-saved-note')?.innerText})})()
                        """
                        web.evaluateJavaScript(assertion) { result, error in
                            try? FileManager.default.removeItem(at: directory)
                            guard error == nil, let text = result as? String,
                                  text.contains("\"tab\":true"), text.contains(id),
                                  text.contains("目标事项"), text.contains("已保存") else {
                                fputs("保存后路由不正确：\(String(describing: result)) \(String(describing: error))\n", stderr)
                                exit(135)
                            }
                            print("当前事项改为未来时间后切到稍后，仍选中原事项并显示已保存：通过")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        } catch { fputs("保存后路由准备失败：\(error)\n", stderr); exit(136) }
    }

    private func checkManagementList() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryList-\(UUID().uuidString)")
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            let now = Date()
            model.settings.presetRules = [ReminderPreset(minutes: 15), ReminderPreset(dayOffset: 1, hour: 9, minute: 0)]
            var current = ReminderItem(text: "当前原话", now: now.addingTimeInterval(-3600))
            try current.apply(.init(title: "当前项", reminder: now.addingTimeInterval(-60), deadline: now.addingTimeInterval(300),
                                    reminderSource: "explicit", timeEvidence: ["当前原话"], suggestedCompletion: nil),
                              now: now.addingTimeInterval(-3600))
            var later = ReminderItem(text: "稍后原话", now: now)
            try later.apply(.init(title: "稍后项", reminder: now.addingTimeInterval(3600), deadline: nil,
                                  suggestedCompletion: nil), now: now)
            var pending = ReminderItem(text: "待识别原话", now: now)
            pending.fail("假模型失败", now: now)
            var history = current
            history.id = UUID()
            history.title = "历史项"
            history.status = .completed
            for item in [current, later, pending, history] { guard model.update(item) else { exit(110) } }
            showManagement()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let web = self.managementWeb?.webView else { exit(111) }
                let script = """
                (()=>{if(!document.querySelector('[data-filter="current"]'))return '页面未加载:'+document.URL+':'+document.body?.innerText.slice(0,80);const result=[];for(const [tab,expected] of [['current','当前项'],['later','稍后项'],['attention','待识别原话'],['history','历史项']]){document.querySelector('[data-filter="'+tab+'"]').click();const row=document.querySelector('#c-rows')?.innerText||'';if(!row.includes(expected))return '缺少'+tab+':'+row;result.push(tab)}document.querySelector('[data-filter="current"]').click();const detail=document.querySelector('#c-detail');if(!detail?.innerText.includes('提醒时间来源')||!detail?.innerText.includes('当前原话'))return '来源或原话不可见';detail.querySelector('[data-action="snooze"]').click();const buttons=[...document.querySelectorAll('.c-snooze-popover .quick button')];if(buttons.length!==2||!buttons[1].innerText.includes('明天 09:00'))return '日期预设未显示';buttons[0].click();return document.querySelector('.c-snooze-feedback button')?.innerText.includes('确认越过截止')?'ok':'未提供截止确认'})()
                """
                web.evaluateJavaScript(script) { value, error in
                    try? FileManager.default.removeItem(at: directory)
                    guard error == nil, value as? String == "ok" else {
                        fputs("管理列表检查失败：\(String(describing: value)) \(String(describing: error))\n", stderr)
                        exit(112)
                    }
                    print("当前、稍后、待识别、历史与原话/时间来源显示：通过")
                    NSApp.terminate(nil)
                }
            }
        } catch { fputs("管理列表准备失败：\(error)\n", stderr); exit(113) }
    }

    private func checkRecognitionRace() async throws {
        @MainActor final class Gate {
            var started: CheckedContinuation<Void, Never>?
            var waiting: CheckedContinuation<InterpretationDecision, Never>?
            func interpret() async -> InterpretationDecision {
                started?.resume()
                started = nil
                return await withCheckedContinuation { waiting = $0 }
            }
            func waitUntilStarted() async {
                if waiting != nil { return }
                await withCheckedContinuation { started = $0 }
            }
            func release(_ decision: InterpretationDecision) {
                waiting?.resume(returning: decision)
                waiting = nil
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryRace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        model = try SecretaryModel(files: LocalFiles(directory: directory))
        model.configuration.verified = true
        let text = "测试迟到识别，不写真实事项"
        let interpretation = Interpretation(title: "迟到的建议", reminder: Date().addingTimeInterval(3600),
                                            deadline: nil, suggestedCompletion: nil)
        for operation in ["snooze", "edit", "complete", "cancel"] {
            let gate = Gate()
            model.interpretationOverride = { _, _ in await gate.interpret() }
            guard model.add(text), let item = model.items.first else {
                throw RecognitionError.invalid("原话未先保存")
            }
            await gate.waitUntilStarted()
            switch operation {
            case "snooze":
                guard model.snooze(item, until: Date().addingTimeInterval(7200)) else {
                    throw RecognitionError.invalid("识别中无法手动改时")
                }
            case "edit":
                guard model.editDetails(item, title: "我自己改的标题", text: "我自己改的内容",
                                        reminder: Date().addingTimeInterval(5400), deadline: nil,
                                        deadlineDay: nil, clearPeriod: false, resolvesSingleAction: false) else {
                    throw RecognitionError.invalid("识别中无法手动改内容")
                }
            case "complete":
                guard model.changeStatus(item, to: .completed) else {
                    throw RecognitionError.invalid("识别中无法完成")
                }
            default:
                guard model.changeStatus(item, to: .cancelled) else {
                    throw RecognitionError.invalid("识别中无法取消")
                }
            }
            let expected = model.items.first!
            gate.release(.schedule(interpretation))
            try await Task.sleep(for: .milliseconds(150))
            let saved = try model.store.all().first(where: { $0.id == item.id })
            guard saved == expected, model.items.first(where: { $0.id == item.id }) == expected else {
                throw RecognitionError.invalid("迟到结果覆盖了用户操作：\(operation)")
            }
            print("识别中\(operation)后迟到模型响应不覆盖：通过")
        }
        let gate = Gate()
        model.interpretationOverride = { _, _ in await gate.interpret() }
        guard model.add(text), let added = model.items.first else {
            throw RecognitionError.invalid("撤销测试原话未保存")
        }
        await gate.waitUntilStarted()
        guard model.undoCapture(added.id) else { throw RecognitionError.invalid("识别中无法撤销录入") }
        gate.release(.schedule(interpretation))
        try await Task.sleep(for: .milliseconds(150))
        guard !(try model.store.all()).contains(where: { $0.id == added.id }),
              !model.items.contains(where: { $0.id == added.id }) else {
            throw RecognitionError.invalid("迟到响应重新创建了已撤销事项")
        }
        print("识别中撤销原话后迟到模型响应不复活：通过")
        model.interpretationOverride = nil
        try await checkRecognitionRetry()
    }

    private func checkRecognitionRetry() async throws {
        @MainActor final class Gate {
            var pending: [CheckedContinuation<InterpretationDecision, Error>] = []
            func interpret() async throws -> InterpretationDecision {
                try await withCheckedThrowingContinuation { pending.append($0) }
            }
            func waitFor(_ count: Int) async {
                while pending.count < count { await Task.yield() }
            }
            func release(_ decision: InterpretationDecision) {
                pending.removeFirst().resume(returning: decision)
            }
            func fail() {
                pending.removeFirst().resume(throwing: RecognitionError.invalid("假模型无效 JSON"))
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        model = try SecretaryModel(files: LocalFiles(directory: directory))
        model.configuration.verified = true
        model.notificationOverride = { _, _, _, completion in completion(true) }
        let gate = Gate()
        let original = "明天检查订单"
        var inputs: [String] = []
        model.interpretationOverride = { text, _ in
            inputs.append(text)
            return try await gate.interpret()
        }
        guard model.add(original), let item = model.items.first else { throw RecognitionError.invalid("初次录入失败") }
        await gate.waitFor(1)
        gate.fail()
        try await waitForRecognition(item.id, .needsAttention)
        guard model.retryRecognition(item.id) else { throw RecognitionError.invalid("失败事项无法手动重试") }
        await gate.waitFor(1)
        guard !model.retryRecognition(item.id) else { throw RecognitionError.invalid("允许重复并发重试") }
        gate.fail()
        try await waitForRecognition(item.id, .needsAttention)
        guard model.retryRecognition(item.id) else { throw RecognitionError.invalid("二次失败后不能重试") }
        await gate.waitFor(1)
        let next = Date().addingTimeInterval(3600)
        gate.release(.schedule(Interpretation(title: "检查订单", reminder: next, deadline: nil, suggestedCompletion: nil)))
        try await waitForRecognition(item.id, .ready)
        guard let saved = try model.store.all().first(where: { $0.id == item.id }),
              model.items.count == 1, saved.originalText == original, saved.nextReminder != nil,
              inputs == [original, original, original], !model.retryRecognition(item.id) else {
            throw RecognitionError.invalid("重试结果未复用原事项和原话")
        }
        print("识别失败后手动重试、重复失败再重试、同 ID 原话持久化：通过")

        // A prior result must not overwrite the later retry, even if its response arrives last.
        var stale = ReminderItem(text: original)
        stale.fail("旧失败")
        guard model.update(stale), model.retryRecognition(stale.id) else { throw RecognitionError.invalid("重试旧事项失败") }
        await gate.waitFor(1)
        // Simulate an older attempt still running when the item became retryable again.
        var failed = model.items.first(where: { $0.id == stale.id })!
        failed.fail("再次失败")
        guard model.update(failed), model.retryRecognition(stale.id) else { throw RecognitionError.invalid("新一轮重试失败") }
        await gate.waitFor(2)
        let newer = Interpretation(title: "新结果", reminder: next, deadline: nil, suggestedCompletion: nil)
        // Release the older request first, then ensure it cannot commit before the newer response.
        gate.release(.schedule(Interpretation(title: "旧结果", reminder: next, deadline: nil, suggestedCompletion: nil)))
        try await Task.sleep(for: .milliseconds(100))
        guard model.items.first(where: { $0.id == stale.id })?.recognition == .interpreting else {
            throw RecognitionError.invalid("旧尝试覆盖新重试")
        }
        gate.release(.schedule(newer))
        try await waitForRecognition(stale.id, .ready)
        guard model.items.first(where: { $0.id == stale.id })?.title == "新结果" else {
            throw RecognitionError.invalid("新重试结果未保存")
        }
        print("旧识别结果不覆盖新重试：通过")

        for operation in ["edit", "complete", "cancel"] {
            var pending = ReminderItem(text: original)
            pending.fail("待重试")
            guard model.update(pending), model.retryRecognition(pending.id) else { throw RecognitionError.invalid("无法启动重试") }
            await gate.waitFor(1)
            if operation == "edit" {
                guard model.editDetails(pending, title: "手动标题", text: "手动内容", reminder: nil,
                                        deadline: nil, deadlineDay: nil, clearPeriod: false,
                                        resolvesSingleAction: false) else { throw RecognitionError.invalid("手动编辑失败") }
            } else {
                guard model.changeStatus(pending, to: operation == "complete" ? .completed : .cancelled) else {
                    throw RecognitionError.invalid("修改状态失败")
                }
            }
            let expected = model.items.first(where: { $0.id == pending.id })!
            gate.release(.schedule(newer))
            try await Task.sleep(for: .milliseconds(100))
            guard model.items.first(where: { $0.id == pending.id }) == expected,
                  (try model.store.all()).first(where: { $0.id == pending.id }) == expected else {
                throw RecognitionError.invalid("重试覆盖手动操作：\(operation)")
            }
        }
        print("重试期间编辑、完成、取消不被覆盖：通过")
        var edited = ReminderItem(text: original)
        edited.fail("待识别")
        guard model.update(edited), model.editDetails(edited, title: "自己的标题", text: "自己的内容",
            reminder: nil, deadline: nil, deadlineDay: nil, clearPeriod: false, resolvesSingleAction: false),
            !model.retryRecognition(edited.id) else {
            throw RecognitionError.invalid("编辑后仍允许模型重新覆盖")
        }
        var split = ReminderItem(text: original)
        split.fail("两个行动", needsSeparateEntries: true)
        guard model.update(split), !model.retryRecognition(split.id) else {
            throw RecognitionError.invalid("需分录事项不能直接重试")
        }
        print("已编辑事项与需分录事项拒绝重试：通过")
        model.interpretationOverride = nil
    }

    private func waitForRecognition(_ id: UUID, _ status: RecognitionStatus) async throws {
        for _ in 0..<100 {
            if model.items.first(where: { $0.id == id })?.recognition == status { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RecognitionError.invalid("等待识别状态超时：\(status)")
    }

    private func checkReminderDispatch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryDispatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            model.notificationGranted = true
            let now = Date()
            let dueAt = now.addingTimeInterval(-120)
            var entries: [ReminderItem] = []
            for number in 1...6 {
                var item = ReminderItem(text: "虚构测试项 \(number)", now: now.addingTimeInterval(-3600))
                try item.apply(.init(title: "事项\(number)", reminder: dueAt,
                                     deadline: nil, suggestedCompletion: nil), now: now.addingTimeInterval(-3600))
                if number == 1 { item.notificationsSent = 1 }
                guard model.update(item) else { exit(70) }
                entries.append(item)
            }
            var sent = 0
            var shouldSucceed = false
            model.notificationOverride = { title, body, ids, completion in
                sent += 1
                guard title.contains("6 件"), body.contains("另有 3 件"),
                      Set(ids) == Set(entries.map(\.id)) else { exit(71) }
                completion(shouldSucceed)
            }
            model.checkDue(now: now)
            guard sent == 1 else { exit(72) }
            guard model.items.allSatisfy({ current in
                entries.first(where: { $0.id == current.id })?.notificationsSent == current.notificationsSent &&
                entries.first(where: { $0.id == current.id })?.nextReminder == current.nextReminder
            }) else { exit(73) }
            shouldSucceed = true
            model.checkDue(now: now)
            guard sent == 2, model.items.allSatisfy({ current in
                guard let prior = entries.first(where: { $0.id == current.id }) else { return false }
                return current.notificationsSent == prior.notificationsSent + 1 && current.nextReminder != nil
            }) else { exit(74) }
            model.checkDue(now: now)
            guard sent == 2 else { exit(75) }
            let first = model.items.first(where: { $0.id == entries[0].id })!
            guard first.nextReminder!.timeIntervalSinceNow > 7000 else { exit(76) }
            print("派发失败不推进、成功仅推进一次；混合首次/重试合并及六项关联：通过")
            NSApp.terminate(nil)
        } catch { fputs("提醒派发检查失败：\(error)\n", stderr); exit(77) }
    }

    private func checkReminderRecovery() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            model.notificationGranted = true
            let now = Date()
            let overdue = now.addingTimeInterval(-2 * 24 * 3600)
            var items: [ReminderItem] = []
            for number in 1...2 {
                var item = ReminderItem(text: "过期项 \(number)", now: overdue.addingTimeInterval(-3600))
                try item.apply(.init(title: "过期项 \(number)", reminder: overdue,
                                     deadline: nil, suggestedCompletion: nil), now: overdue.addingTimeInterval(-3600))
                guard model.update(item) else { exit(78) }
                items.append(item)
            }
            var notifications = 0
            model.notificationOverride = { _, _, ids, completion in
                notifications += 1
                guard Set(ids) == Set(items.map(\.id)) else { exit(79) }
                completion(true)
            }
            // Reopen a persisted ledger after two days; don't replay elapsed retries.
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            model.notificationGranted = true
            model.notificationOverride = { _, _, ids, completion in
                notifications += 1
                guard Set(ids) == Set(items.map(\.id)) else { exit(79) }
                completion(true)
            }
            model.checkDue(now: now)
            guard notifications == 1,
                  model.items.allSatisfy({ $0.notificationsSent == 1 && $0.nextReminder != nil }),
                  ReminderSchedule.due(model.items, at: now).isEmpty else { exit(80) }
            model.checkDue(now: now)
            guard notifications == 1 else { exit(81) }
            print("退出两天重开只合并补发一次，未虚算遗漏轮次：通过")
            NSApp.terminate(nil)
        } catch { fputs("重开补发检查失败：\(error)\n", stderr); exit(82) }
    }

    private func checkReminderDigest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryDigest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            model.notificationGranted = true
            let now = Date()
            var expired = ReminderItem(text: "汇总过期事项", now: now.addingTimeInterval(-3600))
            try expired.apply(.init(title: "过期", reminder: now.addingTimeInterval(-120), deadline: nil,
                                    suggestedCompletion: nil), now: now.addingTimeInterval(-3600))
            var pending = ReminderItem(text: "汇总待识别事项", now: now.addingTimeInterval(-3600))
            pending.fail("虚构识别故障", now: now.addingTimeInterval(-1800))
            var snoozed = expired
            snoozed.id = UUID()
            try snoozed.snooze(until: now.addingTimeInterval(3600), now: now)
            for item in [expired, pending, snoozed] { guard model.update(item) else { exit(83) } }
            var sent = 0
            var succeeds = false
            model.notificationOverride = { _, _, ids, completion in
                sent += 1
                guard Set(ids) == Set([expired.id, pending.id]) else { exit(84) }
                completion(succeeds)
            }
            guard model.sendDigest(now: now), sent == 1, model.settings.lastDigestDay.isEmpty,
                  model.items.first(where: { $0.id == expired.id })?.notificationsSent == 0 else { exit(85) }
            succeeds = true
            guard model.sendDigest(now: now), sent == 2,
                  model.settings.lastDigestDay == ReminderSchedule.digestDay(at: now),
                  model.items.first(where: { $0.id == expired.id })?.notificationsSent == 1,
                  model.items.first(where: { $0.id == pending.id })?.notificationsSent == 1,
                  model.items.first(where: { $0.id == snoozed.id })?.notificationsSent == 0,
                  !ReminderSchedule.shouldSendDigest(at: now, settings: model.settings) else { exit(86) }
            print("汇总失败可重试；成功记录当天并推进同轮到期事项，排除未来推迟：通过")
            NSApp.terminate(nil)
        } catch { fputs("每日汇总检查失败：\(error)\n", stderr); exit(87) }
    }

    private func checkClockRecompute() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryClock-\(UUID().uuidString)")
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            model.notificationGranted = true
            model.settings.lastDigestDay = ReminderSchedule.digestDay(at: .now)
            let now = Date()
            var item = ReminderItem(text: "系统时钟变化测试", now: now.addingTimeInterval(-3600))
            try item.apply(.init(title: "时钟测试", reminder: now.addingTimeInterval(-60),
                                 deadline: nil, suggestedCompletion: nil), now: now.addingTimeInterval(-3600))
            guard model.update(item) else { exit(89) }
            var sent = 0
            model.notificationOverride = { _, _, _, completion in sent += 1; completion(true) }
            NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, sent == 1,
                      self.model.items.first?.notificationsSent == 1 else { exit(90) }
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
                NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard sent == 1 else { exit(91) }
                    try? FileManager.default.removeItem(at: directory)
                    print("时钟变化立即重算；唤醒与时区变化不重放已派发轮次：通过")
                    NSApp.terminate(nil)
                }
            }
        } catch { fputs("时钟重算检查失败：\(error)\n", stderr); exit(92) }
    }

    private func checkItemLifecycle() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SecretaryLifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            model = try SecretaryModel(files: LocalFiles(directory: directory))
            let now = Date()
            var original = ReminderItem(text: "历史恢复测试", now: now.addingTimeInterval(-7200))
            let passedDeadline = now.addingTimeInterval(-60)
            try original.apply(.init(title: "过期但未完成", reminder: now.addingTimeInterval(-3600),
                                     deadline: passedDeadline, suggestedCompletion: nil), now: now.addingTimeInterval(-7200))
            guard model.update(original), model.items.first?.status == .open else { exit(93) }
            guard model.changeStatus(original, to: .completed), model.items.first?.nextReminder == nil,
                  model.undoStatus(original), model.items.first?.status == .open,
                  model.items.first?.nextReminder == original.nextReminder else { exit(94) }
            guard model.changeStatus(original, to: .cancelled) else { exit(95) }
            let newTime = now.addingTimeInterval(3600)
            guard !model.restore(original, until: newTime),
                  model.restore(original, until: newTime, overrideDeadline: true), model.items.first?.status == .open,
                  model.items.first?.nextReminder == newTime,
                  model.items.first?.notificationsSent == 0 else { exit(96) }
            let reopened = try SecretaryModel(files: LocalFiles(directory: directory))
            guard reopened.items.first?.nextReminder == newTime,
                  reopened.items.first?.deadline == passedDeadline,
                  reopened.items.first?.status == .open else { exit(97) }
            print("过期仍未完成；完成/取消、立即撤销与历史选新时间恢复持久化：通过")
            NSApp.terminate(nil)
        } catch { fputs("事项生命周期检查失败：\(error)\n", stderr); exit(98) }
    }

    private func sendDiagnosticEscape(to window: NSWindow) {
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: false, keyCode: 53) else { exit(52) }
        window.sendEvent(key)
    }

    private func tick() {
        model.refreshPermission()
        let now = Date()
        if !ReminderSchedule.shouldSendDigest(at: now, settings: model.settings) || !model.sendDigest(now: now) {
            model.checkDue(now: now)
        }
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        guard statusItem != nil else { return }
        let unhealthy = !model.notificationGranted || model.items.contains { $0.recognition == .needsAttention && $0.status == .open }
        let processing = model.items.contains { $0.recognition == .interpreting && $0.status == .open }
        statusItem.button?.image = NSImage(systemSymbolName: unhealthy ? "bell.slash.fill" : (processing ? "clock.arrow.circlepath" : "checklist"),
                                          accessibilityDescription: unhealthy ? "My Secretary：提醒不可用或有待处理错误" : (processing ? "My Secretary：已记下，正在安排提醒" : "My Secretary"))
        permissionItem?.isHidden = model.notificationGranted
        let pendingCount = model.items.filter { $0.status == .open }.count
        permissionItem?.title = "⚠️ 通知未开启 · \(pendingCount) 件待处理，打开系统设置"
        processingItem?.isHidden = !processing
        undoCaptureItem?.isHidden = !model.items.contains {
            $0.id == model.lastCapturedID && $0.status == .open && Date().timeIntervalSince($0.createdAt) < 120
        }
    }

    private func createStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "My Secretary")
        let menu = NSMenu()
        let capture = NSMenuItem(title: "记下一件事", action: #selector(showCapture), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        let undoCapture = NSMenuItem(title: "撤销刚录入的事项", action: #selector(undoLastCapture), keyEquivalent: "")
        undoCapture.target = self
        undoCapture.isHidden = true
        menu.addItem(undoCapture)
        undoCaptureItem = undoCapture
        let all = NSMenuItem(title: "查看事项", action: #selector(showManagement), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        let settings = NSMenuItem(title: "设置", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let processing = NSMenuItem(title: "已记下，正在安排提醒…", action: nil, keyEquivalent: "")
        processing.isHidden = true
        menu.addItem(processing)
        processingItem = processing
        let permission = NSMenuItem(title: "⚠️ 通知未开启，打开系统设置", action: #selector(openNotificationSettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        permissionItem = permission
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func showCaptureFeedback(_ feedback: CaptureFeedback) {
        feedbackToken = feedback.id
        if feedbackWindow == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 356, height: 120),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            feedbackWindow = window
        }
        feedbackWindow?.contentView = NSHostingView(rootView: CaptureFeedbackView(feedback: feedback, openItem: { [weak self] in
            self?.feedbackWindow?.orderOut(nil)
            self?.model.focusedNotificationIDs = [feedback.itemID]
            self?.presentManagement()
        }, undo: { [weak self] in
            guard let self, self.model.undoCapture(feedback.itemID) else { return }
            self.feedbackWindow?.orderOut(nil)
            self.feedbackToken = nil
        }))
        // Position against the usable bounds of the screen where capture occurred,
        // not against the menu-bar icon (which can appear far from the right edge).
        let screen = feedbackScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        let contentSize = feedbackWindow?.contentView?.fittingSize ?? NSSize(width: 340, height: 130)
        let frame = NSRect(x: visible.maxX - contentSize.width - 16,
                           y: visible.maxY - contentSize.height - 16,
                           width: contentSize.width, height: contentSize.height)
        feedbackWindow?.setFrame(frame, display: true)
        // Wait until the Enter event has closed the capture panel; keep focus in
        // the user's previous app unless they explicitly click the feedback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.feedbackToken == feedback.id else { return }
            self.feedbackWindow?.orderFrontRegardless()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.feedbackToken == feedback.id else { return }
            self.feedbackWindow?.orderOut(nil)
            self.feedbackToken = nil
        }
    }

    private func checkLoginLaunchStatus() {
        do {
            let status = SMAppService.mainApp.status
            guard [SMAppService.Status.enabled, .notRegistered, .requiresApproval, .notFound].contains(status) else {
                fputs("登录启动返回未知状态：\(status.rawValue)\n", stderr)
                exit(131)
            }
            print("登录启动服务状态可查询：\(status.rawValue)\(status == .notFound ? "（当前临时构建未安装，无法验证开机启动）" : "")；未替用户修改系统设置")
            NSApp.terminate(nil)
        }
    }

    @objc func openNotificationSettings() {
        SecretaryModel.openSystemNotificationSettings()
    }

    @objc func undoLastCapture() {
        guard let id = model.lastCapturedID, model.undoCapture(id) else { return }
        feedbackWindow?.orderOut(nil)
        feedbackToken = nil
    }

    @objc func showCapture() {
        guard model.configuration.verified else { showSettings(); return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        feedbackScreen = screen
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        let rect = NSRect(x: frame.midX - 220, y: frame.midY + 30, width: 440, height: 106)
        if panel == nil {
            let window = CapturePanel(contentRect: rect, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            window.onCancel = { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.panel?.orderOut(nil) }
            }
            window.level = .floating
            window.animationBehavior = .none
            window.isFloatingPanel = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.titleVisibility = .hidden
            panel = window
        }
        // Create a fresh input view each time so the old focused TextField is not mutated
        // during its own submit event; close on the next event-loop turn.
        panel?.contentView = NSHostingView(rootView: CaptureView(model: model, dismiss: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.panel?.orderOut(nil) }
        }))
        panel?.setFrame(rect, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc func showManagement() {
        model.focusedNotificationIDs = nil
        presentManagement()
    }

    private func presentManagement() {
        if management == nil {
            management = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 650),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            management?.isReleasedWhenClosed = false
            management?.title = "My Secretary · 事项"
            management?.backgroundColor = NSColor(calibratedRed: 0.973, green: 0.980, blue: 0.984, alpha: 1)
            management?.center()
        }
        if managementWeb == nil {
            let host = ManagementWebHost(model: model, capture: { [weak self] in self?.showCapture() },
                                         close: { [weak self] in self?.management?.performClose(nil) })
            managementWeb = host
            management?.contentView = host.webView
        }
        // Preserve the web view across routes; reset only its transient navigation.
        managementWeb?.resetRoute()
        NSApp.activate(ignoringOtherApps: true)
        management?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.title = "My Secretary · 设置"
            window.center()
            settingsWindow = window
        }
        // Reset transient recorder state only when reopening a *closed* window.
        // Replacing the content while recording would strand the previous combo.
        if settingsWindow?.isVisible != true {
            restoreShortcut()
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model,
                applyShortcut: { [weak self] shortcut in self?.applyShortcut(shortcut) ?? false },
                suspendShortcut: { [weak self] in self?.suspendShortcut() },
                restoreShortcut: { [weak self] in self?.restoreShortcut() }))
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === settingsWindow { restoreShortcut() }
    }

    private func installHotKeyHandler() {
        guard hotKeyHandler == nil else { return }
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let owner = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in owner.showCapture() }
            return noErr
        }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    func registerHotKey() {
        guard hotKey == nil else { return }
        installHotKeyHandler()
        let identifier = EventHotKeyID(signature: 0x53454352, id: 1)
        let status = RegisterEventHotKey(model.settings.shortcutKey, model.settings.shortcutModifiers,
                                         identifier, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { model.message = "快捷键被其他应用占用，请在设置中重新录制" }
    }

    func suspendShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
    }

    func restoreShortcut() { registerHotKey() }

    @discardableResult
    func applyShortcut(_ shortcut: RecordedShortcut) -> Bool {
        installHotKeyHandler()
        if shortcut.keyCode == model.settings.shortcutKey && shortcut.modifiers == model.settings.shortcutModifiers {
            restoreShortcut()
            model.message = "快捷键已启用：\(shortcut.display)"
            return true
        }
        var candidate: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x53454352, id: nextHotKeyID)
        nextHotKeyID &+= 1
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else {
            model.message = "无法注册 \(shortcut.display)：可能与系统或其他应用冲突，原快捷键已保留"
            restoreShortcut()
            return false
        }
        let oldSettings = model.settings
        model.settings.shortcutKey = shortcut.keyCode
        model.settings.shortcutModifiers = shortcut.modifiers
        model.settings.shortcutDisplay = shortcut.display
        do {
            try model.files.saveSettings(model.settings)
        } catch {
            UnregisterEventHotKey(candidate)
            model.settings = oldSettings
            restoreShortcut()
            model.message = "新快捷键保存失败，原快捷键已保留"
            return false
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        model.message = "快捷键已启用：\(shortcut.display)"
        return true
    }

    private func openNotificationPayload(_ userInfo: [AnyHashable: Any]) {
        let ids = (userInfo["itemIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        model.focusedNotificationIDs = ids.isEmpty ? nil : Set(ids)
        presentManagement()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let ids = response.notification.request.content.userInfo["itemIDs"] as? [String] ?? []
        await MainActor.run { self.openNotificationPayload(["itemIDs": ids]) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct SecretaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

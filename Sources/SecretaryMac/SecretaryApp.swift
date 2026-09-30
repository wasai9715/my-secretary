import AppKit
import SwiftUI
import Carbon
import UserNotifications
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
    var onCaptureFeedback: (@MainActor (CaptureFeedback) -> Void)?
    var onItemsChanged: (@MainActor () -> Void)?
    private var dispatchingIDs: Set<UUID> = []
    let files: LocalFiles
    let store: ItemStore

    init() throws {
        files = try LocalFiles()
        store = try ItemStore(path: files.databasePath)
        items = try store.all()
        configuration = try files.loadConfiguration()
        settings = try files.loadSettings()
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

    func add(_ input: String) {
        guard configuration.verified else { message = "请先测试 DeepSeek 连接"; return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var item = ReminderItem(text: text)
        do { try store.upsert(item); items.insert(item, at: 0); onItemsChanged?() }
        catch { message = "本机保存失败：\(error.localizedDescription)"; return }
        message = "已记下，正在安排提醒"
        // Keep the in-flight state in the menu bar; one completed result gets
        // one unobtrusive feedback card instead of replacing a second card.
        let version = item.manualVersion
        let client = DeepSeekClient(configuration: configuration)
        Task {
            do {
                let result = try await client.interpret(text, now: item.createdAt)
                guard let current = items.first(where: { $0.id == item.id }), current.manualVersion == version, current.status == .open else { return }
                item = current
                switch result {
                case .schedule(let interpretation):
                    try item.apply(interpretation)
                    update(item)
                    let reminder = item.nextReminder?.formatted(date: .abbreviated, time: .shortened) ?? "待确认"
                    message = "已安排：\(reminder) 提醒"
                    onCaptureFeedback?(CaptureFeedback(item: item))
                case .separateEntries(let reason):
                    item.fail(reason, needsSeparateEntries: true)
                    update(item)
                    message = reason
                    sendNotification(title: "请分两次录入", body: "原话已保存，包含多个分别需要提醒的行动。点击查看。", ids: [item.id])
                case .needsConfirmation(let reason):
                    item.fail(reason)
                    update(item)
                    message = reason
                    sendNotification(title: "时间待确认", body: "\(item.title) — 点击查看或设置时间", ids: [item.id])
                }
            } catch {
                guard var current = items.first(where: { $0.id == item.id }), current.manualVersion == version, current.status == .open else { return }
                current.fail(error.localizedDescription)
                update(current)
                message = "识别失败：\(current.title)"
                sendNotification(title: "提醒尚未安排", body: "\(current.title) — 点击设置时间或重试", ids: [current.id])
            }
        }
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
                     resolvesSingleAction: Bool, restoreSplit: Bool = false) -> Bool {
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
        updated.text = text
        if restoreSplit && current.needsSeparateEntries == true { updated.status = .open }
        updated.deadline = deadline
        updated.deadlineDay = deadlineDay
        if clearPeriod { updated.deadlinePeriod = nil; updated.deadlinePeriodDay = nil }
        if let reminder, reminder != current.nextReminder || current.needsSeparateEntries == true {
            if current.needsSeparateEntries == true { updated.needsSeparateEntries = false }
            do { try updated.snooze(until: reminder, overrideDeadline: true) }
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

    func restore(_ item: ReminderItem, until date: Date) -> Bool {
        guard let current = items.first(where: { $0.id == item.id }), current.status != .open else { return false }
        var updated = current
        updated.status = .open
        do {
            try updated.snooze(until: date, overrideDeadline: true)
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
                self.notificationGranted = granted
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
        let due = items.filter { $0.status == .open && !dispatchingIDs.contains($0.id) && $0.nextReminder.map { $0 <= now } == true && $0.notificationsSent < ($0.recognition == .needsAttention ? 1 : 3) }
        guard !due.isEmpty, notificationGranted else { return }
        let titles = due.prefix(3).map(\.title).joined(separator: " · ")
        let rest = due.count > 3 ? " · 另有 \(due.count - 3) 件" : ""
        let ids = due.map(\.id)
        dispatchingIDs.formUnion(ids)
        let needsSplit = due.count == 1 && due[0].needsSeparateEntries == true
        sendNotification(title: needsSplit ? "请分两次录入" : "有 \(due.count) 件事需要处理",
                         body: needsSplit ? "原话仍待处理，尚未安排正常提醒" : titles + rest,
                         ids: ids) { success in
            self.dispatchingIDs.subtract(ids)
            guard success else { return }
            for old in due {
                guard var item = self.items.first(where: { $0.id == old.id }), item.status == .open,
                      item.nextReminder == old.nextReminder, item.notificationsSent == old.notificationsSent else { continue }
                item.notificationsSent += 1
                if item.recognition == .needsAttention || item.notificationsSent == 3 { item.nextReminder = nil }
                else { item.nextReminder = Date().addingTimeInterval(item.notificationsSent == 1 ? 30 * 60 : 2 * 60 * 60) }
                self.update(item)
            }
        }
    }

    func sendDigest(now: Date = .now) {
        let pending = items.filter { item in
            item.status == .open && (item.recognition == .needsAttention ||
                (item.firstReminder.map { $0 <= now } == true && (item.lastUserSnooze == nil || item.lastUserSnooze! <= now)))
        }
        guard !pending.isEmpty else { return }
        let titles = pending.prefix(3).map(\.title).joined(separator: " · ")
        sendNotification(title: "还有 \(pending.count) 件事未完成", body: titles + (pending.count > 3 ? " · 另有 \(pending.count - 3) 件" : ""), ids: pending.map(\.id))
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
        do { model = try SecretaryModel() }
        catch {
            NSAlert(error: error).runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        let isDiagnostic = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--check-") }
        model.refreshPermission(requestIfUndetermined: !isDiagnostic)
        createStatusMenu()
        model.onCaptureFeedback = { [weak self] feedback in self?.showCaptureFeedback(feedback) }
        model.onItemsChanged = { [weak self] in self?.updateStatusMenu() }
        registerHotKey()
        if !isDiagnostic { model.checkDue() }
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
                        fputs("录入框未取得焦点：key=\(window.isKeyWindow) responder=\(String(describing: window.firstResponder))\n", stderr)
                        exit(47)
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
        model.checkDue()
        let now = Date()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now).formatted(.iso8601)
        if (calendar.component(.hour, from: now), calendar.component(.minute, from: now)) >= (model.settings.digestHour, model.settings.digestMinute), day != model.settings.lastDigestDay, model.notificationGranted {
            model.sendDigest(now: now)
            model.settings.lastDigestDay = day
            model.saveSettings()
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
        processingItem?.isHidden = !processing
    }

    private func createStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "My Secretary")
        let menu = NSMenu()
        let capture = NSMenuItem(title: "记下一件事", action: #selector(showCapture), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
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

    @objc func openNotificationSettings() {
        SecretaryModel.openSystemNotificationSettings()
    }

    @objc func showCapture() {
        guard model.configuration.verified else { showSettings(); return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        feedbackScreen = screen
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        let rect = NSRect(x: frame.midX - 240, y: frame.midY + 30, width: 480, height: 130)
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let ids = (response.notification.request.content.userInfo["itemIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        await MainActor.run {
            self.model.focusedNotificationIDs = ids.isEmpty ? nil : Set(ids)
            self.presentManagement()
        }
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

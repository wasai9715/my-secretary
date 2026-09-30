import SwiftUI
import AppKit
import SecretaryCore
import WebKit
import Combine

struct CaptureView: View {
    @ObservedObject var model: SecretaryModel
    let dismiss: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.badge.plus").foregroundStyle(.tint)
                Text("记下一件事").font(.headline)
                Spacer()
                Text("ESC 关闭").font(.caption).foregroundStyle(.secondary)
            }
            FocusedCaptureField(text: $text, submit: {
                if model.add(text) { dismiss() }
            }, cancel: dismiss)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private final class CaptureTextControl: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // SwiftUI's onAppear can run before an NSPanel becomes key. Request
        // focus only after the native control is attached to its window.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            window.makeFirstResponder(self)
        }
    }
}

private struct FocusedCaptureField: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CaptureTextControl {
        let field = CaptureTextControl()
        field.placeholderString = "例如：明天 10 点前给领导数据"
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none // The subtler SwiftUI outline above indicates focus.
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: CaptureTextControl, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil && field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusedCaptureField
        init(_ parent: FocusedCaptureField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                parent.submit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                return true
            }
            return false
        }
    }
}

struct CaptureFeedbackView: View {
    let feedback: CaptureFeedback
    let openItem: () -> Void

    private var timeLabel: String {
        guard let date = feedback.reminder else { return "提醒时间待确认" }
        let calendar = Calendar.current
        let clock = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) { return "今天 \(clock)" }
        if calendar.isDateInTomorrow(date) { return "明天 \(clock)" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("提醒已安排")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(feedback.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Label(timeLabel, systemImage: "bell")
                    .foregroundStyle(.primary)
                if let day = feedback.deadlineDay {
                    Text("· 截止 \(day)").foregroundStyle(.secondary)
                } else if let deadline = feedback.deadline {
                    Text("· 截止 \(deadline.formatted(.dateTime.month().day().hour().minute()))")
                        .foregroundStyle(.secondary)
                } else if let suggestion = feedback.suggestedCompletion {
                    Text("· 建议完成 \(suggestion.formatted(.dateTime.month().day().hour().minute()))")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .help("点击查看或修改完整安排")
            HStack {
                Spacer()
                Button(action: openItem) {
                    HStack(spacing: 3) {
                        Text("查看或修改")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 14)
        .frame(width: 356, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .padding(5)
    }
}

private final class WeakManagementHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ManagementWebHost?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

// Keep the document alive for the lifetime of the management window. The document
// owns transient filter/form state; persisted mutations are exclusively native.
@MainActor
final class ManagementWebHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private let model: SecretaryModel
    private let capture: () -> Void
    private let close: () -> Void
    private var observation: AnyCancellable?
    private let handler = WeakManagementHandler()
    private var loaded = false
    private var pendingReset = false
    private var undoItem: ReminderItem?
    private var undoExpires: Date?

    init(model: SecretaryModel, capture: @escaping () -> Void, close: @escaping () -> Void) {
        self.model = model
        self.capture = capture
        self.close = close
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        handler.owner = self
        config.userContentController.add(handler, name: "management")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.publish() }
        }
        if let url = Self.managementURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            model.message = "事项管理页面资源缺失"
        }
    }

    func resetRoute() {
        pendingReset = true
        publish()
    }

    private static var managementURL: URL? {
        Bundle.main.url(forResource: "management", withExtension: "html") ??
            Bundle.module.url(forResource: "management", withExtension: "html")
    }

    private func local(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    private func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    private func safeMessage(_ message: String) -> String {
        if message.isEmpty { return "操作未完成，请重试" }
        let token = model.configuration.token
        if !token.isEmpty && message.contains(token) { return "操作未完成，请检查连接设置" }
        return message
    }

    private func json(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func evaluate(_ function: String, _ value: Any) {
        guard loaded, let encoded = json(value) else { return }
        webView.evaluateJavaScript("window.\(function)(\(encoded))", completionHandler: nil)
    }

    private func publish() {
        guard loaded else { return }
        let snapshot: [[String: Any]] = model.items.map { item in
            ["id": item.id.uuidString, "title": item.title, "original": item.originalText,
             "text": item.text, "status": item.status.rawValue, "recognition": item.recognition.rawValue,
             "reminder": local(item.nextReminder) as Any? ?? NSNull(),
             "deadline": local(item.deadline) as Any? ?? NSNull(),
             "deadlineDay": item.deadlineDay as Any? ?? NSNull(),
             "period": item.deadlinePeriod as Any? ?? NSNull(),
             "periodDay": item.deadlinePeriodDay as Any? ?? NSNull(),
             "suggestion": local(item.suggestedCompletion) as Any? ?? NSNull(),
             "failure": item.failure.map(safeMessage) as Any? ?? NSNull(),
             "split": item.needsSeparateEntries == true,
             "attention": item.recognition == .needsAttention,
             "created": item.createdAt.timeIntervalSince1970 * 1000]
        }
        // Never include configuration or credentials, even in error messages.
        let state: [String: Any] = ["items": snapshot,
            "focus": model.focusedNotificationIDs.map { $0.map(\.uuidString) } as Any? ?? NSNull(),
            "permission": model.notificationGranted,
            "message": model.message.isEmpty ? "" : safeMessage(model.message),
            "presets": model.settings.presetsMinutes,
            "reset": pendingReset]
        pendingReset = false
        evaluate("managementState", state)
    }

    private func result(_ action: String, error: String? = nil, undo: ReminderItem? = nil) {
        var response: [String: Any] = ["action": action]
        if let error { response["error"] = error }
        if let undo { response["undo"] = ["id": undo.id.uuidString, "status": action == "cancel" ? "cancelled" : "completed"] }
        publish()
        evaluate("managementResult", response)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        publish()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Only the bundled document may load; disallow links, forms and all network requests.
        decisionHandler(navigationAction.navigationType == .other &&
            navigationAction.request.url == Self.managementURL ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.name == "management",
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if action == "ready" { loaded = true; publish(); return }
        if action == "close" { close(); return }
        if action == "add" { capture(); return }
        if action == "all" { model.focusedNotificationIDs = nil; resetRoute(); return }
        if action == "permission" { SecretaryModel.openSystemNotificationSettings(); return }
        guard let rawID = body["id"] as? String, let id = UUID(uuidString: rawID),
              let item = model.items.first(where: { $0.id == id }) else { return }
        if action == "copy" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.originalText, forType: .string)
            return
        }
        if action == "undo" {
            guard undoItem?.id == id, let undoExpires, undoExpires > .now else { result(action, error: "撤销时间已结束"); return }
            let success = model.undoStatus(undoItem!)
            if success { undoItem = nil; self.undoExpires = nil }
            result(action, error: success ? nil : safeMessage(model.message))
            return
        }
        if action == "complete" || action == "cancel" {
            guard model.changeStatus(item, to: action == "complete" ? .completed : .cancelled) else {
                result(action, error: safeMessage(model.message)); return
            }
            undoItem = item
            undoExpires = Date().addingTimeInterval(7)
            result(action, undo: item)
            return
        }
        if action == "snooze" || action == "restore" {
            guard let value = body["reminder"] as? String, let when = parse(value), when > .now else {
                result(action, error: "请选择将来的有效提醒时间"); return
            }
            let success = action == "restore" ? model.restore(item, until: when) : model.snooze(item, until: when, overrideDeadline: true)
            result(action, error: success ? nil : safeMessage(model.message))
            return
        }
        if action == "edit" {
            guard let title = body["title"] as? String, let text = body["text"] as? String,
                  let reminderValue = body["reminder"] as? String else { return }
            let reminder = reminderValue.isEmpty ? nil : parse(reminderValue)
            guard reminderValue.isEmpty || reminder != nil else { result(action, error: "提醒时间无效"); return }
            let deadlineValue = body["deadline"] as? String
            let exact = deadlineValue?.contains("T") == true
            let deadline = exact ? parse(deadlineValue) : nil
            let day = exact ? nil : deadlineValue
            guard !exact || deadline != nil,
                  day == nil || (day?.isEmpty == true || ReminderItem.endOfLocalDay(day!) != nil) else {
                result(action, error: "截止日期无效"); return
            }
            let unchangedReminder = reminderValue == local(item.nextReminder)
            guard reminder == nil || unchangedReminder || reminder! > .now else {
                result(action, error: "请选择将来的提醒时间"); return
            }
            let success = model.editDetails(item, title: title, text: text,
                reminder: unchangedReminder ? item.nextReminder : reminder,
                deadline: deadline, deadlineDay: day?.isEmpty == false ? day : nil,
                clearPeriod: body["clearPeriod"] as? Bool ?? false,
                resolvesSingleAction: body["single"] as? Bool ?? false,
                restoreSplit: item.status != .open && item.needsSeparateEntries == true)
            result(action, error: success ? nil : safeMessage(model.message))
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SecretaryModel
    let applyShortcut: (RecordedShortcut) -> Bool
    let suspendShortcut: () -> Void
    let restoreShortcut: () -> Void
    @State private var isRecordingShortcut = false
    @State private var recordedShortcut: RecordedShortcut?
    @State private var endpoint = ""
    @State private var name = ""
    @State private var token = ""
    @State private var showAdvanced = false
    @State private var testing = false
    @State private var presetsInput = ""
    @State private var presetError = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsSection("智能识别", subtitle: "DeepSeek 用于理解事项和安排提醒") {
                    labeledField("API Token") {
                        SecureField("输入 API Token", text: $token)
                            .textFieldStyle(.roundedBorder)
                    }
                    DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            labeledField("API 地址") { TextField("API 地址", text: $endpoint) }
                            labeledField("模型") { TextField("模型", text: $name) }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                    HStack(spacing: 12) {
                        Button(testing ? "正在测试…" : "测试连接并保存") {
                            testing = true
                            Task {
                                await model.testAndSave(endpoint: endpoint, model: name, token: token)
                                testing = false
                            }
                        }.disabled(testing || token.isEmpty)
                        Label(model.configuration.verified ? "连接已验证" : "连接成功后可开始录入",
                              systemImage: model.configuration.verified ? "checkmark.circle.fill" : "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                settingsSection("快捷录入", subtitle: "在任意位置快速记下一件事") {
                    HStack {
                        Text("当前快捷键").foregroundStyle(.secondary)
                        Spacer()
                        Text(model.settings.shortcutDisplay ?? RecordedShortcut.label(
                            keyCode: model.settings.shortcutKey,
                            modifiers: model.settings.shortcutModifiers))
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack(spacing: 10) {
                        if isRecordingShortcut {
                            Text("按下你想使用的组合键…  Esc 取消")
                                .foregroundStyle(.blue)
                            ShortcutRecorder(recorded: $recordedShortcut, isRecording: $isRecordingShortcut,
                                onFinished: restoreShortcut)
                                .frame(width: 1, height: 28)
                            Button("取消") {
                                isRecordingShortcut = false
                                recordedShortcut = nil
                                restoreShortcut()
                            }
                        } else {
                            Button("录制快捷键") {
                                recordedShortcut = nil
                                suspendShortcut()
                                isRecordingShortcut = true
                            }
                            if let recordedShortcut {
                                Text("待应用：\(recordedShortcut.display)")
                                    .font(.system(.caption, design: .monospaced))
                                Button("应用") {
                                    if applyShortcut(recordedShortcut) { self.recordedShortcut = nil }
                                }
                            }
                        }
                    }
                    Text("按修饰键（⌘ / ⌃ / ⌥）和其他按键。如果组合键已被占用，旧快捷键会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                settingsSection("提醒", subtitle: "设置推迟提醒和每日汇总的时间") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("推迟预设").font(.subheadline.weight(.medium))
                        HStack(spacing: 10) {
                            TextField("例如 15, 30, 60", text: $presetsInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                            Text("分钟，逗号分隔")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("保存预设") {
                                let values = presetsInput.split(separator: ",", omittingEmptySubsequences: false)
                                    .map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                guard (1...5).contains(values.count),
                                      values.allSatisfy({ $0.map { (1...1440).contains($0) } == true }) else {
                                    presetError = "请输入 1–5 个 1 到 1440 的分钟数，逗号分隔"
                                    return
                                }
                                model.settings.presetsMinutes = values.compactMap { $0 }
                                model.saveSettings()
                                presetError = ""
                            }
                        }
                        if !presetError.isEmpty { Text(presetError).font(.caption).foregroundStyle(.red) }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("每日汇总").font(.subheadline.weight(.medium))
                        HStack(spacing: 8) {
                            Picker("时", selection: $model.settings.digestHour) { ForEach(0..<24) { Text("\($0) 时").tag($0) } }
                                .frame(width: 96)
                            Picker("分", selection: $model.settings.digestMinute) { ForEach(0..<60) { Text("\($0) 分").tag($0) } }
                                .frame(width: 96)
                            Spacer(minLength: 0)
                            Button("保存时间") { model.saveSettings() }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("通知权限").font(.subheadline.weight(.medium))
                            Spacer()
                            Button(model.notificationGranted ? "检查通知状态" : "打开通知设置") { model.requestPermission() }
                        }
                        Text(model.notificationGranted
                             ? "通知已开启。如果没有收到提醒，请检查系统的勿扰和横幅设置。"
                             : "如果曾拒绝通知，请在系统设置 → 通知 → MySecretary 中开启。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.965, green: 0.965, blue: 0.973))
        .onDisappear {
            if isRecordingShortcut {
                isRecordingShortcut = false
                restoreShortcut()
            }
        }
        .onAppear {
            endpoint = model.configuration.endpoint
            name = model.configuration.model
            token = model.configuration.token
            presetsInput = model.settings.presetsMinutes.map(String.init).joined(separator: ", ")
        }
        .frame(minWidth: 580, minHeight: 490)
    }

    private func settingsSection<Content: View>(_ title: String, subtitle: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14, content: content)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07)))
        }
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium))
            content()
        }
    }
}

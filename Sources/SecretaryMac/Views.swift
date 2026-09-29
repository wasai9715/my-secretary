import SwiftUI
import AppKit
import SecretaryCore

struct CaptureView: View {
    @ObservedObject var model: SecretaryModel
    let dismiss: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "text.badge.plus").foregroundStyle(.tint)
                Text("记下一件事").font(.headline)
                Spacer()
                Text("ESC 关闭").font(.caption).foregroundStyle(.secondary)
            }
            FocusedCaptureField(text: $text, submit: {
                model.add(text)
                dismiss()
            }, cancel: dismiss)
                .frame(height: 28)
        }
        .padding(18)
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

struct ManagementView: View {
    @ObservedObject var model: SecretaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.focusedNotificationIDs == nil ? "记下的事" : "这次提醒的事").font(.title2.bold())
                    Text(model.focusedNotificationIDs == nil ? "到点再想，不必一直惦记" : "先处理本次通知关联的事项")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.focusedNotificationIDs != nil {
                    Button("查看全部") { model.focusedNotificationIDs = nil }
                } else {
                    Text("\(model.items.filter { $0.status == .open }.count) 未完成")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !model.notificationGranted {
                HStack {
                    Label("通知未开启：到期事项不会弹出提醒", systemImage: "bell.slash")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("打开通知设置") { SecretaryModel.openSystemNotificationSettings() }
                }
            }
            if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
            }
            List {
                if let focused = model.focusedNotificationIDs {
                    Section("本次通知 · \(focused.count) 件") {
                        ForEach(model.items.filter { focused.contains($0.id) }) { item in
                            ItemRow(model: model, item: item)
                        }
                    }
                } else {
                Section("现在需要处理") {
                    ForEach(model.items.filter { $0.status == .open && ($0.recognition == .needsAttention || $0.nextReminder == nil || $0.nextReminder! <= .now) }) { item in
                        ItemRow(model: model, item: item)
                    }
                }
                Section("已安排稍后") {
                    ForEach(model.items.filter { $0.status == .open && $0.recognition != .needsAttention && $0.nextReminder.map { $0 > .now } == true }) { item in
                        ItemRow(model: model, item: item)
                    }
                }
                Section("历史") {
                    ForEach(model.items.filter { $0.status != .open }) { item in
                        ItemRow(model: model, item: item)
                    }
                }
                }
            }
        }.padding(16).frame(minWidth: 520, minHeight: 480)
    }
}

private struct ItemRow: View {
    @ObservedObject var model: SecretaryModel
    let item: ReminderItem
    @State private var editing = false
    @State private var newText = ""
    @State private var newDate = Date().addingTimeInterval(900)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.title).font(.headline)
                Spacer()
                if item.recognition == .needsAttention { Text("待识别").foregroundStyle(.orange) }
            }
            Text(item.text).font(.subheadline).foregroundStyle(.secondary)
            if let next = item.nextReminder { Text("下次提醒  \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption.monospacedDigit()) }
            if let deadline = item.deadline { Text("明确截止  \(deadline.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.red) }
            if let day = item.deadlineDay { Text("截止日期  \(day)（未指定几点）").font(.caption).foregroundStyle(.red) }
            if let period = item.deadlinePeriod {
                Text("截止时段  \(item.deadlinePeriodDay.map { "\($0) " } ?? "")\(period)（未指定几点）")
                    .font(.caption).foregroundStyle(.red)
            }
            if let suggestion = item.suggestedCompletion { Text("建议完成  \(suggestion.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            if let failure = item.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            if item.needsSeparateEntries == true {
                Text("该原话尚未安排提醒；请分两次录入，并取消这条原记录。")
                    .font(.caption).foregroundStyle(.orange)
                Button("复制原话") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.originalText, forType: .string) }
                    .font(.caption)
            }
            HStack(spacing: 8) {
                if item.status == .open {
                    Button("完成") { model.changeStatus(item, to: .completed) }
                    Button("不做了") { model.changeStatus(item, to: .cancelled) }
                    if item.needsSeparateEntries != true {
                        Button("15 分钟") { model.snooze(item, until: .now.addingTimeInterval(900)) }
                        Button("30 分钟") { model.snooze(item, until: .now.addingTimeInterval(1800)) }
                        Button("1 小时") { model.snooze(item, until: .now.addingTimeInterval(3600)) }
                    }
                    Button("修改") { newText = item.text; editing = true }
                    Button("测试通知") {
                        model.sendNotification(title: "测试提醒：\(item.title)", body: item.text, ids: [item.id])
                    }
                } else {
                    Button("恢复并设为 15 分钟后") {
                        var restored = item
                        restored.status = .open
                        model.snooze(restored, until: .now.addingTimeInterval(900))
                    }
                }
            }.buttonStyle(.borderless).font(.caption)
            if editing {
                TextField("事项内容", text: $newText)
                HStack {
                    Button("保存内容") { model.edit(item, text: newText); editing = false }
                    DatePicker("修改提醒", selection: $newDate, displayedComponents: [.date, .hourAndMinute])
                    Button("设定") { model.snooze(item, until: newDate); editing = false }
                }.font(.caption)
            }
        }
        .padding(.vertical, 8)
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

    var body: some View {
        Form {
            Section("智能识别 · DeepSeek") {
                SecureField("API Token", text: $token)
                DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                    TextField("API 地址", text: $endpoint)
                    TextField("模型", text: $name)
                }
                HStack {
                    Button(testing ? "正在测试…" : "测试连接并保存") {
                        testing = true
                        Task {
                            await model.testAndSave(endpoint: endpoint, model: name, token: token)
                            testing = false
                        }
                    }.disabled(testing || token.isEmpty)
                    Text(model.configuration.verified ? "连接已验证" : "连接成功后可开始录入")
                        .foregroundStyle(.secondary)
                }
            }
            Section("快捷录入") {
                HStack {
                    Text("当前快捷键")
                    Spacer()
                    Text(model.settings.shortcutDisplay ?? RecordedShortcut.label(
                        keyCode: model.settings.shortcutKey,
                        modifiers: model.settings.shortcutModifiers))
                        .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
                HStack {
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
                Text("录制时按至少一个修饰键（⌘／⌃／⌥）加其他按键；若系统或其他应用占用，旧快捷键会保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("提醒") {
                HStack {
                    Text("每日汇总")
                    Picker("时", selection: $model.settings.digestHour) { ForEach(0..<24) { Text("\($0) 时").tag($0) } }.frame(width: 95)
                    Picker("分", selection: $model.settings.digestMinute) { ForEach(0..<60) { Text("\($0) 分").tag($0) } }.frame(width: 95)
                    Button("保存") { model.saveSettings() }
                }
                Button(model.notificationGranted ? "检查通知状态" : "开启通知（前往系统设置）") { model.requestPermission() }
                Text("如果曾拒绝通知，macOS 不会再次弹出授权框；请在系统设置 → 通知 → MySecretary 中开启。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
        }
        .onDisappear {
            if isRecordingShortcut {
                isRecordingShortcut = false
                restoreShortcut()
            }
        }
        .padding(24)
        .onAppear {
            endpoint = model.configuration.endpoint
            name = model.configuration.model
            token = model.configuration.token
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

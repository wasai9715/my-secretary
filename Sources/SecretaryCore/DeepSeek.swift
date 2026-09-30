import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One saved item has one reminder; two independent actions require two user entries.
public enum InterpretationDecision: Sendable, Equatable {
    case schedule(Interpretation)
    case separateEntries(String)
    case needsConfirmation(String)
}

public struct DeepSeekClient: Sendable {
    public let configuration: AIConfiguration
    public init(configuration: AIConfiguration) { self.configuration = configuration }

    public func testConnection() async throws {
        let response = try await chat(system: "请仅返回 JSON 对象。", user: "返回 {\"ok\":true}。")
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool, ok else {
            throw RecognitionError.invalid("模型连接测试未返回预期结果")
        }
    }

    public static func timeContext(now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return "\(formatter.string(from: now))，时区 \(timeZone.identifier)"
    }

    public static func systemPrompt(now: Date = .now) throws -> String {
        guard let url = Bundle.main.url(forResource: "interpretation-prompt", withExtension: "txt")
                ?? Bundle.module.url(forResource: "interpretation-prompt", withExtension: "txt") else {
            throw RecognitionError.invalid("事项理解规则不可用")
        }
        return try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "{current_local_datetime}", with: timeContext(now: now))
            .replacingOccurrences(of: "{timezone}", with: TimeZone.current.identifier)
    }

    public func interpret(_ text: String, now: Date = .now) async throws -> InterpretationDecision {
        let prompt = try Self.systemPrompt(now: now)
        let first = try await chat(system: prompt, user: "原话：\(text)")
        do { return try Self.decodeInterpretation(first, originalText: text, now: now) }
        catch {
            // Only invalid model output is reparsed. Semantic split/uncertainty is
            // a valid decision; network/auth/timeouts must not trigger a correction.
            let retry = "原话：\(text)\n上次结果：\(first)\n程序校验失败：\(error.localizedDescription)\n请重新输出完整合法 JSON 对象。"
            let second = try await chat(system: prompt, user: retry)
            return try Self.decodeInterpretation(second, originalText: text, now: now)
        }
    }

    public static func decodeInterpretation(_ json: String, originalText: String, now: Date) throws -> InterpretationDecision {
        // Required keys must be present even when the corresponding value is null.
        guard let bytes = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let actions = object["actions"] as? [[String: Any]],
              object["title"] is String,
              object["requiresConfirmation"] is Bool,
              object.keys.contains("confirmationReason") else {
            throw RecognitionError.invalid("模型返回的事项结构不完整")
        }
        for raw in actions {
            let needed = ["action", "actionEvidence", "scheduledDay", "reminderAt", "reminderSource",
                          "reminderEvidence", "deadline", "uncertainty"]
            guard needed.allSatisfy(raw.keys.contains), let deadline = raw["deadline"] as? [String: Any],
                  ["kind", "day", "period", "at", "basis", "evidence"].allSatisfy(deadline.keys.contains) else {
                throw RecognitionError.invalid("模型返回的行动字段不完整")
            }
        }
        let response: ModelResponse
        do { response = try JSONDecoder().decode(ModelResponse.self, from: bytes) }
        catch { throw RecognitionError.invalid("模型字段类型或枚举值无效") }
        guard !response.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecognitionError.invalid("模型未返回短标题")
        }
        guard !response.actions.isEmpty else { throw RecognitionError.invalid("模型未识别有效行动") }
        for action in response.actions {
            guard !action.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecognitionError.invalid("模型返回空行动")
            }
            try assertEvidence(action.actionEvidence, in: originalText)
            try assertEvidence(action.reminderEvidence, in: originalText)
            try assertEvidence(action.deadline.evidence, in: originalText)
        }
        if response.actions.count > 1 {
            let descriptions = response.actions.prefix(2).map(\.action).joined(separator: "、")
            return .separateEntries("识别到多个分别需要提醒的行动（\(descriptions)）。原话已保存，请分两次录入。")
        }
        if response.requiresConfirmation && response.actions.contains(where: { $0.reminderAt != nil }) {
            throw RecognitionError.invalid("待确认状态不得同时声称已安排具体提醒")
        }
        let action = response.actions[0]
        if response.requiresConfirmation || action.reminderSource == .uncertain {
            guard action.reminderAt == nil else { throw RecognitionError.invalid("待确认的行动不能安排具体提醒") }
            return .needsConfirmation(response.confirmationReason ?? action.uncertainty ?? "时间未明确，请手动设置提醒")
        }
        if let reason = response.confirmationReason, !reason.isEmpty {
            throw RecognitionError.invalid("模型既称不需确认又提出确认原因")
        }
        let parsed = try buildInterpretation(response.title, action: action, originalText: originalText, now: now)
        return .schedule(parsed)
    }

    private static func buildInterpretation(_ title: String, action: ModelAction, originalText: String, now: Date) throws -> Interpretation {
        let reminder = try date(action.reminderAt)
        let cutoff = try date(action.deadline.at)
        let deadline = action.deadline
        if let period = deadline.period { try assertEvidence(period, in: originalText) }
        if let day = action.scheduledDay { try validateDay(day) }
        if let day = deadline.day { try validateDay(day) }
        switch deadline.kind {
        case .none:
            guard cutoff == nil, deadline.day == nil, deadline.period == nil,
                  deadline.basis == .none, deadline.evidence == nil else {
                throw RecognitionError.invalid("无截止却返回了截止字段")
            }
        case .day:
            guard deadline.day != nil, cutoff == nil, deadline.period == nil,
                  deadline.basis != .none, deadline.evidence != nil else {
                throw RecognitionError.invalid("仅日期截止的结构无效")
            }
        case .period:
            guard let period = deadline.period, !period.isEmpty, cutoff == nil,
                  deadline.basis != .none, deadline.evidence != nil else {
                throw RecognitionError.invalid("时间段截止的结构无效")
            }
        case .instant:
            guard cutoff != nil, deadline.period == nil,
                  deadline.basis != .none, deadline.evidence != nil else {
                throw RecognitionError.invalid("精确截止的结构无效")
            }
        }
        let today = now
        if let reminder, reminder < today {
            throw RecognitionError.invalid("提醒时间早于录入时间")
        }
        if let cutoff, cutoff <= now { throw RecognitionError.invalid("精确截止时刻已经过去") }
        if let reminder, let cutoff, reminder >= cutoff {
            throw RecognitionError.invalid("首次提醒必须严格早于精确截止")
        }
        if let day = deadline.day, let end = ReminderItem.endOfLocalDay(day), now >= end {
            throw RecognitionError.invalid("截止日期已过")
        }
        if let day = deadline.day, let reminder,
           let end = ReminderItem.endOfLocalDay(day), reminder >= end,
           action.reminderSource != .explicit {
            throw RecognitionError.invalid("建议提醒晚于截止日期")
        }
        if action.reminderSource == .default15min {
            guard reminder == nil, action.scheduledDay == nil, deadline.kind == .none,
                  action.reminderEvidence == nil else {
                throw RecognitionError.invalid("有时间线索却使用无时间默认提醒")
            }
        } else {
            guard reminder != nil else { throw RecognitionError.invalid("有时间线索却没有首次提醒") }
        }
        if action.reminderSource == .explicit {
            guard action.reminderEvidence != nil else { throw RecognitionError.invalid("明确提醒没有原话依据") }
        }
        return Interpretation(title: title, reminder: reminder, deadline: cutoff,
                              deadlineDay: deadline.kind == .day ? deadline.day : nil,
                              deadlinePeriod: deadline.kind == .period ? deadline.period : nil,
                              deadlinePeriodDay: deadline.kind == .period ? deadline.day : nil,
                              scheduledDay: action.scheduledDay,
                              reminderSource: action.reminderSource.rawValue,
                              timeEvidence: [action.actionEvidence, action.reminderEvidence, deadline.evidence].compactMap { $0 },
                              suggestedCompletion: nil)
    }

    private static func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        // ISO8601 offsets, including Z, are required: never use the machine's
        // current time zone to invent an offset for a model-generated clock.
        guard value.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw RecognitionError.invalid("模型时间缺少时区偏移量")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        guard let parsed = formatter.date(from: value) else { throw RecognitionError.invalid("日期时间格式无效") }
        return parsed
    }

    private static func validateDay(_ value: String) throws {
        guard ReminderItem.endOfLocalDay(value) != nil else { throw RecognitionError.invalid("日期格式或日历日期无效") }
    }

    private static func assertEvidence(_ quote: String?, in text: String) throws {
        guard let quote else { return }
        guard !quote.isEmpty, text.contains(quote) else {
            throw RecognitionError.invalid("时间或行动依据不是原话中的连续片段")
        }
    }

    private func chat(system: String, user: String) async throws -> String {
        guard let url = URL(string: configuration.endpoint), url.scheme == "https", !configuration.token.isEmpty else {
            throw RecognitionError.connection("模型地址须为 HTTPS 且 Token 不能为空")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Message: Encodable { let role: String; let content: String }
        struct Body: Encodable { let model: String; let messages: [Message]; let response_format: [String: String]; let stream: Bool }
        request.httpBody = try JSONEncoder().encode(Body(model: configuration.model, messages: [.init(role: "system", content: system), .init(role: "user", content: user)], response_format: ["type": "json_object"], stream: false))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = response as? HTTPURLResponse, (200..<300).contains(status.statusCode) else {
            throw RecognitionError.connection("模型请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），请检查 Token、模型与网络")
        }
        struct Envelope: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(Envelope.self, from: data).choices.first?.message.content else {
            throw RecognitionError.invalid("模型没有返回内容")
        }
        return content
    }
}

private struct ModelResponse: Decodable {
    let title: String
    let actions: [ModelAction]
    let requiresConfirmation: Bool
    let confirmationReason: String?
}

private struct ModelAction: Decodable {
    let action: String
    let actionEvidence: String
    let scheduledDay: String?
    let reminderAt: String?
    let reminderSource: ReminderOrigin
    let reminderEvidence: String?
    let deadline: ModelDeadline
    let uncertainty: String?
}

private enum ReminderOrigin: String, Decodable {
    case explicit, inferred, uncertain
    case default15min = "default_15min"
}

private struct ModelDeadline: Decodable {
    enum Kind: String, Decodable { case none, day, period, instant }
    enum Basis: String, Decodable { case explicit, context_inferred, none }
    let kind: Kind
    let day: String?
    let period: String?
    let at: String?
    let basis: Basis
    let evidence: String?
}

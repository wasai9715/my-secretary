import Foundation
import SecretaryCore

// Explicit opt-in: three live DeepSeek requests with fictional current-item content.
@main struct SecretaryCommandSmoke {
    static func main() async {
        do {
            let config = try LocalFiles().loadConfiguration()
            guard config.verified else { throw RecognitionError.invalid("请先测试模型连接") }
            let client = DeepSeekClient(configuration: config)
            var item = ReminderItem(text: "查订单接口")
            try item.apply(.init(title: "查订单接口", reminder: Date().addingTimeInterval(3600),
                                 deadline: Date().addingTimeInterval(7200), suggestedCompletion: nil))
            guard case .update(let edit) = try await client.interpretTimeEdit(
                "明天上午九点提醒我，截止改为明天下午六点", item: item),
                edit.reminder != nil, edit.deadline != nil else {
                throw RecognitionError.invalid("提醒与明确截止未完整识别")
            }
            print("✓ 两种时间均完整识别")
            guard case .choosePreset = try await client.interpretTimeEdit("晚点再提醒", item: item) else {
                throw RecognitionError.invalid("含糊提醒未提示预设")
            }
            print("✓ 晚点要求选预设，没有静默排期")
            do {
                let mixed = try await client.interpretTimeEdit(
                    "今天下午五点再提醒我，案例批次号为 ABC123", item: item)
                guard case .unclear = mixed else {
                    throw RecognitionError.invalid("夹带内容修改却只安排了时间")
                }
            } catch RecognitionError.invalid(let message) where message.contains("内容框") {
                // The decoder must reject unsupported content even if the model supplied a time.
            }
            print("✓ 夹带批次号不静默只改时间")
        } catch {
            fputs("当前事项真实时间模型冒烟失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

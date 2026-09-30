import Foundation
import SecretaryCore

// Synthetic sentences only. Run explicitly; performs a valid and an invalid
// connection test plus five interpretations (and possible corrective calls).
@main
struct SecretaryAISmoke {
    static func main() async {
        do {
            let files = try LocalFiles()
            let config = try files.loadConfiguration()
            guard config.verified else { throw RecognitionError.invalid("请先测试模型连接") }
            let client = DeepSeekClient(configuration: config)
            try await client.testConnection()
            print("✓ 已保存凭据连接测试通过")
            var invalid = config
            invalid.token = "invalid-secretary-smoke-token"
            do {
                try await DeepSeekClient(configuration: invalid).testConnection()
                throw RecognitionError.invalid("无效凭据意外通过连接测试")
            } catch RecognitionError.connection(let reason) where reason.contains("HTTP 401") {
                print("✓ 无效凭据被服务端拒绝")
            }
            guard try files.loadConfiguration().token == config.token else {
                throw RecognitionError.invalid("负向测试修改了已保存凭据")
            }
            let samples = [
                ("明天提醒我写周报", "single"),
                ("后天给阿姨买东西", "single"),
                ("明天下午三点前把测试报告交给同事", "deadline"),
                ("帮同事查一下订单接口", "no-time"),
                ("周五上线功能，下周一检查结果", "separate"),
            ]
            for (text, expectation) in samples {
                let decision = try await client.interpret(text)
                switch (expectation, decision) {
                case ("single", .schedule(let result)):
                    guard result.reminder != nil else { throw RecognitionError.invalid("单行动未安排提醒") }
                    print("✓ 单行动已安排（不输出原话或结果时间）")
                case ("deadline", .schedule(let result)) where result.deadline != nil && result.reminder != nil && result.reminder! < result.deadline!:
                    print("✓ 明确截止与提前提醒正确分开")
                case ("no-time", .schedule(let result)) where result.reminderSource == "default_15min" && result.reminder == nil:
                    print("✓ 无时间事项采用15分钟默认规则")
                case ("separate", .separateEntries):
                    print("✓ 两个独立行动被标记为需分录")
                default:
                    throw RecognitionError.invalid("模型输出与单事项策略不符：\(expectation)")
                }
            }
            print("AI 冒烟检查通过")
        } catch {
            fputs("AI 冒烟检查失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

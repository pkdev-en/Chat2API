// --- ios/Chat2API_iOS/Models.swift ---
import Foundation

enum AuthType: String, Codable, CaseIterable {
    case userToken    = "userToken"
    case jwtToken     = "jwtToken"
    case cookie       = "cookie"
    case ssoTicket    = "ssoTicket"
    case refreshToken = "refreshToken"
}

struct Provider: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    var chatPath: String
    var authType: AuthType
    var token: String
    var models: [String]
    var enabled: Bool

    func authHeader() -> (String, String) {
        switch authType {
        case .userToken, .jwtToken, .refreshToken:
            return ("Authorization", "Bearer \(token)")
        case .cookie:
            return ("Cookie", token)
        case .ssoTicket:
            return ("Cookie", "sso-ticket=\(token)")
        }
    }
}

extension Provider {
    static func defaults() -> [Provider] {
        [
            Provider(
                name: "Qwen (CN)",
                baseURL: "https://qianwen.aliyun.com",
                chatPath: "/api/chat/completions",
                authType: .ssoTicket,
                token: "",
                models: ["qwen3-max", "qwen3-coder", "qwen3-max-thinking-preview"],
                enabled: false
            ),
            Provider(
                name: "DeepSeek",
                baseURL: "https://chat.deepseek.com",
                chatPath: "/api/v0/chat/completions",
                authType: .userToken,
                token: "",
                models: ["deepseek-v4-flash", "deepseek-v4-pro"],
                enabled: false
            ),
            Provider(
                name: "Kimi",
                baseURL: "https://kimi.moonshot.cn",
                chatPath: "/api/chat/completions",
                authType: .jwtToken,
                token: "",
                models: ["kimi-k2.6"],
                enabled: false
            ),
            Provider(
                name: "MiniMax",
                baseURL: "https://hailuoai.com",
                chatPath: "/api/chat/completions",
                authType: .jwtToken,
                token: "",
                models: ["minimax-m2.7"],
                enabled: false
            ),
        ]
    }
}

struct ProxyConfig: Codable {
    var port: Int = 8080
    var apiKey: String = ""
    var requireAuth: Bool = false
}

struct RequestLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let path: String
    let statusCode: Int
    let provider: String
    let durationMs: Int
}

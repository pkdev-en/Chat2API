// --- ios/Chat2API_iOS/ProviderManager.swift ---
import Foundation

class ProviderManager: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var config: ProxyConfig = ProxyConfig()

    private let providersKey = "chat2api.providers"
    private let configKey    = "chat2api.config"
    var roundRobinIndex: Int = 0

    init() {
        load()
        if providers.isEmpty {
            providers = Provider.defaults()
            save()
        }
    }

    func save() {
        if let d = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(d, forKey: providersKey)
        }
        if let d = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(d, forKey: configKey)
        }
    }

    func load() {
        if let d = UserDefaults.standard.data(forKey: providersKey),
           let v = try? JSONDecoder().decode([Provider].self, from: d) {
            providers = v
        }
        if let d = UserDefaults.standard.data(forKey: configKey),
           let v = try? JSONDecoder().decode(ProxyConfig.self, from: d) {
            config = v
        }
    }

    func enabledProviders() -> [Provider] {
        providers.filter { $0.enabled && !$0.token.isEmpty }
    }

    func providerForModel(_ model: String) -> Provider? {
        let ml = model.lowercased()
        return enabledProviders().first { p in
            p.models.contains(where: { $0.lowercased() == ml })
        } ?? enabledProviders().first
    }

    func nextProvider() -> Provider? {
        let active = enabledProviders()
        guard !active.isEmpty else { return nil }
        let p = active[roundRobinIndex % active.count]
        roundRobinIndex += 1
        return p
    }
}

extension Provider {
    static func defaults() -> [Provider] {
        [
            Provider(
                name: "DeepSeek",
                baseURL: "https://chat.deepseek.com",
                chatPath: "/api/v0/chat/completion",
                authType: .userToken,
                token: "",
                models: [
                    "deepseek-v4-flash",
                    "deepseek-v4-pro",
                    "deepseek-r1",
                    "deepseek-r1-search",
                ],
                enabled: false
            ),
            Provider(
                name: "Kimi",
                baseURL: "https://www.kimi.com",
                chatPath: "/apiv2/kimi.gateway.chat.v1.ChatService/Chat",
                authType: .jwtToken,
                token: "",
                models: [
                    "Kimi-K2.6",
                    "kimi-k2.6",
                    "kimi-k2.6-think",
                    "kimi-k2.6-search",
                ],
                enabled: false
            ),
        ]
    }
}

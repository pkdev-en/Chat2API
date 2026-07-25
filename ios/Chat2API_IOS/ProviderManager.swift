// --- ios/Chat2API_iOS/ProviderManager.swift ---
import Foundation

class ProviderManager: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var config: ProxyConfig = ProxyConfig()

    private let providersKey = "chat2api.providers"
    private let configKey    = "chat2api.config"

    init() {
        load()
        if providers.isEmpty {
            providers = Provider.defaults()
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: providersKey)
        }
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: providersKey),
           let decoded = try? JSONDecoder().decode([Provider].self, from: data) {
            providers = decoded
        }
        if let data = UserDefaults.standard.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode(ProxyConfig.self, from: data) {
            config = decoded
        }
    }

    func enabledProviders() -> [Provider] {
        providers.filter { $0.enabled && !$0.token.isEmpty }
    }

    func providerForModel(_ model: String) -> Provider? {
        enabledProviders().first { $0.models.contains(model) }
            ?? enabledProviders().first
    }

    var roundRobinIndex: Int = 0

    func nextProvider() -> Provider? {
        let active = enabledProviders()
        guard !active.isEmpty else { return nil }
        let p = active[roundRobinIndex % active.count]
        roundRobinIndex += 1
        return p
    }
}

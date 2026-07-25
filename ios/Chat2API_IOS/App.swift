// --- ios/Chat2API_iOS/App.swift ---
import SwiftUI

@main
struct Chat2APIApp: App {
    @StateObject private var proxy = ProxyServer()
    @StateObject private var pm    = ProviderManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(proxy)
                .environmentObject(pm)
                .onAppear {
                    proxy.providerManager = pm
                    proxy.start()
                }
        }
    }
}

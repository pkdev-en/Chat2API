// --- ios/Chat2API_iOS/ContentView.swift ---
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var proxy: ProxyServer
    @EnvironmentObject var pm: ProviderManager

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar") }

            ProvidersView()
                .tabItem { Label("Providers", systemImage: "server.rack") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var proxy: ProxyServer
    @EnvironmentObject var pm: ProviderManager

    var body: some View {
        NavigationView {
            List {
                Section("Proxy") {
                    HStack {
                        Circle()
                            .fill(proxy.isRunning ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(proxy.isRunning ? "Running" : "Stopped")
                        Spacer()
                        Text(":\(pm.config.port)")
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }

                    if proxy.isRunning {
                        Text("http://localhost:\(pm.config.port)/v1")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Button(proxy.isRunning ? "Stop Proxy" : "Start Proxy") {
                        proxy.isRunning ? proxy.stop() : proxy.start()
                    }
                    .foregroundStyle(proxy.isRunning ? .red : .accentColor)
                }

                Section("Stats") {
                    LabeledContent("Requests", value: "\(proxy.requestCount)")
                    LabeledContent("Errors",   value: "\(proxy.errorCount)")
                    LabeledContent("Active providers",
                                   value: "\(pm.enabledProviders().count)")
                }

                if !proxy.logs.isEmpty {
                    Section("Recent") {
                        ForEach(proxy.logs.prefix(20)) { log in
                            HStack {
                                Text(log.provider)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(log.statusCode)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(log.statusCode == 200 ? .green : .red)
                                Text("\(log.durationMs)ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chat2API")
        }
    }
}

// MARK: - Providers

struct ProvidersView: View {
    @EnvironmentObject var pm: ProviderManager
    @State private var editingIndex: Int? = nil
    @State private var showAdd = false

    var body: some View {
        NavigationView {
            List {
                ForEach(pm.providers.indices, id: \.self) { i in
                    ProviderRow(provider: $pm.providers[i])
                        .onChange(of: pm.providers[i].token)   { _ in pm.save() }
                        .onChange(of: pm.providers[i].enabled) { _ in pm.save() }
                }
                .onDelete { pm.providers.remove(atOffsets: $0); pm.save() }
            }
            .navigationTitle("Providers")
            .toolbar {
                EditButton()
            }
        }
    }
}

struct ProviderRow: View {
    @Binding var provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.name).font(.headline)
                Spacer()
                Toggle("", isOn: $provider.enabled)
                    .labelsHidden()
            }

            TextField("Token / Cookie", text: $provider.token)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Text(provider.models.joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var pm: ProviderManager
    @EnvironmentObject var proxy: ProxyServer

    var body: some View {
        NavigationView {
            Form {
                Section("Proxy") {
                    Stepper("Port: \(pm.config.port)",
                            value: $pm.config.port, in: 1024...65535, step: 1)
                    .onChange(of: pm.config.port) { _ in pm.save() }
                }

                Section("Auth") {
                    Toggle("Require API Key", isOn: $pm.config.requireAuth)
                        .onChange(of: pm.config.requireAuth) { _ in pm.save() }

                    if pm.config.requireAuth {
                        TextField("API Key", text: $pm.config.apiKey)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: pm.config.apiKey) { _ in pm.save() }
                    }
                }

                Section("Endpoint") {
                    Text("POST /v1/chat/completions")
                        .font(.system(.caption, design: .monospaced))
                    Text("GET  /v1/models")
                        .font(.system(.caption, design: .monospaced))
                    Text("GET  /health")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .navigationTitle("Settings")
        }
    }
}

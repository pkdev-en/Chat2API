// --- ios/Chat2API_iOS/ProxyServer.swift ---
import Foundation
import Network

class ProxyServer: ObservableObject {
    @Published var isRunning = false
    @Published var logs: [RequestLog] = []
    @Published var requestCount = 0
    @Published var errorCount = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "chat2api.proxy", qos: .userInitiated)
    var providerManager: ProviderManager?

    func start() {
        let port = UInt16(providerManager?.config.port ?? 8080)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            print("[ProxyServer] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed, .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.isRunning = false }
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHTTP(conn: conn)
    }

    private func receiveHTTP(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) {
            [weak self] data, _, isComplete, error in

            guard let self = self, let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }

            guard let raw = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }

            self.handleHTTPRequest(raw: raw, conn: conn)
        }
    }

    private func handleHTTPRequest(raw: String, conn: NWConnection) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(conn: conn, status: 400, message: "Bad Request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(conn: conn, status: 400, message: "Bad Request")
            return
        }

        let method = parts[0]
        let path   = parts[1]

        // Auth check
        if providerManager?.config.requireAuth == true {
            let expectedKey = providerManager?.config.apiKey ?? ""
            let authLine = lines.first(where: { $0.lowercased().hasPrefix("authorization:") })
            let token = authLine?
                .dropFirst("authorization:".count)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "Bearer ", with: "") ?? ""
            if !expectedKey.isEmpty && token != expectedKey {
                sendError(conn: conn, status: 401, message: "Unauthorized")
                return
            }
        }

        // Route
        if method == "GET" && path == "/v1/models" {
            handleModels(conn: conn)
        } else if method == "POST" && path == "/v1/chat/completions" {
            let bodyStart = raw.range(of: "\r\n\r\n")
            let body = bodyStart.map { String(raw[$0.upperBound...]) } ?? ""
            handleChat(body: body, conn: conn)
        } else if method == "GET" && path == "/health" {
            sendJSON(conn: conn, status: 200, body: #"{"status":"ok"}"#)
        } else {
            sendError(conn: conn, status: 404, message: "Not Found")
        }
    }

    private func handleModels(conn: NWConnection) {
        let providers = providerManager?.enabledProviders() ?? []
        let models = providers.flatMap { $0.models }.map { name -> String in
            #"{"id":"\#(name)","object":"model","owned_by":"chat2api"}"#
        }.joined(separator: ",")

        let body = #"{"object":"list","data":[\#(models)]}"#
        sendJSON(conn: conn, status: 200, body: body)
    }

    private func handleChat(body: String, conn: NWConnection) {
        guard let bodyData = body.data(using: .utf8),
              let req = try? JSONDecoder().decode(ChatRequest.self, from: bodyData)
        else {
            sendError(conn: conn, status: 400, message: "Invalid request body")
            return
        }

        guard let provider = providerManager?.providerForModel(req.model) else {
            sendError(conn: conn, status: 503, message: "No enabled provider for model \(req.model)")
            return
        }

        let isStream = req.stream ?? false
        let start    = Date()

        guard let url = URL(string: provider.baseURL + provider.chatPath) else {
            sendError(conn: conn, status: 500, message: "Invalid provider URL")
            return
        }

        var upstream = URLRequest(url: url, timeoutInterval: 120)
        upstream.httpMethod = "POST"
        upstream.httpBody   = bodyData
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (headerName, headerValue) = provider.authHeader()
        upstream.setValue(headerValue, forHTTPHeaderField: headerName)
        upstream.setValue("application/json", forHTTPHeaderField: "Accept")

        if isStream {
            upstream.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        if isStream {
            forwardStream(upstream: upstream, provider: provider,
                          start: start, conn: conn)
        } else {
            forwardSync(upstream: upstream, provider: provider,
                        start: start, conn: conn)
        }
    }

    private func forwardSync(upstream: URLRequest, provider: Provider,
                              start: Date, conn: NWConnection) {
        let task = URLSession.shared.dataTask(with: upstream) {
            [weak self] data, response, error in

            let ms = Int(Date().timeIntervalSince(start) * 1000)

            if let error = error {
                self?.sendError(conn: conn, status: 502, message: error.localizedDescription)
                self?.logRequest(path: "/v1/chat/completions", status: 502,
                                 provider: provider.name, ms: ms)
                DispatchQueue.main.async { self?.errorCount += 1 }
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            self?.sendJSON(conn: conn, status: statusCode, body: body)
            self?.logRequest(path: "/v1/chat/completions", status: statusCode,
                             provider: provider.name, ms: ms)
            DispatchQueue.main.async { self?.requestCount += 1 }
        }
        task.resume()
    }

    private func forwardStream(upstream: URLRequest, provider: Provider,
                                start: Date, conn: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: text/event-stream\r\n" +
                     "Cache-Control: no-cache\r\n" +
                     "Transfer-Encoding: chunked\r\n" +
                     "Connection: keep-alive\r\n\r\n"

        conn.send(content: header.data(using: .utf8)!, completion: .idempotent)

        let forwarder = StreamForwarder(
            onData: { data in
                let chunk = String(format: "%X\r\n", data.count)
                var packet = Data()
                packet.append(chunk.data(using: .utf8)!)
                packet.append(data)
                packet.append("\r\n".data(using: .utf8)!)
                conn.send(content: packet, completion: .idempotent)
            },
            onComplete: { [weak self] _ in
                let terminator = "0\r\n\r\n".data(using: .utf8)!
                conn.send(content: terminator, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                self?.logRequest(path: "/v1/chat/completions", status: 200,
                                 provider: provider.name, ms: ms)
                DispatchQueue.main.async { self?.requestCount += 1 }
            }
        )
        forwarder.forward(request: upstream)
    }

    // MARK: - HTTP helpers

    private func sendJSON(conn: NWConnection, status: Int, body: String) {
        let statusText = HTTPURLResponse.localizedString(forStatusCode: status)
        let response = "HTTP/1.1 \(status) \(statusText)\r\n" +
                       "Content-Type: application/json\r\n" +
                       "Content-Length: \(body.utf8.count)\r\n" +
                       "Connection: close\r\n\r\n" +
                       body
        conn.send(content: response.data(using: .utf8)!,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendError(conn: NWConnection, status: Int, message: String) {
        let body = #"{"error":{"message":"\#(message)","type":"proxy_error","code":\#(status)}}"#
        sendJSON(conn: conn, status: status, body: body)
    }

    private func logRequest(path: String, status: Int, provider: String, ms: Int) {
        let entry = RequestLog(timestamp: Date(), method: "POST",
                               path: path, statusCode: status,
                               provider: provider, durationMs: ms)
        DispatchQueue.main.async {
            self.logs.insert(entry, at: 0)
            if self.logs.count > 200 { self.logs.removeLast() }
        }
    }
}

// minimal decode — chỉ cần model + stream flag
private struct ChatRequest: Decodable {
    let model: String
    var stream: Bool?
}

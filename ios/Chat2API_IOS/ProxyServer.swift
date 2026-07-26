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
            print("[ProxyServer] Listener error: \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.isRunning = state == .ready }
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
        receive(conn: conn)
    }

    private func receive(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 131072) {
            [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            guard let raw = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            self.handleHTTP(raw: raw, conn: conn)
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String
    }

    private func parseHTTP(_ raw: String) -> HTTPRequest? {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerSection = parts[0]
        let body = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : ""
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let reqParts = requestLine.components(separatedBy: " ")
        guard reqParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.components(separatedBy: ": ")
            if kv.count >= 2 { headers[kv[0].lowercased()] = kv[1...].joined(separator: ": ") }
        }
        return HTTPRequest(method: reqParts[0], path: reqParts[1], headers: headers, body: body)
    }

    private func handleHTTP(raw: String, conn: NWConnection) {
        guard let req = parseHTTP(raw) else {
            sendError(conn: conn, status: 400, message: "Bad Request"); return
        }
        if providerManager?.config.requireAuth == true {
            let expected = providerManager?.config.apiKey ?? ""
            let auth = req.headers["authorization"] ?? ""
            let token = auth.replacingOccurrences(of: "Bearer ", with: "")
            if !expected.isEmpty && token != expected {
                sendError(conn: conn, status: 401, message: "Unauthorized"); return
            }
        }
        switch (req.method, req.path) {
        case ("GET", "/v1/models"):    handleModels(conn: conn)
        case ("POST", "/v1/chat/completions"): handleChat(body: req.body, conn: conn)
        case ("GET", "/health"):       sendJSON(conn: conn, status: 200, body: #"{"status":"ok"}"#)
        default:                       sendError(conn: conn, status: 404, message: "Not Found")
        }
    }

    private func handleModels(conn: NWConnection) {
        let all = [
            "deepseek-v4-flash", "deepseek-v4-pro",
            "deepseek-r1", "deepseek-r1-search",
            "Kimi-K2.6", "kimi-k2.6",
            "kimi-k2.6-think", "kimi-k2.6-search",
        ]
        let items = all.map { #"{"id":"\#($0)","object":"model","owned_by":"chat2api"}"# }
            .joined(separator: ",")
        sendJSON(conn: conn, status: 200, body: #"{"object":"list","data":[\#(items)]}"#)
    }

    private func handleChat(body: String, conn: NWConnection) {
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let model = json["model"] as? String,
              let messagesRaw = json["messages"] as? [[String: Any]]
        else {
            sendError(conn: conn, status: 400, message: "Invalid request body"); return
        }

        let stream = json["stream"] as? Bool ?? false
        let chatRequest = ChatRequest(model: model, messages: messagesRaw, stream: stream)
        let start = Date()
        let modelLower = model.lowercased()

        if modelLower.contains("deepseek") {
            guard let provider = providerManager?.enabledProviders()
                .first(where: { $0.name.lowercased().contains("deepseek") }),
                  !provider.token.isEmpty
            else {
                sendError(conn: conn, status: 503, message: "No enabled DeepSeek provider"); return
            }
            routeDeepSeek(chatRequest: chatRequest, token: provider.token, start: start, conn: conn)

        } else if modelLower.contains("kimi") || modelLower.contains("k2.5") || modelLower.contains("k2.6") {
            guard let provider = providerManager?.enabledProviders()
                .first(where: { $0.name.lowercased().contains("kimi") }),
                  !provider.token.isEmpty
            else {
                sendError(conn: conn, status: 503, message: "No enabled Kimi provider"); return
            }
            routeKimi(chatRequest: chatRequest, token: provider.token, start: start, conn: conn)

        } else {
            sendError(conn: conn, status: 400,
                      message: "Unknown model: \(model). Supported: deepseek-*, kimi-*, Kimi-K2.*")
        }
    }

    private func routeDeepSeek(chatRequest: ChatRequest, token: String,
                                start: Date, conn: NWConnection) {
        Task {
            do {
                let adapter = DeepSeekAdapter(token: token)
                let (upstreamReq, sessionId) = try await adapter.chatCompletion(request: chatRequest)
                if chatRequest.stream {
                    try await streamSSE(
                        upstream: upstreamReq,
                        parser: DeepSeekStreamParser(
                            model: chatRequest.model,
                            sessionId: sessionId,
                            webSearchEnabled: chatRequest.model.lowercased().contains("search")
                        ),
                        conn: conn, start: start, provider: "DeepSeek"
                    )
                } else {
                    try await syncResponse(upstream: upstreamReq, conn: conn, start: start, provider: "DeepSeek")
                }
            } catch {
                self.sendError(conn: conn, status: 502, message: error.localizedDescription)
                DispatchQueue.main.async { self.errorCount += 1 }
            }
        }
    }

    private func routeKimi(chatRequest: ChatRequest, token: String,
                            start: Date, conn: NWConnection) {
        Task {
            do {
                let adapter = KimiAdapter(token: token)
                let upstreamReq = try await adapter.chatCompletion(request: chatRequest)
                if chatRequest.stream {
                    try await streamGRPC(
                        upstream: upstreamReq,
                        parser: KimiStreamParser(model: chatRequest.model),
                        conn: conn, start: start
                    )
                } else {
                    try await syncResponse(upstream: upstreamReq, conn: conn, start: start, provider: "Kimi")
                }
            } catch {
                self.sendError(conn: conn, status: 502, message: error.localizedDescription)
                DispatchQueue.main.async { self.errorCount += 1 }
            }
        }
    }

    private func streamSSE(upstream: URLRequest,
                            parser: DeepSeekStreamParser,
                            conn: NWConnection,
                            start: Date,
                            provider: String) async throws {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n"
        sendRaw(conn: conn, data: header.data(using: .utf8)!)

        let (stream, _) = try await URLSession.shared.bytes(for: upstream)
        var lineBuffer = ""

        for try await byte in stream {
            guard let char = String(bytes: [byte], encoding: .utf8) else { continue }
            lineBuffer += char
            if lineBuffer.hasSuffix("\n") {
                let chunks = parser.feed(lineBuffer.data(using: .utf8)!)
                for chunk in chunks { sendChunked(conn: conn, data: chunk.data(using: .utf8)!) }
                if lineBuffer.contains("[DONE]") { break }
                lineBuffer = ""
            }
        }

        sendRaw(conn: conn, data: "0\r\n\r\n".data(using: .utf8)!)
        conn.cancel()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        logRequest(path: "/v1/chat/completions", status: 200, provider: provider, ms: ms)
        DispatchQueue.main.async { self.requestCount += 1 }
    }

    private func streamGRPC(upstream: URLRequest,
                             parser: KimiStreamParser,
                             conn: NWConnection,
                             start: Date) async throws {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n"
        sendRaw(conn: conn, data: header.data(using: .utf8)!)

        let (stream, _) = try await URLSession.shared.bytes(for: upstream)
        var byteBuffer = Data()

        for try await byte in stream {
            byteBuffer.append(byte)
            if byteBuffer.count >= 5 {
                let chunks = parser.feed(byteBuffer)
                byteBuffer = Data()
                for chunk in chunks {
                    sendChunked(conn: conn, data: chunk.data(using: .utf8)!)
                    if chunk.contains("[DONE]") {
                        sendRaw(conn: conn, data: "0\r\n\r\n".data(using: .utf8)!)
                        conn.cancel()
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        logRequest(path: "/v1/chat/completions", status: 200, provider: "Kimi", ms: ms)
                        DispatchQueue.main.async { self.requestCount += 1 }
                        return
                    }
                }
            }
        }

        sendRaw(conn: conn, data: "0\r\n\r\n".data(using: .utf8)!)
        conn.cancel()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        logRequest(path: "/v1/chat/completions", status: 200, provider: "Kimi", ms: ms)
        DispatchQueue.main.async { self.requestCount += 1 }
    }

    private func syncResponse(upstream: URLRequest, conn: NWConnection,
                               start: Date, provider: String) async throws {
        let (data, response) = try await URLSession.shared.data(for: upstream)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let body = String(data: data, encoding: .utf8) ?? "{}"
        sendJSON(conn: conn, status: status, body: body)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        logRequest(path: "/v1/chat/completions", status: status, provider: provider, ms: ms)
        DispatchQueue.main.async { self.requestCount += 1 }
    }

    private func sendRaw(conn: NWConnection, data: Data) {
        conn.send(content: data, completion: .idempotent)
    }

    private func sendChunked(conn: NWConnection, data: Data) {
        let header = String(format: "%X\r\n", data.count).data(using: .utf8)!
        var packet = Data()
        packet.append(header)
        packet.append(data)
        packet.append("\r\n".data(using: .utf8)!)
        conn.send(content: packet, completion: .idempotent)
    }

    private func sendJSON(conn: NWConnection, status: Int, body: String) {
        let statusText = HTTPURLResponse.localizedString(forStatusCode: status)
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: response.data(using: .utf8)!,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendError(conn: NWConnection, status: Int, message: String) {
        let body = #"{"error":{"message":"\#(message)","type":"proxy_error","code":\#(status)}}"#
        sendJSON(conn: conn, status: status, body: body)
    }

    private func logRequest(path: String, status: Int, provider: String, ms: Int) {
        let entry = RequestLog(timestamp: Date(), method: "POST", path: path,
                               statusCode: status, provider: provider, durationMs: ms)
        DispatchQueue.main.async {
            self.logs.insert(entry, at: 0)
            if self.logs.count > 200 { self.logs.removeLast() }
        }
    }
}

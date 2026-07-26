// --- ios/Chat2API_iOS/KimiAdapter.swift ---
import Foundation

// MARK: - Kimi Adapter

actor KimiAdapter {
    private let token: String
    private var cachedAccessToken: String?
    private var tokenExpiresAt: Int = 0

    private static let apiBase = "https://www.kimi.com"
    private static let fakeHeaders: [String: String] = [
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
        "Origin": "https://www.kimi.com",
        "Sec-Ch-Ua": "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
        "Sec-Ch-Ua-Mobile": "?0",
        "Sec-Ch-Ua-Platform": "\"Windows\"",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    ]

    init(token: String) {
        self.token = token
    }

    private func unixTimestamp() -> Int { Int(Date().timeIntervalSince1970) }

    private func isJWT(_ t: String) -> Bool {
        guard t.hasPrefix("eyJ") else { return false }
        let parts = t.split(separator: ".")
        guard parts.count == 3 else { return false }
        guard let payload = Data(base64Encoded: String(parts[1]).padding(toLength: ((String(parts[1]).count + 3) / 4) * 4, withPad: "=", startingAt: 0)),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        return json["app_id"] as? String == "kimi" && json["typ"] as? String == "access"
    }

    // MARK: Acquire token

    func acquireToken() async throws -> String {
        if let t = cachedAccessToken, unixTimestamp() < tokenExpiresAt { return t }

        // JWT — use directly
        if isJWT(token) {
            cachedAccessToken = token
            tokenExpiresAt = unixTimestamp() + 300
            return token
        }

        // Refresh token — use directly as bearer
        cachedAccessToken = token
        tokenExpiresAt = unixTimestamp() + 300
        return token
    }

    // MARK: Build gRPC frame

    private func encodeGrpcFrame(_ payload: [String: Any]) throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var frame = Data(count: 5 + jsonData.count)
        frame[0] = 0  // flag: no compression
        // 4-byte big-endian length
        let length = UInt32(jsonData.count)
        frame[1] = UInt8((length >> 24) & 0xFF)
        frame[2] = UInt8((length >> 16) & 0xFF)
        frame[3] = UInt8((length >> 8) & 0xFF)
        frame[4] = UInt8(length & 0xFF)
        frame.replaceSubrange(5..., with: jsonData)
        return frame
    }

    private func resolveScenario(_ model: String) -> String {
        model.lowercased().contains("k2.6") ? "SCENARIO_K2D6" : "SCENARIO_K2D5"
    }

    private func buildPayload(model: String, content: String,
                               enableWebSearch: Bool, enableThinking: Bool) -> [String: Any] {
        let scenario = resolveScenario(model)
        return [
            "scenario": scenario,
            "chat_id": "",
            "tools": enableWebSearch ? [["type": "TOOL_TYPE_SEARCH", "search": [String: Any]()]] : [],
            "message": [
                "parent_id": "",
                "role": "user",
                "blocks": [["message_id": "", "text": ["content": content]]],
                "scenario": scenario,
            ],
            "options": ["thinking": enableThinking],
        ]
    }

    private func prepareContent(messages: [[String: Any]]) -> String {
        var systemContent = ""
        var others: [(role: String, content: String)] = []

        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let text: String
            if let s = msg["content"] as? String { text = s }
            else if let parts = msg["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else { text = "" }

            if role == "system" { systemContent = text }
            else { others.append((role: role, content: text)) }
        }

        var result = systemContent.isEmpty ? "" : "system:\(systemContent)\n"

        if others.count < 2 {
            result += others.map { "\($0.content)\n" }.joined()
        } else {
            var withFocus = others
            let lastIdx = withFocus.count - 1
            withFocus.insert((role: "system", content: "Focus on the latest message from user"), at: lastIdx)
            result += withFocus.map { "\($0.role):\($0.content)\n" }.joined()
        }

        return result
    }

    // MARK: Chat completion

    func chatCompletion(request: ChatRequest) async throws -> URLRequest {
        let tok = try await acquireToken()
        let content = prepareContent(messages: request.messages)

        let modelLower = request.model.lowercased()
        let enableThinking = modelLower.contains("think") || modelLower.contains("r1")
        let enableWebSearch = modelLower.contains("search")

        let payload = buildPayload(model: request.model, content: content,
                                    enableWebSearch: enableWebSearch, enableThinking: enableThinking)
        let frameData = try encodeGrpcFrame(payload)

        let url = URL(string: "\(Self.apiBase)/apiv2/kimi.gateway.chat.v1.ChatService/Chat")!
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.httpBody = frameData
        for (k, v) in Self.fakeHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")

        return req
    }
}

// MARK: - Kimi Stream Parser

class KimiStreamParser {
    private let model: String
    private let created: Int
    private var conversationId: String = ""
    private var isFirstChunk = true
    private var buffer = Data()
    private var currentPhase: String = ""  // "thinking" | "answer"

    init(model: String) {
        self.model = model
        self.created = Int(Date().timeIntervalSince1970)
    }

    func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var output: [String] = []
        var offset = 0

        while offset + 5 <= buffer.count {
            // gRPC-Web frame: 1 byte flag + 4 bytes BE length + payload
            let length = Int(buffer[offset + 1]) << 24
                       | Int(buffer[offset + 2]) << 16
                       | Int(buffer[offset + 3]) << 8
                       | Int(buffer[offset + 4])

            guard offset + 5 + length <= buffer.count else { break }

            let payload = buffer.subdata(in: (offset + 5)..<(offset + 5 + length))
            offset += 5 + length

            guard let text = String(data: payload, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  let jsonData = text.data(using: .utf8),
                  let data = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { continue }

            output.append(contentsOf: processFrame(data))
        }

        buffer = buffer.subdata(in: offset..<buffer.count)
        return output
    }

    private func processFrame(_ data: [String: Any]) -> [String] {
        // heartbeat
        if data["heartbeat"] != nil { return [] }

        // extract chat id
        if let chat = data["chat"] as? [String: Any],
           let id = chat["id"] as? String, conversationId.isEmpty {
            conversationId = id
        }

        // phase detection from multiStage
        if let block = data["block"] as? [String: Any],
           let multiStage = block["multiStage"] as? [String: Any],
           let stages = multiStage["stages"] as? [[String: Any]],
           let first = stages.first,
           first["name"] as? String == "STAGE_NAME_THINKING" {
            currentPhase = first["status"] as? String == "completed" ? "answer" : "thinking"
        }

        // phase from text flags
        if let block = data["block"] as? [String: Any],
           let text = block["text"] as? [String: Any],
           let flags = text["flags"] as? String {
            currentPhase = flags == "thinking" ? "thinking" : "answer"
        }

        var output: [String] = []

        if let op = data["op"] as? String, (op == "set" || op == "append") {
            let mask = data["mask"] as? String ?? ""

            if mask.contains("block.think") {
                if let thinkContent = (data["block"] as? [String: Any])?["think"] as? [String: Any],
                   let content = thinkContent["content"] as? String {
                    output.append(contentsOf: emit(content: content, isThinking: true))
                }
            } else if mask.contains("block.text") {
                if let textBlock = (data["block"] as? [String: Any])?["text"] as? [String: Any],
                   let content = textBlock["content"] as? String {
                    output.append(contentsOf: emit(content: content, isThinking: false))
                }
            } else if let textBlock = (data["block"] as? [String: Any])?["text"] as? [String: Any],
                      let content = textBlock["content"] as? String {
                let isThinking = currentPhase == "thinking"
                output.append(contentsOf: emit(content: content, isThinking: isThinking))
            }
        }

        if data["done"] != nil {
            let chunk: [String: Any] = [
                "id": conversationId,
                "model": model,
                "object": "chat.completion.chunk",
                "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
                "created": created,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: chunk),
               let s = String(data: d, encoding: .utf8) {
                output.append("data: \(s)\n\n")
            }
            output.append("data: [DONE]\n\n")
        }

        return output
    }

    private func emit(content: String, isThinking: Bool) -> [String] {
        guard !content.isEmpty else { return [] }

        var delta: [String: Any] = [:]
        if isFirstChunk { delta["role"] = "assistant" }
        if isThinking { delta["reasoning_content"] = content }
        else { delta["content"] = content }

        let chunk: [String: Any] = [
            "id": conversationId,
            "model": model,
            "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]],
            "created": created,
        ]

        isFirstChunk = false

        guard let d = try? JSONSerialization.data(withJSONObject: chunk),
              let s = String(data: d, encoding: .utf8) else { return [] }
        return ["data: \(s)\n\n"]
    }
}

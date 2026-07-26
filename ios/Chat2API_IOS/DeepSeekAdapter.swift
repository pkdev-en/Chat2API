// --- ios/Chat2API_iOS/DeepSeekAdapter.swift ---
import Foundation
import JavaScriptCore

// MARK: - WASM PoW via JavaScriptCore

class DeepSeekHash {
    static let shared = DeepSeekHash()
    private var context: JSContext?
    private var initialized = false

    func initialize() {
        guard !initialized else { return }
        guard let wasmURL = Bundle.main.url(forResource: "sha3_wasm_bg.7b9ca65ddd", withExtension: "wasm"),
              let wasmData = try? Data(contentsOf: wasmURL) else {
            print("[DeepSeekHash] WASM file not found")
            return
        }

        let ctx = JSContext()!
        ctx.exceptionHandler = { _, ex in
            print("[DeepSeekHash] JS Exception:", ex?.toString() ?? "nil")
        }

        let wasmBase64 = wasmData.base64EncodedString()

        let js = """
        var wasmInstance = null;

        function initWasm(base64) {
            var binary = atob(base64);
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
            }
            var result = WebAssembly.instantiateSync(bytes.buffer, { wbg: {} });
            wasmInstance = result.instance.exports;
        }

        var cachedUint8Memory = null;
        var cachedTextEncoder = new TextEncoder();
        var offset = 0;

        function getCachedUint8Memory() {
            if (cachedUint8Memory === null || cachedUint8Memory.byteLength === 0) {
                cachedUint8Memory = new Uint8Array(wasmInstance.memory.buffer);
            }
            return cachedUint8Memory;
        }

        function encodeString(text, allocate, reallocate) {
            if (!reallocate) {
                var encoded = cachedTextEncoder.encode(text);
                var ptr = allocate(encoded.length, 1) >>> 0;
                var memory = getCachedUint8Memory();
                memory.subarray(ptr, ptr + encoded.length).set(encoded);
                offset = encoded.length;
                return ptr;
            }
            var strLength = text.length;
            var ptr = allocate(strLength, 1) >>> 0;
            var memory = getCachedUint8Memory();
            var asciiLength = 0;
            for (; asciiLength < strLength; asciiLength++) {
                var charCode = text.charCodeAt(asciiLength);
                if (charCode > 127) break;
                memory[ptr + asciiLength] = charCode;
            }
            if (asciiLength !== strLength) {
                if (asciiLength > 0) { text = text.slice(asciiLength); }
                ptr = reallocate(ptr, strLength, asciiLength + text.length * 3, 1) >>> 0;
                var result2 = cachedTextEncoder.encodeInto(
                    text,
                    getCachedUint8Memory().subarray(ptr + asciiLength, ptr + asciiLength + text.length * 3)
                );
                asciiLength += result2.written;
                ptr = reallocate(ptr, asciiLength + text.length * 3, asciiLength, 1) >>> 0;
            }
            offset = asciiLength;
            return ptr;
        }

        function calculateHash(algorithm, challenge, salt, difficulty, expireAt) {
            if (algorithm !== 'DeepSeekHashV1') return null;
            var prefix = salt + '_' + expireAt + '_';
            try {
                var retptr = wasmInstance.__wbindgen_add_to_stack_pointer(-16);
                var ptr0 = encodeString(challenge, wasmInstance.__wbindgen_export_0, wasmInstance.__wbindgen_export_1);
                var len0 = offset;
                var ptr1 = encodeString(prefix, wasmInstance.__wbindgen_export_0, wasmInstance.__wbindgen_export_1);
                var len1 = offset;
                wasmInstance.wasm_solve(retptr, ptr0, len0, ptr1, len1, difficulty);
                var dataView = new DataView(wasmInstance.memory.buffer);
                var status = dataView.getInt32(retptr + 0, true);
                var value = dataView.getFloat64(retptr + 8, true);
                wasmInstance.__wbindgen_add_to_stack_pointer(16);
                if (status === 0) return null;
                return value;
            } catch(e) {
                return null;
            }
        }

        initWasm('\(wasmBase64)');
        """

        ctx.evaluateScript(js)
        context = ctx
        initialized = true
        print("[DeepSeekHash] WASM initialized")
    }

    func calculateHash(algorithm: String, challenge: String, salt: String,
                       difficulty: Int, expireAt: Int) -> Double? {
        guard let ctx = context else { return nil }
        let result = ctx.evaluateScript(
            "calculateHash('\(algorithm)', '\(challenge)', '\(salt)', \(difficulty), \(expireAt))"
        )
        if let val = result, !val.isNull, !val.isUndefined {
            return val.toDouble()
        }
        return nil
    }
}

// MARK: - DeepSeek Adapter

actor DeepSeekAdapter {
    private let token: String
    private var accessToken: String?
    private var accessTokenExpiresAt: Int = 0
    private var sessionId: String?
    private var sessionCreatedAt: Date?

    private static let apiBase = "https://chat.deepseek.com/api"
    private static let fakeHeaders: [String: String] = [
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Origin": "https://chat.deepseek.com",
        "Referer": "https://chat.deepseek.com/",
        "Sec-Ch-Ua": "\"Not/A)Brand\";v=\"99\", \"Chromium\";v=\"148\"",
        "Sec-Ch-Ua-Mobile": "?0",
        "Sec-Ch-Ua-Platform": "\"macOS\"",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
        "X-App-Version": "2.0.0",
        "X-Client-Locale": "zh_CN",
        "X-Client-Platform": "web",
        "x-Client-Timezone-Offset": "28800",
        "X-Client-Version": "2.0.0",
    ]

    init(token: String) {
        self.token = token
        DeepSeekHash.shared.initialize()
    }

    private func unixTimestamp() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    private func generateRandomHex(_ length: Int) -> String {
        let chars = "0123456789abcdef"
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private func generateUUID() -> String { UUID().uuidString.lowercased() }

    private func generateCookie() -> String {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let tsSec = ts / 1000
        let uuid1 = generateUUID()
        let uuid2 = generateUUID()
        return "intercom-HWWAFSESTIME=\(ts); HWWAFSESID=\(generateRandomHex(18)); Hm_lvt_\(uuid1)=\(tsSec),\(tsSec),\(tsSec); Hm_lpvt_\(uuid1)=\(tsSec); _frid=\(uuid2); _fr_ssid=\(uuid2); _fr_pvid=\(uuid2)"
    }

    private func makeRequest(url: URL, method: String = "GET",
                              body: Data? = nil,
                              extraHeaders: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in Self.fakeHeaders { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    // MARK: Acquire token

    func acquireToken() async throws -> String {
        if let t = accessToken, unixTimestamp() < accessTokenExpiresAt { return t }

        let url = URL(string: "\(Self.apiBase)/v0/users/current")!
        var req = makeRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 {
            throw ProxyError.message("DeepSeek token invalid or expired")
        }
        guard status == 200 else {
            throw ProxyError.message("acquireToken: HTTP \(status)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let bizData = (json?["data"] as? [String: Any])?["biz_data"] as? [String: Any]
            ?? json?["biz_data"] as? [String: Any]
        guard let newToken = bizData?["token"] as? String else {
            throw ProxyError.message("acquireToken: no token in response")
        }

        accessToken = newToken
        accessTokenExpiresAt = unixTimestamp() + 3600
        return newToken
    }

    // MARK: Create session

    func createSession() async throws -> String {
        if let s = sessionId,
           let created = sessionCreatedAt,
           Date().timeIntervalSince(created) < 300 { return s }

        let tok = try await acquireToken()
        let url = URL(string: "\(Self.apiBase)/v0/chat_session/create")!
        var req = makeRequest(url: url, method: "POST", body: "{}".data(using: .utf8))
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue(generateCookie(), forHTTPHeaderField: "Cookie")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ProxyError.message("createSession: HTTP \(status)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let bizData = (json?["data"] as? [String: Any])?["biz_data"] as? [String: Any]
            ?? json?["biz_data"] as? [String: Any]
        guard let sid = (bizData?["chat_session"] as? [String: Any])?["id"] as? String else {
            throw ProxyError.message("createSession: no session id")
        }

        sessionId = sid
        sessionCreatedAt = Date()
        return sid
    }

    // MARK: PoW Challenge

    private struct Challenge: Decodable {
        let algorithm: String
        let challenge: String
        let salt: String
        let difficulty: Int
        let expire_at: Int
        let signature: String
    }

    private func getChallenge(tok: String) async throws -> Challenge {
        let url = URL(string: "\(Self.apiBase)/v0/chat/create_pow_challenge")!
        let body = try JSONSerialization.data(withJSONObject: ["target_path": "/api/v0/chat/completion"])
        var req = makeRequest(url: url, method: "POST", body: body)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ProxyError.message("getChallenge: HTTP \(status)") }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let bizData = (json?["data"] as? [String: Any])?["biz_data"] as? [String: Any]
            ?? json?["biz_data"] as? [String: Any]
        guard let challengeData = bizData?["challenge"] else {
            throw ProxyError.message("getChallenge: no challenge in response")
        }

        let challengeJSON = try JSONSerialization.data(withJSONObject: challengeData)
        return try JSONDecoder().decode(Challenge.self, from: challengeJSON)
    }

    private func solvePow(_ c: Challenge) throws -> String {
        guard c.algorithm == "DeepSeekHashV1" else {
            throw ProxyError.message("Unsupported PoW algorithm: \(c.algorithm)")
        }

        guard let answer = DeepSeekHash.shared.calculateHash(
            algorithm: c.algorithm,
            challenge: c.challenge,
            salt: c.salt,
            difficulty: c.difficulty,
            expireAt: c.expire_at
        ) else {
            throw ProxyError.message("PoW calculation failed")
        }

        let payload: [String: Any] = [
            "algorithm": c.algorithm,
            "challenge": c.challenge,
            "salt": c.salt,
            "answer": answer,
            "signature": c.signature,
            "target_path": "/api/v0/chat/completion",
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return payloadData.base64EncodedString()
    }

    // MARK: Message format

    private func messagesToPrompt(_ messages: [[String: Any]]) -> String {
        var blocks: [(role: String, text: String)] = []

        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let text: String
            if let content = msg["content"] as? String {
                text = content
            } else if let parts = msg["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                text = ""
            }

            if let last = blocks.last, last.role == role {
                blocks[blocks.count - 1].text += "\n\n" + text
            } else {
                blocks.append((role: role, text: text))
            }
        }

        return blocks.enumerated().map { i, block in
            switch block.role {
            case "assistant":
                return "<｜Assistant｜>\(block.text)<｜end of sentence｜>"
            case "user", "system":
                return i > 0 ? "<｜User｜>\(block.text)" : block.text
            default:
                return block.text
            }
        }.joined()
    }

    // MARK: Chat completion

    func chatCompletion(request: ChatRequest) async throws -> (URLRequest, String) {
        let tok = try await acquireToken()
        let sid = try await createSession()
        let challenge = try await getChallenge(tok: tok)
        let powResponse = try solvePow(challenge)

        let modelLower = request.model.lowercased()
        let isProModel = modelLower.contains("pro") || modelLower.contains("expert")
        let searchEnabled = modelLower.contains("search")
        let thinkingEnabled = modelLower.contains("think") || modelLower.contains("r1")

        let prompt = messagesToPrompt(request.messages)

        let body: [String: Any] = [
            "chat_session_id": sid,
            "parent_message_id": NSNull(),
            "prompt": prompt,
            "model_type": isProModel ? "expert" : "default",
            "ref_file_ids": [],
            "search_enabled": searchEnabled,
            "thinking_enabled": thinkingEnabled,
            "preempt": false,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let url = URL(string: "\(Self.apiBase)/v0/chat/completion")!
        var req = makeRequest(url: url, method: "POST", body: bodyData, extraHeaders: [
            "Authorization": "Bearer \(tok)",
            "Referer": "https://chat.deepseek.com/a/chat/s/\(sid)",
            "Cookie": generateCookie(),
            "X-Ds-Pow-Response": powResponse,
        ])

        return (req, sid)
    }
}

// MARK: - DeepSeek Stream Parser

class DeepSeekStreamParser {
    private let model: String
    private let sessionId: String
    private let created: Int
    private var messageId: String = ""
    private var currentPath: String = ""
    private var isFirstChunk = true
    private var isDone = false
    private var buffer: String = ""
    private var thinkingStarted = false
    private let webSearchEnabled: Bool
    private let isThinkingModel: Bool

    init(model: String, sessionId: String, webSearchEnabled: Bool = false) {
        self.model = model
        self.sessionId = sessionId
        self.created = Int(Date().timeIntervalSince1970)
        let ml = model.lowercased()
        self.isThinkingModel = ml.contains("think") || ml.contains("r1") || ml.contains("reasoner")
        self.webSearchEnabled = webSearchEnabled
    }

    func feed(_ chunk: Data) -> [String] {
        guard let text = String(data: chunk, encoding: .utf8) else { return [] }
        buffer += text

        var output: [String] = []
        let lines = buffer.components(separatedBy: "\n")
        buffer = lines.last ?? ""

        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let data = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard data != "[DONE]" else {
                output.append("data: [DONE]\n\n")
                isDone = true
                continue
            }

            guard let jsonData = data.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { continue }

            output.append(contentsOf: processChunk(parsed))
        }

        return output
    }

    private func processChunk(_ chunk: [String: Any]) -> [String] {
        var output: [String] = []

        if let msgId = chunk["response_message_id"] as? String, messageId.isEmpty {
            messageId = msgId
        }

        // Fragment-based response (new format)
        if let vObj = chunk["v"] as? [String: Any],
           let response = vObj["response"] as? [String: Any] {
            let thinkingEnabled = response["thinking_enabled"] as? Bool ?? false
            currentPath = thinkingEnabled ? "thinking" : "content"

            if let fragments = response["fragments"] as? [[String: Any]] {
                for fragment in fragments {
                    if let content = fragment["content"] as? String,
                       let type = fragment["type"] as? String {
                        let path = type == "THINK" ? "thinking" : "content"
                        output.append(contentsOf: sendContent(content, path: path))
                    }
                }
            }
            return output
        }

        // SSE patch format
        if let p = chunk["p"] as? String, p == "response/fragments",
           let vArr = chunk["v"] as? [[String: Any]] {
            for fragment in vArr {
                if let content = fragment["content"] as? String,
                   let type = fragment["type"] as? String {
                    let path = type == "THINK" ? "thinking" : "content"
                    currentPath = path
                    output.append(contentsOf: sendContent(content, path: path))
                }
            }
            return output
        }

        // String value
        if let v = chunk["v"] as? String, !v.isEmpty {
            var effectivePath = currentPath
            if effectivePath.isEmpty { effectivePath = isThinkingModel ? "thinking" : "content" }
            let cleaned = v.replacingOccurrences(of: "FINISHED", with: "")
            output.append(contentsOf: sendContent(cleaned, path: effectivePath))
        }

        return output
    }

    private func sendContent(_ content: String, path: String) -> [String] {
        guard !content.isEmpty else { return [] }

        var delta: [String: Any] = [:]

        if isFirstChunk { delta["role"] = "assistant" }

        if path == "thinking" {
            delta["reasoning_content"] = content
        } else {
            delta["content"] = content
        }

        let chunk: [String: Any] = [
            "id": "\(sessionId)@\(messageId)",
            "model": model,
            "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]],
            "created": created,
        ]

        isFirstChunk = false

        guard let data = try? JSONSerialization.data(withJSONObject: chunk),
              let str = String(data: data, encoding: .utf8) else { return [] }
        return ["data: \(str)\n\n"]
    }

    func finish() -> [String] {
        let chunk: [String: Any] = [
            "id": "\(sessionId)@\(messageId)",
            "model": model,
            "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
            "created": created,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: chunk),
              let str = String(data: data, encoding: .utf8) else { return [] }
        return ["data: \(str)\n\n", "data: [DONE]\n\n"]
    }
}

enum ProxyError: Error {
    case message(String)
    var localizedDescription: String {
        switch self { case .message(let m): return m }
    }
}

struct ChatRequest {
    let model: String
    let messages: [[String: Any]]
    let stream: Bool
}

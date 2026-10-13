import AppKit
import CryptoKit
import Foundation
import Network

@MainActor
enum LoginSession {
    private static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let scopes = "openid profile email offline_access grok-cli:access api:access"
    private static var listener: NWListener?
    private static var verifier = ""
    private static var expectedState = ""
    private static var redirect = ""
    private static var done: ((Bool) -> Void)?
    private static var finished = false

    static func start() {
        start { _ in }
    }

    static func start(done: @escaping (Bool) -> Void) {
        self.done = done
        finished = false
        listener?.cancel()
        verifier = randomToken()
        expectedState = randomToken()
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            let next = try NWListener(using: parameters)
            next.newConnectionHandler = { connection in
                accept(connection)
            }
            next.stateUpdateHandler = { state in
                Task { @MainActor in
                    if case .ready = state, let port = next.port {
                        openAuthorize(port: port)
                    }
                    if case .failed = state {
                        finish(false)
                    }
                }
            }
            listener = next
            next.start(queue: .global(qos: .userInitiated))
        } catch {
            finish(false)
        }
    }

    private static func openAuthorize(port: NWEndpoint.Port) {
        redirect = "http://127.0.0.1:\(port.rawValue)/callback"
        var parts = URLComponents(string: "https://auth.x.ai/oauth2/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: expectedState),
            URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "login"),
        ]
        guard let url = parts.url else {
            finish(false)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config)
    }

    nonisolated private static func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let body = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Connection: close\r
            \r
            <p>登录完成，可以回到 Grok。</p>
            """
            connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            Task { @MainActor in
                handle(text)
            }
        }
    }

    private static func handle(_ request: String) {
        guard let line = request.split(separator: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            return
        }
        let code = components.queryItems?.first { $0.name == "code" }?.value ?? ""
        let state = components.queryItems?.first { $0.name == "state" }?.value ?? ""
        guard !code.isEmpty, state == expectedState else {
            return
        }
        Task { await exchange(code) }
    }

    /// Accepts a code pasted by the user from the consent page.
    /// Takes a bare code, a "code#state" pair, or a full callback URL.
    static func submit(pasted raw: String, done: @escaping (Bool) -> Void) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var code = text
        if let parts = URLComponents(string: text),
           let item = parts.queryItems?.first(where: { $0.name == "code" })?.value {
            code = item
        } else if let hash = text.firstIndex(of: "#") {
            code = String(text[..<hash])
        }
        self.done = done
        finished = false
        Task { await exchange(code) }
    }

    private static func exchange(_ code: String) async {
        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": clientID,
            "code_verifier": verifier,
        ].map { "\($0.key)=\(formEscape($0.value))" }.joined(separator: "&")
        request.httpBody = Data(form.utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let token = (json?["access_token"] as? String) ?? ""
            guard status == 200, !token.isEmpty else {
                finish(false)
                return
            }
            TokenStore.store(json ?? [:])
            NSLog("GrokMac login: refresh token %@", ((json?["refresh_token"] as? String) ?? "").isEmpty ? "missing" : "received")
            finish(true)
        } catch {
            finish(false)
        }
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        let callback = done
        done = nil
        callback?(ok)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func challenge(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import AppKit
import AuthenticationServices

@MainActor
final class LoginSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = LoginSession()
    private var session: ASWebAuthenticationSession?

    func start() {
        let url = URL(string: "https://accounts.x.ai/sign-in")!
        let next = ASWebAuthenticationSession(url: url, callbackURLScheme: "grokmac") { _, _ in
            Task { @MainActor in
                self.session = nil
            }
        }
        next.presentationContextProvider = self
        next.prefersEphemeralWebBrowserSession = false
        session = next
        if !next.start() {
            NSWorkspace.shared.open(url)
        }
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? ASPresentationAnchor()
    }
}

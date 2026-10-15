import AppKit
import WebKit
import MCCPublisherCore

/// A dedicated Microsoft authorization window. Never reads forms, passwords or browser cookies.
@MainActor
final class MicrosoftLoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<URL, Error>?
    private var challenge: SignInChallenge?

    func authorize(_ challenge: SignInChallenge) async throws -> URL {
        guard continuation == nil else { throw PublisherError.authentication("Sign-in is already open.") }
        guard challenge.url.scheme == "https", let host = challenge.url.host,
              host == "login.live.com" || host == "login.microsoftonline.com" || host == "sisu.xboxlive.com" else {
            throw PublisherError.authentication("Microsoft did not provide a recognized sign-in address.")
        }
        self.challenge = challenge
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 710),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Sign in with Microsoft"; window.delegate = self; window.isReleasedWhenClosed = false
            window.contentView = web; window.center(); window.makeKeyAndOrderFront(nil)
            self.window = window; self.webView = web
            web.load(URLRequest(url: challenge.url))
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let challenge else { decisionHandler(.cancel); return }
        if url.scheme == challenge.redirectURI.scheme, url.host == challenge.redirectURI.host, url.path == challenge.redirectURI.path {
            decisionHandler(.cancel)
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value
            guard state == challenge.state else {
                finish(.failure(PublisherError.authentication("Microsoft returned a sign-in response for a different session."))); return
            }
            finish(.success(url)); return
        }
        // External app schemes and plain HTTP are never followed in the authorization view.
        guard url.scheme == "https" || url.absoluteString == "about:blank" else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(PublisherError.authentication("Microsoft sign-in could not load. Check your connection and try again."))) }
    }
    func windowWillClose(_ notification: Notification) { finish(.failure(PublisherError.cancelled)) }
    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil; challenge = nil
        window?.delegate = nil; window?.close(); window = nil; webView?.navigationDelegate = nil; webView = nil
        c.resume(with: result)
    }
}

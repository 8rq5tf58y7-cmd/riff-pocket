import SwiftUI
import WebKit
import RiffCore

/// Sign in to Plaud's own website (e.g. "Continue with Apple") inside the app, then capture the
/// long-lived account token — the same approach as Riffado's Connector browser extension:
/// read the HttpOnly `pld_ut` cookie (native apps can, via WKHTTPCookieStore), falling back to
/// `localStorage.pld_tokenstr`. Workspace tokens (~24h) are rejected by `PlaudJWT.validateShape`.
///
/// Uses a non-persistent data store, so no Plaud web session survives after the token is captured.
/// Note: Google blocks sign-in inside embedded web views — Google-account users should paste a token.
struct PlaudWebLoginView: UIViewRepresentable {
    let startURL: URL
    let desktopMode: Bool
    let onToken: (String) -> Void

    func makeCoordinator() -> PlaudWebLoginCoordinator {
        PlaudWebLoginCoordinator(onToken: onToken)
    }

    func makeUIView(context: Context) -> WebContainer {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.preferredContentMode = desktopMode ? .desktop : .mobile
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let container = WebContainer(configuration: config)
        context.coordinator.attach(to: container)
        container.webView.load(URLRequest(url: startURL))
        return container
    }

    func updateUIView(_ uiView: WebContainer, context: Context) {}

    static func dismantleUIView(_ uiView: WebContainer, coordinator: PlaudWebLoginCoordinator) {
        coordinator.stop()
    }
}

final class WebContainer: UIView {
    let webView: WKWebView
    var popups: [WKWebView] = []

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.allowsBackForwardNavigationGestures = true
        addFilling(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func addFilling(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
final class PlaudWebLoginCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let onToken: (String) -> Void
    private weak var container: WebContainer?
    private var delivered = false
    private var timer: Timer?

    init(onToken: @escaping (String) -> Void) {
        self.onToken = onToken
        super.init()
    }

    func attach(to container: WebContainer) {
        self.container = container
        container.webView.navigationDelegate = self
        container.webView.uiDelegate = self
        container.webView.configuration.websiteDataStore.httpCookieStore.add(self)
        // Some sign-in flows finish via XHR without a navigation; poll as a backstop.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() async {
        guard !delivered, let web = container?.webView else { return }
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        if let cookie = cookies.first(where: { $0.name == "pld_ut" && $0.domain.contains("plaud") }),
           accept(cookie.value) { return }
        // `|| ''` keeps the result a String (async evaluateJavaScript traps on null).
        if let value = try? await web.evaluateJavaScript("localStorage.getItem('pld_tokenstr') || ''") as? String,
           !value.isEmpty {
            _ = accept(value)
        }
    }

    private func accept(_ raw: String) -> Bool {
        guard !delivered, let token = try? PlaudJWT.validateShape(raw.removingPercentEncoding ?? raw) else { return false }
        delivered = true
        stop()
        onToken(token)
        return true
    }

    // MARK: WKNavigationDelegate / cookie observer

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await check() }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.check() }
    }

    // MARK: Popups ("Continue with Apple" may open a window)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let container = container else { return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        container.addFilling(popup)
        container.popups.append(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.removeFromSuperview()
        container?.popups.removeAll { $0 === webView }
        Task { await check() }
    }
}

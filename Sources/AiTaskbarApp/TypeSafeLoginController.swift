import AppKit
import WebKit
import AiTaskbarCore

/// In-app sign-in to the TypeSafe console (docs/SDD-typesafe-jev.md §16.3).
///
/// Opens `console.typesafe.ai/login` in a `WKWebView` with a NON-persistent
/// data store, so nothing of the login outlives the window and the system
/// browsers' cookies are never touched. The user signs in however they like
/// (Google, e-mail); the controller never reads what they type. Once the
/// console itself is showing, it copies ONLY the three login cookies out of
/// the webview's own store, persists them encrypted (`console_session`, 0600
/// via `ConfigLoader.applyChanges`) and hands them to the provider through
/// `TypeSafeSessionStore`, so the card fills in without a relaunch.
@MainActor
final class TypeSafeLoginController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = TypeSafeLoginController()

    nonisolated static let loginURL = URL(string: "https://console.typesafe.ai/login")!
    /// A login left open this long is abandoned.
    static let timeout: TimeInterval = 10 * 60

    @Published private(set) var session: TypeSafeConsoleSession?
    @Published private(set) var isSigningIn = false
    @Published var lastError: String?

    private var configLoader: ConfigLoader?
    private var store: TypeSafeSessionStore?
    private var onChange: (() -> Void)?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var poll: Timer?
    private var startedAt = Date()

    func configure(configLoader: ConfigLoader, store: TypeSafeSessionStore, onChange: @escaping () -> Void) {
        self.configLoader = configLoader
        self.store = store
        self.onChange = onChange
        session = store.current
    }

    func signIn() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 700), configuration: cfg)
        let win = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = L10n.localizedString("typesafe_login_window_title")
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        webView = web
        lastError = nil
        isSigningIn = true
        startedAt = Date()
        web.load(URLRequest(url: Self.loginURL))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Next.js navigates client-side (no didFinish), so poll the URL and
        // the webview's own cookie store once a second.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func signOut() {
        persist(nil)
    }

    private func tick() {
        guard let web = webView else { return }
        if Date().timeIntervalSince(startedAt) > Self.timeout {
            finish()
            return
        }
        // Only once the console itself is showing: pre-login pages may carry
        // anonymous cookies with the same names.
        guard Self.isSignedInPage(web.url) else { return }
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            MainActor.assumeIsolated {
                guard let self, self.webView === web else { return }
                let own = cookies.filter { Self.isTypeSafeDomain($0.domain) }
                    .map { (name: $0.name, value: $0.value, expiresAt: $0.expiresDate) }
                guard let captured = TypeSafeConsoleSession.capture(own) else { return }
                self.persist(captured)
                self.finish()
            }
        }
    }

    nonisolated static func isSignedInPage(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == "console.typesafe.ai" else { return false }
        let path = url.path.lowercased()
        return !path.hasPrefix("/login") && !path.hasPrefix("/signup") && !path.hasPrefix("/auth")
    }

    nonisolated static func isTypeSafeDomain(_ domain: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return d == "typesafe.ai" || d.hasSuffix(".typesafe.ai")
    }

    private func persist(_ new: TypeSafeConsoleSession?) {
        guard let configLoader, let store else { return }
        do {
            try configLoader.applyChanges([
                .secret(section: "typesafe", key: "console_session", plaintext: new?.cookieHeader),
                .double(section: "typesafe", key: "console_session_expires_at",
                        value: new?.expiresAt?.timeIntervalSince1970 ?? 0),
            ])
        } catch {
            // The session is not stored: the user must see it, not a card
            // that silently stays disconnected.
            lastError = L10n.localizedString("typesafe_login_save_failed_fmt", String(describing: error))
            return
        }
        store.set(new)
        session = new
        onChange?()
    }

    private func finish() {
        poll?.invalidate()
        poll = nil
        let win = window
        window = nil
        webView = nil
        isSigningIn = false
        win?.delegate = nil
        win?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            poll?.invalidate()
            poll = nil
            window = nil
            webView = nil
            isSigningIn = false
        }
    }
}

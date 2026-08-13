import Foundation
import WebKit
import Observability

// ─────────────────────────────────────────────────────────────
// A browser with no window (ARCHITECTURE §1.4.1, P13.1).
//
// The criterion P13.1 is judged on is "runs inside the sandboxed .app", and this
// is the option that needs nothing packaged: `WKWebView` is a system framework,
// so there is no Python runtime to bundle and no second sidecar to keep alive.
// It also executes JavaScript, which is what `PageFetcher` cannot do — the
// `FetchError.empty` seen most often is a page whose text is not in the HTML the
// server sent.
//
// Three rules, all from §1.4.1, all about refusing to guess:
//
//  • **A bot wall is not an empty result.** A page that asks for a CAPTCHA comes
//    back as `blocked`, never as "nothing found" — in research the second one is
//    the most expensive lie the system could tell, because "no evidence" reads as
//    a finding. The system does not solve the CAPTCHA either; it says a person is
//    needed.
//  • **A page that loads but parses to nothing is an error.** v1 scraped
//    DuckDuckGo's HTML and broke silently every time the markup moved. Zero
//    results from a page that loaded fine means the extractor is stale, and that
//    has to be loud.
//  • **Page text is data, not instructions.** Whatever comes back is content with
//    provenance. Nothing here concatenates it into a prompt.
//
// One web view, one queue, and the session data is cleared between searches: we
// are not trying to look like a returning visitor, and a cookie jar that
// accumulates is a fingerprint plus a privacy problem.
// ─────────────────────────────────────────────────────────────

public enum HeadlessError: Error, CustomStringConvertible, Equatable {
    case timedOut(url: String, seconds: Int)
    /// A bot wall, a CAPTCHA, or an HTTP status that means "not for robots".
    /// Carries what was seen so the message can name it rather than guess.
    case blocked(reason: String, url: String)
    case http(status: Int, url: String)
    /// Loaded, but the extractor found nothing. The engine's markup has moved.
    case extractorFoundNothing(engine: String, url: String)
    case notAvailable(String)

    public var description: String {
        switch self {
        case .timedOut(let url, let seconds):
            "โหลดหน้าไม่ทันใน \(seconds) วินาที: \(url)"
        case .blocked(let reason, let url):
            // The wording is the point: this is a request for a person, not a
            // result. §1.4.1 — the system does not solve CAPTCHAs.
            "ถูกด่านกันบอทกั้นไว้ (\(reason)) — ต้องให้คนเปิดหน้านี้เองแล้วค้นด้วยมือ "
                + "หรือเปลี่ยนไปใช้แหล่งที่อนุญาต: \(url)"
        case .http(let status, let url):
            "เซิร์ฟเวอร์ตอบ \(status): \(url)"
        case .extractorFoundNothing(let engine, let url):
            "หน้าโหลดสำเร็จแต่อ่านผลลัพธ์ไม่ได้เลย — ตัวอ่านของ \(engine) ล้าสมัยแล้ว "
                + "(ไม่ใช่ 'ไม่มีผลลัพธ์'): \(url)"
        case .notAvailable(let why):
            "ใช้เบราว์เซอร์ในแอปไม่ได้: \(why)"
        }
    }
}

/// What came back from one load.
public struct LoadedPage: Sendable, Equatable {
    /// After redirects — what was actually read, which is what a citation names.
    public let finalURL: URL
    public let html: String
    public let statusCode: Int?

    public init(finalURL: URL, html: String, statusCode: Int? = nil) {
        self.finalURL = finalURL
        self.html = html
        self.statusCode = statusCode
    }
}

/// Whether a page is a wall rather than a result. Pure, so the markers can be
/// tested against real captured pages without a browser.
public enum BotWall {
    /// Substrings that mean "prove you are human". Lowercased comparison; kept
    /// short and specific — matching the word "robot" anywhere would flag half
    /// the pages about robotics.
    static let markers = [
        "captcha", "recaptcha", "unusual traffic", "verify you are human",
        "are you a robot", "cf-challenge", "cf_chl_", "px-captcha",
        "ยืนยันว่าคุณไม่ใช่บอท",
    ]

    /// Paths engines redirect to when they refuse automation.
    static let paths = ["/sorry/", "/challenge", "/blocked", "/captcha"]

    public static func detect(url: URL, html: String, statusCode: Int? = nil) -> HeadlessError? {
        if let statusCode, statusCode == 403 || statusCode == 429 {
            return .blocked(reason: "http \(statusCode)", url: url.absoluteString)
        }
        let path = url.path().lowercased()
        if let hit = paths.first(where: { path.contains($0) }) {
            return .blocked(reason: "ถูกส่งไปหน้า \(hit)", url: url.absoluteString)
        }
        // Only the head of the document: the words appear in ordinary prose
        // further down often enough that scanning the whole page would flag
        // articles *about* CAPTCHAs.
        let head = html.prefix(4_000).lowercased()
        if let hit = markers.first(where: { head.contains($0) }) {
            return .blocked(reason: "พบ '\(hit)' ในหน้า", url: url.absoluteString)
        }
        return nil
    }
}

/// One offscreen `WKWebView`, driven one page at a time.
///
/// `@MainActor` because WebKit requires it — every caller is an actor that awaits
/// hops onto the main actor for the load and gets a plain value back, so nothing
/// holds a web view across a suspension.
@MainActor
public final class HeadlessBrowser {
    private let webView: WKWebView
    private let navigation = NavigationWatcher()
    private let log = AppLog.logger("headless-browser")
    /// Politeness, per host. A crawler that hammers one domain gets blocked, and
    /// then §1.4.1's rule turns every later search into "a person is needed".
    private var lastVisit: [String: Date] = [:]
    private let minimumGap: TimeInterval

    public init(minimumGap: TimeInterval = 1.5) {
        let configuration = WKWebViewConfiguration()
        // Ephemeral: nothing is remembered between launches, and `clearSession`
        // wipes even within one.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_280, height: 900),
                            configuration: configuration)
        // A real, current user agent string. Not a disguise — the default WebKit
        // string identifies as a WebView and several engines serve those a
        // stripped page, which would look like a broken extractor.
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        self.minimumGap = minimumGap
        webView.navigationDelegate = navigation
    }

    /// Loads a page and returns its rendered HTML.
    ///
    /// `settle` is the pause after `didFinish` for client-side rendering to
    /// happen. Deliberately a fixed wait rather than a "network idle" heuristic:
    /// idle detection on a page with polling never fires, and a search page that
    /// never returns is worse than one that returns early and fails loudly.
    public func page(_ url: URL, timeout: TimeInterval = 20,
                     settle: TimeInterval = 0.6) async throws -> LoadedPage {
        try await waitForPoliteness(host: url.host() ?? "")

        navigation.reset()
        webView.load(URLRequest(url: url))
        do {
            try await navigation.finished(timeout: timeout)
        } catch is CancellationError {
            throw HeadlessError.timedOut(url: url.absoluteString, seconds: Int(timeout))
        }
        if let status = navigation.statusCode, status >= 400 {
            // 403/429 are a wall, not a server error — `BotWall` names which.
            if let blocked = BotWall.detect(url: webView.url ?? url, html: "",
                                            statusCode: status) {
                throw blocked
            }
            throw HeadlessError.http(status: status, url: url.absoluteString)
        }

        try? await Task.sleep(for: .seconds(settle))
        let html = try await outerHTML()
        let finalURL = webView.url ?? url
        if let blocked = BotWall.detect(url: finalURL, html: html,
                                        statusCode: navigation.statusCode) {
            log.warning("blocked at \(finalURL.host() ?? "?", privacy: .public)")
            throw blocked
        }
        return LoadedPage(finalURL: finalURL, html: html, statusCode: navigation.statusCode)
    }

    /// Runs an extractor in the loaded page and returns whatever JSON it printed.
    /// The DOM does the parsing — the whole reason for using a browser rather
    /// than a regex over HTML, which is how v1's scraper broke.
    public func evaluateJSON(_ javascript: String) async throws -> Data {
        let value = try await webView.evaluateJavaScript(javascript)
        guard let text = value as? String else {
            throw HeadlessError.notAvailable("ตัวอ่านไม่ได้คืนข้อความ JSON")
        }
        return Data(text.utf8)
    }

    /// Forgets cookies and storage. Called between searches: this is not a
    /// returning visitor, and an accumulating jar is a fingerprint.
    public func clearSession() async {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    private func outerHTML() async throws -> String {
        let value = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
        return (value as? String) ?? ""
    }

    private func waitForPoliteness(host: String) async throws {
        guard let last = lastVisit[host] else {
            lastVisit[host] = Date()
            return
        }
        let elapsed = Date().timeIntervalSince(last)
        if elapsed < minimumGap {
            try? await Task.sleep(for: .seconds(minimumGap - elapsed))
        }
        lastVisit[host] = Date()
    }
}

/// Bridges `WKNavigationDelegate`'s callbacks to one awaitable finish.
private final class NavigationWatcher: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var statusCode: Int?
    private var settled = false

    func reset() {
        statusCode = nil
        settled = false
    }

    /// Awaits `didFinish`, or gives up.
    ///
    /// The timeout is a race against a sleeping task rather than a `Task` with a
    /// deadline, because WebKit will happily never call back on a page that keeps
    /// a connection open — and a search that hangs forever is the one failure
    /// mode worse than a search that fails.
    @MainActor
    func finished(timeout: TimeInterval) async throws {
        let load = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                if settled { continuation.resume(); return }
                self.continuation = continuation
            }
        }
        let alarm = Task {
            try await Task.sleep(for: .seconds(timeout))
            await MainActor.run { self.settle(.failure(CancellationError())) }
        }
        defer { alarm.cancel() }
        try await load.value
    }

    private func settle(_ result: Result<Void, Error>) {
        settled = true
        let waiting = continuation
        continuation = nil
        switch result {
        case .success: waiting?.resume()
        case .failure(let error): waiting?.resume(throwing: error)
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            statusCode = response.statusCode
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settle(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        settle(.failure(error))
    }
}

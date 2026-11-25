import Combine
import SwiftUI
import WebKit

/// Full-screen Home Assistant dashboard. Sign-in is kept in the default
/// website data store, so you only log in once.
struct DashboardView: UIViewRepresentable {
    let url: URL
    let zoom: CGFloat
    let darkMode: Bool?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.allowsBackForwardNavigationGestures = false

        // Any touch wakes the screen and restarts the screen timeout,
        // without getting in the way of the dashboard.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touched))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        webView.addGestureRecognizer(tap)

        context.coordinator.attach(webView)
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        let style: UIUserInterfaceStyle = darkMode.map { $0 ? .dark : .light } ?? .unspecified
        if webView.overrideUserInterfaceStyle != style { webView.overrideUserInterfaceStyle = style }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var loadedURL: URL?
        private weak var webView: WKWebView?
        private var urlObservation: NSKeyValueObservation?
        private var commands: AnyCancellable?
        private var retry: DispatchWorkItem?

        func attach(_ webView: WKWebView) {
            self.webView = webView
            urlObservation = webView.observe(\.url, options: [.new]) { webView, _ in
                guard let url = webView.url else { return }
                DispatchQueue.main.async { Satellite.shared.webPathChanged(url.path) }
            }
            commands = Satellite.shared.webCommands.sink { [weak self] command in
                guard let webView = self?.webView else { return }
                switch command {
                case .reload: webView.reload()
                case let .load(url): webView.load(URLRequest(url: url))
                }
            }
        }

        @objc func touched() { Satellite.shared.userActivity() }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // Home Assistant restarting or Wi-Fi dropping leaves an error page;
        // try again until it's back.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            scheduleRetry(webView, error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            scheduleRetry(webView, error)
        }

        private func scheduleRetry(_ webView: WKWebView, _ error: Error) {
            Log.shared.add("Dashboard failed to load: \(error.localizedDescription)")
            retry?.cancel()
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let webView, let url = self?.loadedURL else { return }
                webView.load(URLRequest(url: url))
            }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        }

        // Many home servers use a self-signed certificate. Accept it for the
        // Home Assistant host only.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               challenge.protectionSpace.host == loadedURL?.host,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}

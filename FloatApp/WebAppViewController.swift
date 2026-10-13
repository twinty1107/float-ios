import UIKit
import WebKit

/// Native WKWebView shell around https://meou123.netlify.app/
/// Keeps the PWA inside the app, locks portrait, handles camera/mic uploads,
/// opens off-site links in Safari and shows a branded offline screen.
final class WebAppViewController: UIViewController {

    // MARK: - Configuration

    private enum Config {
        static let startURL = URL(string: "https://meou123.netlify.app/")!
        /// Hosts allowed to stay inside the app; everything else opens in Safari.
        static let inAppHosts: Set<String> = ["meou123.netlify.app"]
        static let backgroundColor = UIColor.black
    }

    // MARK: - Views

    private var webView: WKWebView!
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let splashView = UIView()
    private let errorView = UIView()
    private let errorLabel = UILabel()

    private var progressObservation: NSKeyValueObservation?
    private var didFinishFirstLoad = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Config.backgroundColor
        configureWebView()
        configureProgressBar()
        configureSplash()
        configureErrorView()
        loadStartPage()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        didFinishFirstLoad ? .default : .lightContent
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    // MARK: - Setup

    private func configureWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        let userContentController = WKUserContentController()
        // Viewport guard: keeps the PWA edge-to-edge under the notch / home indicator.
        let viewportScript = """
        (function () {
          var meta = document.querySelector('meta[name="viewport"]');
          if (!meta) {
            meta = document.createElement('meta');
            meta.setAttribute('name', 'viewport');
            document.head.appendChild(meta);
          }
          meta.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover, user-scalable=no');
        })();
        """
        userContentController.addUserScript(WKUserScript(source: viewportScript,
                                                        injectionTime: .atDocumentStart,
                                                        forMainFrameOnly: true))
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.scrollView.bounces = true
        webView.isOpaque = true
        webView.backgroundColor = Config.backgroundColor
        webView.scrollView.backgroundColor = Config.backgroundColor
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.webView = webView

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.updateProgress(Float(webView.estimatedProgress))
        }

        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    private func configureProgressBar() {
        progressBar.progressTintColor = .white
        progressBar.trackTintColor = .clear
        progressBar.alpha = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    private func configureSplash() {
        splashView.backgroundColor = Config.backgroundColor
        splashView.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "float"
        title.textColor = .white
        title.font = .systemFont(ofSize: 34, weight: .light)
        title.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        splashView.addSubview(title)
        splashView.addSubview(spinner)
        view.addSubview(splashView)

        NSLayoutConstraint.activate([
            splashView.topAnchor.constraint(equalTo: view.topAnchor),
            splashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            title.centerXAnchor.constraint(equalTo: splashView.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: splashView.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: splashView.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24)
        ])
    }

    private func configureErrorView() {
        errorView.backgroundColor = Config.backgroundColor
        errorView.alpha = 0
        errorView.isUserInteractionEnabled = false
        errorView.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.text = "网络未连接\n请检查网络后重试"
        errorLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        errorLabel.font = .systemFont(ofSize: 16, weight: .regular)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let retry = UIButton(type: .system)
        retry.setTitle("重新加载", for: .normal)
        retry.setTitleColor(.white, for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        retry.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        retry.layer.borderWidth = 1
        retry.layer.cornerRadius = 22
        retry.contentEdgeInsets = UIEdgeInsets(top: 10, left: 28, bottom: 10, right: 28)
        retry.addTarget(self, action: #selector(handleRefresh), for: .touchUpInside)
        retry.translatesAutoresizingMaskIntoConstraints = false

        errorView.addSubview(errorLabel)
        errorView.addSubview(retry)
        view.addSubview(errorView)

        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            retry.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            retry.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 28)
        ])
    }

    // MARK: - Loading

    private func loadStartPage() {
        var request = URLRequest(url: Config.startURL)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 30
        webView.load(request)
    }

    @objc private func handleRefresh() {
        hideError()
        if webView.url == nil {
            loadStartPage()
        } else {
            webView.reload()
        }
        webView.scrollView.refreshControl?.endRefreshing()
    }

    private func updateProgress(_ value: Float) {
        progressBar.setProgress(value, animated: true)
        if value >= 1 {
            UIView.animate(withDuration: 0.25) { self.progressBar.alpha = 0 }
        } else {
            progressBar.alpha = 1
        }
    }

    private func hideSplash() {
        guard !didFinishFirstLoad else { return }
        didFinishFirstLoad = true
        setNeedsStatusBarAppearanceUpdate()
        UIView.animate(withDuration: 0.35, animations: {
            self.splashView.alpha = 0
        }, completion: { _ in
            self.splashView.removeFromSuperview()
        })
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorView.isUserInteractionEnabled = true
        UIView.animate(withDuration: 0.25) { self.errorView.alpha = 1 }
    }

    private func hideError() {
        errorView.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.2) { self.errorView.alpha = 0 }
    }

    // MARK: - Navigation policy

    private func isInAppURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return Config.inAppHosts.contains(host)
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

// MARK: - WKNavigationDelegate

extension WebAppViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // Non-web schemes (tel:, mailto:, weixin:, itms-apps:, ...) leave the app.
        if !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            openExternally(url)
            decisionHandler(.cancel)
            return
        }

        // Target=_blank / window.open keeps the same host in-app.
        if navigationAction.targetFrame == nil {
            if isInAppURL(url) {
                webView.load(URLRequest(url: url))
            } else {
                openExternally(url)
            }
            decisionHandler(.cancel)
            return
        }

        // Off-site links open in Safari so the shell never becomes a browser jail.
        if (scheme == "http" || scheme == "https"),
           !isInAppURL(url),
           navigationAction.navigationType == .linkActivated {
            openExternally(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideSplash()
        hideError()
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        hideSplash()
        showError("页面加载失败\n\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        hideSplash()
        let code = (error as NSError).code
        if code == NSURLErrorNotConnectedToInternet || code == NSURLErrorNetworkConnectionLost {
            showError("网络未连接\n请检查网络后重试")
        } else {
            showError("页面加载失败\n\(error.localizedDescription)")
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hideError()
        webView.reload()
    }
}

// MARK: - WKUIDelegate (permissions, JS dialogs, file input)

extension WebAppViewController: WKUIDelegate {

    // Deployment target is iOS 15, so this delegate is always available.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Camera / microphone stay usable because the usage strings are declared in Info.plist.
        // The site actually records audio through getUserMedia, so this must not be denied.
        let host = origin.host.lowercased()
        let trusted = Config.inAppHosts.contains(host) || host.hasSuffix(".netlify.app")
        // `.prompt` would re-enter this delegate for the same origin, so answer definitively.
        decisionHandler(trusted ? .grant : .deny)
    }

    // window.open / target=_blank
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isInAppURL(url) {
                webView.load(URLRequest(url: url))
            } else {
                openExternally(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}

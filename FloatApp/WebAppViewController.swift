import UIKit
import WebKit

/// Native WKWebView shell around https://meou123.netlify.app/
/// Keeps the PWA inside the app, locks portrait, handles camera/mic uploads,
/// opens off-site links in Safari and shows a branded offline screen.
final class WebAppViewController: UIViewController, UIGestureRecognizerDelegate {

    // MARK: - Configuration

    private enum Config {
        static let startURL = URL(string: "https://meou123.netlify.app/")!
        /// Hosts allowed to stay inside the app; everything else opens in Safari.
        static let inAppHosts: Set<String> = ["meou123.netlify.app"]
        /// 站点主题色 #f8f7f2：用它当底色，页面未铺满时才不会露出黑边。
        static let background = UIColor(red: 0xF8 / 255.0, green: 0xF7 / 255.0, blue: 0xF2 / 255.0, alpha: 1)
    }

    // MARK: - Views

    private var webView: WKWebView!
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let splashView = UIView()
    private let errorView = UIView()
    private let errorLabel = UILabel()

    private var progressObservation: NSKeyValueObservation?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var didFinishFirstLoad = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Config.background
        configureWebView()
        configureProgressBar()
        configureSplash()
        configureErrorView()
        registerKeyboardObservers()
        loadStartPage()
    }

    deinit {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        progressObservation?.invalidate()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        // 站点是浅色主题（#f8f7f2），状态栏用深色文字
        .darkContent
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    // MARK: - UIGestureRecognizerDelegate

    /// 让点按收起键盘的手势与网页自身的点击/滚动并存
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// 键盘没弹出来时不需要识别，省掉无谓的 JS 查询
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        webView?.isFirstResponder ?? false
    }

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
        // 只补站点自己没处理的安全区（见 safeAreaCSS）。不覆盖站点原有的 viewport meta：
        // 它已经声明了 viewport-fit=cover，按 cover 模式渲染才能正确撑满刘海与底部横条。
        userContentController.addUserScript(WKUserScript(source: Self.safeAreaCSS,
                                                        injectionTime: .atDocumentEnd,
                                                        forMainFrameOnly: true))
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // .never：安全区交给页面自己用 env(safe-area-inset-*) 处理。
        // 若用 .always，系统会以浏览器方式再加一次顶部留白，与站点的 cover 布局冲突。
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isOpaque = true
        webView.backgroundColor = Config.background
        webView.scrollView.backgroundColor = Config.background
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
        refresh.tintColor = .secondaryLabel
        refresh.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        stripInputAssistantBars()
        installTapToDismissKeyboard()
    }

    // MARK: - 去掉键盘上方的输入助手栏

    /// WKWebView 会在键盘上方插入系统的 inputAssistantItem 栏
    /// （上一个/下一个输入框的箭头 + “完成”按钮）。网页无法控制它，只能清空。
    /// 代价：失去“上一个/下一个”快捷切换；键盘收起改用下拉与点按空白处。
    private func stripInputAssistantBars() {
        if #available(iOS 13.0, *) {
            clearAssistantGroups(everywhereIn: webView)
            clearAssistantGroups(everywhereIn: webView.scrollView)
        }
    }

    private func clearAssistantGroups(everywhereIn view: UIView) {
        // 用 KVC 访问 inputAssistantItem：UIKit 未公开为协议要求，但所有 UIView 都响应
        if let item = view.value(forKey: "inputAssistantItem") as? UITextInputAssistantItem {
            item.leadingBarButtonGroups = []
            item.trailingBarButtonGroups = []
        }
        for sub in view.subviews {
            clearAssistantGroups(everywhereIn: sub)
        }
    }

    /// 安全区兜底：站点若已用 env(safe-area-inset-*) 自行避让，这里什么都不做；
    /// 若没有，则把内容推进安全区，避免标题被灵动岛压住、底部被横条遮挡。
    private static let safeAreaCSS = """
    (function () {
      var d = document, de = d.documentElement;
      var root = getComputedStyle(de);
      var readInset = function (name) {
        var probe = d.createElement('div');
        probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;height:env(' + name + ',0px)';
        de.appendChild(probe);
        var v = parseFloat(getComputedStyle(probe).height) || 0;
        de.removeChild(probe);
        return v;
      };
      var top = readInset('safe-area-inset-top');
      var bottom = readInset('safe-area-inset-bottom');
      var handlesTop = false, handlesBottom = false, el = d.body;
      while (el && el !== de) {
        var cs = getComputedStyle(el);
        var padTop = parseFloat(cs.paddingTop) || 0;
        var padBottom = parseFloat(cs.paddingBottom) || 0;
        var posTop = parseFloat(cs.top) || 0;
        var marginTop = parseFloat(cs.marginTop) || 0;
        if (top > 0 && (padTop >= top - 1 || (cs.position === 'fixed' && posTop >= top - 1) || marginTop >= top - 1)) handlesTop = true;
        if (bottom > 0 && padBottom >= bottom - 1) handlesBottom = true;
        el = el.parentElement;
      }
      var bodyCS = d.body ? getComputedStyle(d.body) : null;
      var bg = (bodyCS && bodyCS.backgroundColor && bodyCS.backgroundColor !== 'rgba(0, 0, 0, 0)')
        ? bodyCS.backgroundColor
        : (root.backgroundColor !== 'rgba(0, 0, 0, 0)' ? root.backgroundColor : '#f8f7f2');
      de.style.background = bg;
      if (!handlesTop && top > 0) de.style.paddingTop = top + 'px';
      if (!handlesBottom && bottom > 0) de.style.paddingBottom = bottom + 'px';
    })();
    """

    /// 页面若把宽度算得超出可视区，锁回 1.0（maximum-scale=1 之外的第二道保险）。
    private func lockZoomScale() {
        guard let scrollView = webView?.scrollView else { return }
        if abs(scrollView.zoomScale - 1) > 0.001 {
            scrollView.setZoomScale(1, animated: false)
        }
        scrollView.contentOffset.x = 0
    }

    private func configureProgressBar() {
        progressBar.progressTintColor = .secondaryLabel
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
        splashView.backgroundColor = Config.background
        splashView.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "float"
        title.textColor = .darkGray
        title.font = .systemFont(ofSize: 34, weight: .light)
        title.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .darkGray
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
        errorView.backgroundColor = Config.background
        errorView.alpha = 0
        errorView.isUserInteractionEnabled = false
        errorView.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.text = "网络未连接\n请检查网络后重试"
        errorLabel.textColor = UIColor.label.withAlphaComponent(0.85)
        errorLabel.font = .systemFont(ofSize: 16, weight: .regular)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let retry = UIButton(type: .system)
        retry.setTitle("重新加载", for: .normal)
        retry.setTitleColor(.label, for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        retry.layer.borderColor = UIColor.label.withAlphaComponent(0.35).cgColor
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

    // MARK: - Keyboard avoidance

    /// 键盘避让：把键盘占掉的高度加进 scrollView 的底部 inset，
    /// 让 WebKit 知道可视区变小并在文档流内滚动焦点元素，
    /// 而不是把整个页面顶上去（原来没有这段逻辑，所以键盘一弹整页上移）。
    private func registerKeyboardObservers() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.keyboardWillChange(note)
            }
            keyboardObservers.append(token)
        }
    }

    private func keyboardWillChange(_ note: Notification) {
        guard let webView else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
            ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

        var inset: CGFloat = 0
        if note.name != UIResponder.keyboardWillHideNotification,
           let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            let keyboardFrame = view.convert(frameValue.cgRectValue, from: nil)
            // 键盘与 webView 的重叠高度
            inset = max(0, webView.frame.maxY - keyboardFrame.minY)
        }

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            webView.scrollView.contentInset.bottom = inset
            webView.scrollView.verticalScrollIndicatorInsets.bottom = inset
        } completion: { _ in
            // WebKit 可能在聚焦时才创建内部视图，这里再清一次输入助手栏
            self.stripInputAssistantBars()
            if inset > 0 {
                // 键盘完全展开后，把正在输入的控件滚进可视区
                webView.evaluateJavaScript("""
                (function () {
                  var el = document.activeElement;
                  if (el && typeof el.scrollIntoView === 'function') {
                    el.scrollIntoView({ block: 'center', behavior: 'smooth' });
                  }
                })();
                """, completionHandler: nil)
            }
        }
    }

    // MARK: - 点按空白处收起键盘

    /// 输入助手栏被移除后，“完成”按钮也没了，所以补一个点击空白收起键盘的手势。
    private func installTapToDismissKeyboard() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        tap.cancelsTouchesInView = false          // 不能吃掉网页自身的点击
        tap.delegate = self
        webView.addGestureRecognizer(tap)
    }

    @objc private func handleBackgroundTap() {
        guard webView.isFirstResponder else { return }
        // 只有当点到的不是可输入元素时才收起键盘
        webView.evaluateJavaScript("""
        (function () {
          var el = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2);
          var active = document.activeElement;
          var editable = active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA' || active.isContentEditable);
          var tappedEditable = el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
          return editable && !tappedEditable;
        })();
        """) { [weak self] result, _ in
            if let shouldDismiss = result as? Bool, shouldDismiss {
                self?.webView.endEditing(true)
            }
        }
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
        // 页面稳定后复位缩放并检查安全区（SPA 内容由 JS 渲染，需要等一拍）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.lockZoomScale()
        }
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

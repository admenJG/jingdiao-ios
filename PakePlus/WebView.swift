//
//  WebView.swift
//  PakePlus
//
//  Created by Song on 2025/3/30.
//

import AVFoundation
import CoreLocation
import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    // wkwebview url
    let webUrl: URL
    // is debug
    let debug: Bool
    // on load finished
    let onLoadFinished: (() -> Void)?
    // userAgent
    let userAgent = Bundle.main.object(forInfoDictionaryKey: "USERAGENT") as? String ?? ""
    // 对外暴露 WKWebView 实例，供原生工具栏调用 goBack / reload / load（默认空绑定，不影响其它调用点）
    var webViewRef: Binding<WKWebView?> = .constant(nil)

    func makeUIView(context: Context) -> WKWebView {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webConfiguration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        webConfiguration.allowsInlineMediaPlayback = true
        webConfiguration.allowsPictureInPictureMediaPlayback = true
        webConfiguration.ignoresViewportScaleLimits = true
        webConfiguration.allowsInlineMediaPlayback = true
        webConfiguration.allowsAirPlayForMediaPlayback = true
        webConfiguration.allowsPictureInPictureMediaPlayback = true
        webConfiguration.selectionGranularity = .character
        // enable developer extras
        if #available(iOS 16.4, *) {
            webConfiguration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        } else {
            webConfiguration.preferences.setValue(true, forKey: "developerExtrasEnabled")
            UserDefaults.standard.set(true, forKey: "WebKitDeveloperExtras")
        }
        // creat wkwebview
        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        // transparent background
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // JS bridge: blob download
        webView.configuration.userContentController.add(context.coordinator, name: "blobDownload")

        // debug script
        if debug, let debugScript = WebView.loadJSFile(named: "vConsole") {
            let fullScript = debugScript + "\nvar vConsole = new window.VConsole();"
            let userScript = WKUserScript(
                source: fullScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(userScript)
            if #available(iOS 16.4, *) {
                webView.isInspectable = true
            }
        }
        // config userAgent
        if !userAgent.isEmpty {
            webView.customUserAgent = userAgent
        }

        // disable double tap zoom
        let script = """
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            document.head.appendChild(meta);
        """
        let scriptInjection = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(scriptInjection)

        // load custom script
        if let customScript = WebView.loadJSFile(named: "custom") {
            let userScript = WKUserScript(
                source: customScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(userScript)
        }

        if webUrl.host?.contains("pakeplus.com") == true {
            // load html file
            if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        } else if webUrl.host?.contains("password.com") == true {
            if let url = Bundle.main.url(forResource: "pppwd", withExtension: "html") {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        } else {
            // load url
            webView.load(URLRequest(url: webUrl))
        }

        // delegate 设置

        // Add gesture recognizers
        let rightSwipeGesture = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRightSwipe(_:)))
        rightSwipeGesture.direction = .right
        webView.addGestureRecognizer(rightSwipeGesture)

        let leftSwipeGesture = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLeftSwipe(_:)))
        leftSwipeGesture.direction = .left
        webView.addGestureRecognizer(leftSwipeGesture)

        context.coordinator.prepareWebGeolocationAuthorization()

        webViewRef.wrappedValue = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // add coordinator to prevent zoom
    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadFinished: onLoadFinished)
    }
}

// swifui coordinator
class Coordinator: NSObject, UIScrollViewDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, CLLocationManagerDelegate {
    private let onLoadFinished: (() -> Void)?
    private var didFinishMainFrameOnce = false
    private var locationManager: CLLocationManager?

    // init
    init(onLoadFinished: (() -> Void)?) {
        self.onLoadFinished = onLoadFinished
        super.init()
    }

    // blob download state
    private struct BlobDownloadState {
        var filename: String
        var mimeType: String
        var totalChunks: Int
        var receivedChunkIndexes: Set<Int>
        var buffer: Data
    }

    // blob downloads
    private var blobDownloads: [String: BlobDownloadState] = [:]

    // disable zoom
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        // disable zoom
        return nil
    }

    // Handle right swipe gesture
    @objc func handleRightSwipe(_ gesture: UISwipeGestureRecognizer) {
        if let webView = gesture.view as? WKWebView, webView.canGoBack {
            webView.goBack()
        }
    }

    // Handle left swipe gesture
    @objc func handleLeftSwipe(_ gesture: UISwipeGestureRecognizer) {
        if let webView = gesture.view as? WKWebView, webView.canGoForward {
            webView.goForward()
        }
    }

    // MARK: - WKNavigationDelegate

    // intercept navigation, recognize common file types and trigger download
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // handle special schemes (tel/mailto/sms/etc.) by handing off to system.
        // Note: some pages trigger these via JS (location.href/window.open), which becomes `.other` instead of `.linkActivated`.
        if let scheme = url.scheme?.lowercased(),
           isExternalAppScheme(scheme)
        {
            decisionHandler(.cancel)
            openExternalURL(url)
            return
        }

        // AList / 图库 的「下载」可能是 <a> 点击，也可能由 JS(location.href / window.open) 触发，
        // 后者 navigationType 是 .other，只认 .linkActivated 会静默失效（点了完全没反应）。
        // 只对主框架导航拦截，iframe / 子资源不受影响。
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, shouldDownload(url: url) {
            decisionHandler(.cancel)
            downloadFile(from: url, in: webView)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // only respond to main frame, and only trigger once, avoid iframe / multiple redirects causing repeated hiding
        guard !didFinishMainFrameOnce else { return }
        didFinishMainFrameOnce = true

        DispatchQueue.main.async { [onLoadFinished] in
            onLoadFinished?()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // provisional failure = initial connection failed (DNS / no network / blocked)
        guard !didFinishMainFrameOnce else { return }
        didFinishMainFrameOnce = true
        print("PakePlus provisional load failed: \(error.localizedDescription)")
        showLoadError(on: webView, message: error.localizedDescription)
        DispatchQueue.main.async { [onLoadFinished] in
            onLoadFinished?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // avoid certain loading failures causing it to stay on the launch screen/loading
        guard !didFinishMainFrameOnce else { return }
        didFinishMainFrameOnce = true
        print("PakePlus load failed: \(error.localizedDescription)")
        showLoadError(on: webView, message: error.localizedDescription)
        DispatchQueue.main.async { [onLoadFinished] in
            onLoadFinished?()
        }
    }

    /// show readable error on screen instead of blank white
    private func showLoadError(on view: UIView, message: String) {
        DispatchQueue.main.async {
            let label = UILabel()
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .label
            label.backgroundColor = .systemBackground
            label.font = .systemFont(ofSize: 15, weight: .medium)
            let clean = message.replacingOccurrences(of: "file://", with: "")
            // 图库首页地址以 scripts/ppconfig.json 的 ios.webUrl 为准；
            // 换域名时这里必须同步，否则报错页会把人指向一个已经不用的旧域名。
            label.text = "⚠️ 页面加载失败\n\n\(clean)\n\n请确认手机能访问\nhttps://tk.715881989.xyz"
            label.frame = view.bounds
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(label)
        }
    }

    // MARK: - WKUIDelegate: system vs web permissions

    // target="_blank" / window.open：WKUIDelegate 默认返回 nil 会被静默忽略，
    // AList 的「下载」按钮点了完全没反应多半就卡在这里。
    // 改成在当前 WebView 里加载，再交给 decidePolicyFor 统一拦截下载。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil || !(navigationAction.targetFrame?.isMainFrame ?? false) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// 摄像头 / 麦克风：系统层已授权则直接 `.grant`（不再出现网页内二次权限面板）；系统已拒绝或受限则 `.deny`；尚未决定则 `.prompt`。
    /// 网页地理定位 `navigator.geolocation`：公开 `WKUIDelegate` 无对应决策方法，无法像媒体这样 `.grant`；仅能通过 `NSLocationWhenInUseUsageDescription` 与 `prepareWebGeolocationAuthorization()` 尽早完成系统层授权。
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void)
    {
        decisionHandler(permissionDecisionForMediaCapture(type: type))
    }

    @available(iOS 15.0, *)
    private func permissionDecisionForMediaCapture(type: WKMediaCaptureType) -> WKPermissionDecision {
        let video = AVCaptureDevice.authorizationStatus(for: .video)
        let audio = AVCaptureDevice.authorizationStatus(for: .audio)

        let authorized: Bool
        let deniedOrRestricted: Bool
        switch type {
        case .camera:
            authorized = video == .authorized
            deniedOrRestricted = video == .denied || video == .restricted
        case .microphone:
            authorized = audio == .authorized
            deniedOrRestricted = audio == .denied || audio == .restricted
        case .cameraAndMicrophone:
            authorized = video == .authorized && audio == .authorized
            deniedOrRestricted = video == .denied || video == .restricted || audio == .denied || audio == .restricted
        @unknown default:
            return .prompt
        }

        if authorized { return .grant }
        if deniedOrRestricted { return .deny }
        return .prompt
    }

    /// 在宿主侧请求「使用期间」定位授权，供 WKWebView 内 Geolocation API 使用（需配合 `NSLocationWhenInUseUsageDescription`）。
    func prepareWebGeolocationAuthorization() {
        guard locationManager == nil else { return }
        let manager = CLLocationManager()
        manager.delegate = self
        locationManager = manager
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    // MARK: - WKScriptMessageHandler (blob download bridge)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "blobDownload" else { return }
        guard let body = message.body as? [String: Any] else { return }

        let action = (body["action"] as? String) ?? ""
        let id = (body["id"] as? String) ?? ""
        if id.isEmpty { return }

        switch action {
        case "start":
            let filename = sanitizeFilename((body["filename"] as? String) ?? "download")
            let mimeType = (body["mimeType"] as? String) ?? ""
            let totalChunks = max(1, (body["totalChunks"] as? Int) ?? 1)
            blobDownloads[id] = BlobDownloadState(
                filename: filename,
                mimeType: mimeType,
                totalChunks: totalChunks,
                receivedChunkIndexes: [],
                buffer: Data()
            )
            showHint("开始下载…")

        case "chunk":
            guard var state = blobDownloads[id] else { return }
            guard let index = body["index"] as? Int else { return }
            guard let base64 = body["data"] as? String else { return }

            // prevent duplicate chunk
            if state.receivedChunkIndexes.contains(index) { return }
            guard let chunkData = Data(base64Encoded: base64) else { return }

            state.buffer.append(chunkData)
            state.receivedChunkIndexes.insert(index)
            blobDownloads[id] = state

        case "finish":
            guard let state = blobDownloads[id] else { return }
            blobDownloads.removeValue(forKey: id)

            // only save when all chunks are received
            guard state.receivedChunkIndexes.count >= state.totalChunks else { return }
            saveAndShareBlobData(state.buffer, filename: state.filename)

        case "error":
            blobDownloads.removeValue(forKey: id)
            if let msg = body["message"] as? String, !msg.isEmpty {
                print("blob download failed: \(msg)")
            }

        default:
            return
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "download" }
        // remove path separator, avoid writing file exception
        return trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func saveAndShareBlobData(_ data: Data, filename: String) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent(filename)

        try? fileManager.removeItem(at: destinationURL)
        do {
            try data.write(to: destinationURL, options: [.atomic])
        } catch {
            print("save blob file failed: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.presentShareSheet(for: destinationURL)
        }
    }

    /// check if url is a common file type that needs to be downloaded
    private func shouldDownload(url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension.isEmpty {
            return false
        }

        let downloadableExtensions: Set<String> = [
            // 图片
            "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic",
            "tif", "tiff", "svg", "ico", "psd", "ai", "eps",
            // 视频
            "mp4", "mov", "m4v", "avi", "mkv",
            // 音频
            "mp3", "wav", "aac", "m4a", "flac",
            // 文本/文档
            "txt", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            "csv", "json", "xml", "md", "epub",
            // 压缩
            "zip", "rar", "7z", "gz", "tar", "bz2", "xz", "iso",
            // 精雕 / 3D / CAD（主公业务格式，原来漏了 .vs3d 导致点下载无反应）
            "vs3d", "vsm", "jdp", "jdw", "stl", "obj", "glb", "gltf", "ply",
            "3ds", "fbx", "3mf", "dxf", "dwg", "stp", "step", "iges", "igs",
            "vsd", "vsdx", "sat", "sldprt",
            // 安装包 / 其他
            "apk", "ipa", "exe", "msi", "dmg", "bin", "dat", "torrent"
        ]

        return downloadableExtensions.contains(pathExtension)
    }

    private func isExternalAppScheme(_ scheme: String) -> Bool {
        switch scheme {
        case "tel", "mailto", "sms", "facetime", "facetime-audio":
            return true
        default:
            return false
        }
    }

    private func openExternalURL(_ url: URL) {
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    /// 使用 URLSession 下载文件并弹出系统分享面板，让用户保存到「文件」或其他 App
    private func downloadFile(from url: URL, in webView: WKWebView) {
        print("start downloading file: \(url.absoluteString)")
        showHint("开始下载…")

        // 图库 / E盘 / 工作区 的文件直链要带 tk_session 登录 cookie 才放行。
        // WKWebView 的 cookie 在 WKHTTPCookieStore，URLSession.shared 用的是
        // NSHTTPCookieStorage，两者不保证互通；不显式搬一次，点 .vs3d 下载到的
        // 会是 403 或登录页 HTML（文件名对、内容是废的）。
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            var request = URLRequest(url: url)
            // Cloudflare 浏览器完整性检查会拦 CFNetwork 默认 UA（error code 1010）
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 900

            let host = url.host?.lowercased() ?? ""
            let pairs = cookies.filter { c in
                let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return !d.isEmpty && (host == d || host.hasSuffix("." + d))
            }.map { "\($0.name)=\($0.value)" }
            if !pairs.isEmpty {
                request.setValue(pairs.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            }
            cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }

            let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
                if let error = error {
                    print("download failed: \(error.localizedDescription)")
                    self?.showHint("下载失败: \(error.localizedDescription)", ok: false)
                    return
                }

                // 别把 403 / 登录页 / CF 拦截页当文件存下来
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    self?.showHint("下载失败: HTTP \(http.statusCode)，请在 App 内重新登录", ok: false)
                    return
                }
                if let mime = response?.mimeType?.lowercased(), mime.contains("text/html") {
                    self?.showHint("下载失败: 返回的是网页，请在 App 内重新登录", ok: false)
                    return
                }

                guard let tempURL = tempURL else {
                    print("download failed: temporary file not found")
                    self?.showHint("下载失败: 未取到临时文件", ok: false)
                    return
                }

                // 优先用原始链接里的中文文件名（AList /d/ 路径），避免天翼 302 之后
                // 落到 UUID.vs3d，或 Content-Disposition 里的乱码名。
                let originalName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                let suggestedName = (response as? HTTPURLResponse)?
                    .allHeaderFields["Content-Disposition"] as? String

                let fileName: String
                if !originalName.isEmpty && originalName.lowercased() != "d" {
                    fileName = originalName
                } else if let suggestedName,
                          let range = suggestedName.range(of: "filename=")
                {
                    let namePart = String(suggestedName[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
                    fileName = namePart.isEmpty ? "file" : namePart
                } else {
                    fileName = "file"
                }

                let fileManager = FileManager.default
                let tempDir = fileManager.temporaryDirectory
                let destinationURL = tempDir.appendingPathComponent(fileName)

                // if file already exists, remove it
                try? fileManager.removeItem(at: destinationURL)

                do {
                    try fileManager.moveItem(at: tempURL, to: destinationURL)
                } catch {
                    print("failed to move download file: \(error.localizedDescription)")
                    return
                }

                print("download finished, temporary save path: \(destinationURL.path)")

                DispatchQueue.main.async {
                    self?.presentShareSheet(for: destinationURL)
                }
            }

            task.resume()
        }
    }

    /// show a short on-screen hint (disappears after 2-3 seconds)
    private func showHint(_ text: String, ok: Bool = true) {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) else { return }

            let label = UILabel()
            label.text = text
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textColor = .white
            label.backgroundColor = ok ? .systemBlue : .systemRed
            label.textAlignment = .center
            label.layer.cornerRadius = 8
            label.clipsToBounds = true
            label.alpha = 0

            let padding: CGFloat = 16
            let topMargin: CGFloat = 20
            label.sizeToFit()
            label.frame.size.width += padding * 2
            label.frame.size.height += padding
            let yCenter = window.safeAreaInsets.top + label.frame.height / 2 + topMargin
            label.center = CGPoint(x: window.bounds.midX, y: yCenter)

            window.addSubview(label)

            UIView.animate(withDuration: 0.25, animations: { label.alpha = 1 })
            UIView.animate(withDuration: 0.25, delay: ok ? 1.75 : 2.75, options: [], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    // present system share sheet, user can choose to save to "file" or share to other apps
    private func presentShareSheet(for fileURL: URL) {
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activityVC.popoverPresentationController?.sourceView = UIApplication.shared.windows.first { $0.isKeyWindow }

        if let topVC = Coordinator.topViewController() {
            topVC.present(activityVC, animated: true, completion: nil)
        } else {
            print("top view controller not found, cannot show share sheet")
        }
    }

    // get current top view controller
    private static func topViewController(base: UIViewController? = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first(where: { $0.isKeyWindow })?.rootViewController) -> UIViewController?
    {
        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}

extension WebView {
    // load js file from bundle
    static func loadJSFile(named filename: String) -> String? {
        guard let path = Bundle.main.path(forResource: filename, ofType: "js") else {
            print("Could not find \(filename).js in bundle")
            return nil
        }

        do {
            let jsString = try String(contentsOfFile: path, encoding: .utf8)
            return jsString
        } catch {
            print("Error loading \(filename).js: \(error)")
            return nil
        }
    }
}

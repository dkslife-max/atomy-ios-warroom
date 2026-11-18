import SwiftUI
import WebKit

struct WarRoomContainerView: View {
    @ObservedObject var engine: AtomySyncEngine
    var onBackToSync: () -> Void

    var body: some View {
        WarRoomWebViewRepresentable(engine: engine, onOpenUpdate: onBackToSync)
            .ignoresSafeArea(edges: .bottom)
    }
}

final class AtomyAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let engine: AtomySyncEngine

    init(engine: AtomySyncEngine) {
        self.engine = engine
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        let accountDir = engine.accountDirectory(for: engine.activeAccount)

        if path.hasPrefix("/data/") {
            let fileName = String(path.dropFirst("/data/".count))
            let fileUrl = accountDir.appendingPathComponent(fileName)
            let data = (try? Data(contentsOf: fileUrl)) ?? Data("{}".utf8)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }

        let cleanPath = path.replacingOccurrences(of: "/assets/pwa/", with: "")
        let resourceName = cleanPath.isEmpty ? "index.html" : cleanPath
        if let bundleUrl = Bundle.main.url(forResource: resourceName, withExtension: nil, subdirectory: "Assets/pwa") ??
                           Bundle.main.url(forResource: resourceName, withExtension: nil),
           let data = try? Data(contentsOf: bundleUrl) {
            let mime: String = {
                if resourceName.hasSuffix(".html") { return "text/html; charset=utf-8" }
                if resourceName.hasSuffix(".js") { return "application/javascript; charset=utf-8" }
                if resourceName.hasSuffix(".css") { return "text/css; charset=utf-8" }
                if resourceName.hasSuffix(".webmanifest") { return "application/manifest+json; charset=utf-8" }
                if resourceName.hasSuffix(".png") { return "image/png" }
                return "application/octet-stream"
            }()
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mime, "Cache-Control": "no-store"]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data("Not Found".utf8))
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

struct WarRoomWebViewRepresentable: UIViewRepresentable {
    let engine: AtomySyncEngine
    let onOpenUpdate: () -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onOpenUpdate: () -> Void
        init(onOpenUpdate: @escaping () -> Void) {
            self.onOpenUpdate = onOpenUpdate
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "AtomyApp" {
                DispatchQueue.main.async { self.onOpenUpdate() }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if url.scheme == "tel" || url.host?.contains("line.me") == true {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenUpdate: onOpenUpdate)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AtomyAssetSchemeHandler(engine: engine), forURLScheme: "atomyapp")
        let bridgeJs = """
        window.AtomyApp = {
            openUpdate: function() {
                window.webkit.messageHandlers.AtomyApp.postMessage('openUpdate');
            }
        };
        """
        config.userContentController.addUserScript(WKUserScript(source: bridgeJs, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(context.coordinator, name: "AtomyApp")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        let acc = engine.activeAccount.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let startUrl = URL(string: "atomyapp://appassets.androidplatform.net/assets/pwa/index.html?native=1&account=\(acc)")!
        wv.load(URLRequest(url: startUrl))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

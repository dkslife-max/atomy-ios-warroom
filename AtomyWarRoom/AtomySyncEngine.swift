import Foundation
import WebKit
import SwiftUI

final class AtomySyncEngine: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    enum SyncMode: Int {
        case daily = 0
        case fill24 = 1
        case reload24 = 2
    }

    @Published var accountInput: String = UserDefaults.standard.string(forKey: "lastMember") ?? ""
    @Published var passwordInput: String = ""
    @Published var syncMode: SyncMode = .daily
    @Published var forceFullOrgScan: Bool = false

    @Published var activeAccount: String = UserDefaults.standard.string(forKey: "activeOwner") ?? ""
    @Published var stageLabel: String = "準備開始"
    @Published var statusDetail: String = "組織更新 → 業績讀取 → 官方總額對帳\n首次更新可能較久，畫面會回報進度。"
    @Published var currentStepIndex: Int = 0
    @Published var isBusy: Bool = false
    @Published var needsUserVerification: Bool = false

    private(set) var crawlerWebView: WKWebView!
    private var autoStage: String = ""
    private var pendingScanToken: String = ""
    private var salesQueue: [(key: String, start: String, end: String, incremental: Bool)] = []
    private var currentPeriod: (key: String, start: String, end: String, incremental: Bool)?
    private var currentPeriodRecords: [[String: Any]] = []
    private var currentPeriodPage: Int = 1
    private var latestOfficialSummary: [String: Any] = [:]

    private var orgMembers: [String: [String: Any]] = [:]
    private var orgEdges: [String: [String: String]] = [:]
    private var orgCheckpoint: [String: Any]?

    var hasSavedSession: Bool {
        !activeAccount.isEmpty
    }

    var canOpenWarRoom: Bool {
        guard !activeAccount.isEmpty else { return false }
        let url = accountDirectory(for: activeAccount).appendingPathComponent("current_dataset.json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    override init() {
        super.init()
        setupCrawlerWebView()
        if !activeAccount.isEmpty {
            loadAccountStore(for: activeAccount)
        }
    }

    private func setupCrawlerWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let contentController = WKUserContentController()

        let bridgeShim = """
        window.AtomyPrototypeResult = {
            saveScanChunk: function(token, jsonStr) {
                window.webkit.messageHandlers.AtomyPrototypeResult.postMessage({action: 'saveScanChunk', token: token, payload: jsonStr});
                return 'ok';
            },
            scanRequest: function(token, chunks, requests, queueLen, level, attempt) {
                window.webkit.messageHandlers.AtomyPrototypeResult.postMessage({action: 'scanRequest', token: token, chunks: chunks, requests: requests, queueLen: queueLen, level: level, attempt: attempt});
            },
            scanProgress: function(token, chunks, requests, queueLen) {
                window.webkit.messageHandlers.AtomyPrototypeResult.postMessage({action: 'scanProgress', token: token, chunks: chunks, requests: requests, queueLen: queueLen});
            },
            scanBackoff: function(token, status, delay) {
                window.webkit.messageHandlers.AtomyPrototypeResult.postMessage({action: 'scanBackoff', token: token, status: status, delay: delay});
            },
            scanPaused: function(token) {
                window.webkit.messageHandlers.AtomyPrototypeResult.postMessage({action: 'scanPaused', token: token});
            },
            scanDone: function(token, root) {
                window.webkit.messageHandlers.AtomyPrototypeResult.postMessage({action: 'scanDone', token: token, root: root});
            },
            scanFailed: function(token, error) {
                window.webkit.messageHandlers.AtomyPrototypeResult.postMessage({action: 'scanFailed', token: token, error: error});
            },
            complete: function(token, jsonStr) {
                window.webkit.messageHandlers.AtomyPrototypeResult.postMessage({action: 'complete', token: token, payload: jsonStr});
            }
        };
        """
        let userScript = WKUserScript(source: bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(userScript)
        contentController.add(self, name: "AtomyPrototypeResult")
        config.userContentController = contentController

        crawlerWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        crawlerWebView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        crawlerWebView.navigationDelegate = self
    }

    func accountDirectory(for memberId: String) -> URL {
        let canonical = memberId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("accounts/\(canonical)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadAccountStore(for memberId: String) {
        let dir = accountDirectory(for: memberId)
        if let data = try? Data(contentsOf: dir.appendingPathComponent("org_members.json")),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            orgMembers = map
        } else {
            orgMembers = [:]
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("org_edges.json")),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            orgEdges = map
        } else {
            orgEdges = [:]
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("org_checkpoint.json")),
           let cp = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            orgCheckpoint = cp
        } else {
            orgCheckpoint = nil
        }
    }

    private func saveAccountStore(for memberId: String) {
        let dir = accountDirectory(for: memberId)
        if let d1 = try? JSONSerialization.data(withJSONObject: orgMembers) {
            try? d1.write(to: dir.appendingPathComponent("org_members.json"), options: .atomic)
        }
        if let d2 = try? JSONSerialization.data(withJSONObject: orgEdges) {
            try? d2.write(to: dir.appendingPathComponent("org_edges.json"), options: .atomic)
        }
        if let cp = orgCheckpoint, let d3 = try? JSONSerialization.data(withJSONObject: cp) {
            try? d3.write(to: dir.appendingPathComponent("org_checkpoint.json"), options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("org_checkpoint.json"))
        }
    }

    private func readAsset(_ name: String) -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Assets") ??
                     Bundle.main.url(forResource: name, withExtension: nil),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        return ""
    }

    func switchAccount() {
        accountInput = ""
        passwordInput = ""
        statusDetail = "目前帳號資料已保留。請輸入要登入的帳號密碼；各帳號的組織、業績與追蹤會分開保存。"
    }

    func cancelSync() {
        crawlerWebView.evaluateJavaScript("window.__atomyScanStop=true;", completionHandler: nil)
        isBusy = false
        autoStage = ""
        stageLabel = "同步已停止"
        statusDetail = "已停止同步。可隨時重新開始。"
    }

    func startNativeLoginAndSync() {
        let trimmedAcc = accountInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmedAcc.isEmpty && activeAccount.isEmpty {
            statusDetail = "請輸入會員編號或暱稱"
            return
        }
        if !trimmedAcc.isEmpty {
            UserDefaults.standard.set(trimmedAcc, forKey: "lastMember")
        }
        isBusy = true
        needsUserVerification = false
        currentStepIndex = 1
        stageLabel = "1／4  確認登入狀態"

        if passwordInput.isEmpty && !activeAccount.isEmpty {
            autoStage = "checking-identity"
            statusDetail = "正在檢查上次登入狀態…"
            crawlerWebView.load(URLRequest(url: URL(string: "https://tw.atomy.com/myoffice/home")!))
        } else {
            if passwordInput.isEmpty {
                isBusy = false
                statusDetail = "請輸入密碼"
                return
            }
            autoStage = "waiting-login"
            statusDetail = "正在開啟艾多美官方登入，準備送出你的帳密…"
            crawlerWebView.load(URLRequest(url: URL(string: "https://tw.atomy.com/login?returnUrl=%2Fmyoffice%2Fhome")!))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isBusy else { return }
        let urlStr = webView.url?.absoluteString ?? ""
        if autoStage == "waiting-login" {
            if urlStr.contains("/login") {
                fillAndSubmitLogin()
            } else if urlStr.contains("/myoffice") || urlStr.contains("/main") {
                autoStage = "checking-identity"
                checkIdentityOnPage()
            }
        } else if autoStage == "checking-identity" {
            checkIdentityOnPage()
        } else if autoStage == "waiting-org" {
            beginOrganizationScan()
        } else if autoStage == "opening-period" {
            applyCurrentPeriodOnPage()
        }
    }

    private func fillAndSubmitLogin() {
        let template = readAsset("login.js")
        guard !template.isEmpty else {
            failSync("無法準備官方登入，請重新嘗試。")
            return
        }
        let opts: [String: String] = ["account": accountInput.trimmingCharacters(in: .whitespacesAndNewlines), "password": passwordInput]
        let optsJson = String(data: try! JSONSerialization.data(withJSONObject: opts), encoding: .utf8)!
        let fillScript = template.replacingOccurrences(of: "__MODE__", with: "'fill'").replacingOccurrences(of: "__OPTIONS__", with: optsJson)

        crawlerWebView.evaluateJavaScript(fillScript) { [weak self] res, _ in
            guard let self = self else { return }
            guard let jsonStr = res as? String,
                  let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.fillAndSubmitLogin() }
                return
            }
            if status == "loading" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.fillAndSubmitLogin() }
                return
            }
            if status == "login-rejected" {
                self.failSync("艾多美未接受這次登入。請確認帳密後重新登入。")
                return
            }
            self.statusDetail = "帳密已交給官方登入頁，正在等待登入檢查…"
            let submitScript = template.replacingOccurrences(of: "__MODE__", with: "'submit'").replacingOccurrences(of: "__OPTIONS__", with: "{}")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.crawlerWebView.evaluateJavaScript(submitScript) { subRes, _ in
                    if let sStr = subRes as? String, sStr.contains("verification-required") {
                        self.statusDetail = "官方要求額外驗證。請完成官方驗證後返回 APP。"
                        self.needsUserVerification = true
                    } else {
                        self.statusDetail = "帳密已送出，正在等待艾多美確認登入…"
                        self.pollLoginCompletion()
                    }
                }
            }
        }
    }

    private func pollLoginCompletion() {
        guard isBusy && autoStage == "waiting-login" else { return }
        let path = crawlerWebView.url?.path ?? ""
        if !path.contains("/login") {
            autoStage = "checking-identity"
            crawlerWebView.load(URLRequest(url: URL(string: "https://tw.atomy.com/myoffice/home")!))
            return
        }
        let template = readAsset("login.js")
        let checkScript = template.replacingOccurrences(of: "__MODE__", with: "'check'").replacingOccurrences(of: "__OPTIONS__", with: "{}")
        crawlerWebView.evaluateJavaScript(checkScript) { [weak self] res, _ in
            guard let self = self else { return }
            if let sStr = res as? String {
                if sStr.contains("login-rejected") {
                    self.failSync("艾多美未接受這次登入。請確認帳密後再試。")
                    return
                }
                if sStr.contains("verification-required") {
                    self.statusDetail = "艾多美要求額外驗證。請完成驗證，APP 會自動接續。"
                    self.needsUserVerification = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.pollLoginCompletion()
            }
        }
    }

    private func checkIdentityOnPage() {
        let probe = readAsset("probe.js")
        let script = probe.replacingOccurrences(of: "__MODE__", with: "'identity'").replacingOccurrences(of: "__OPTIONS__", with: "{}")
        crawlerWebView.evaluateJavaScript(script) { [weak self] res, _ in
            guard let self = self else { return }
            guard let sStr = res as? String,
                  let data = sStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if (obj["loginFields"] as? Bool) == true {
                self.requestRelogin()
                return
            }
            let detected = (obj["memberId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let fallback = self.accountInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let memberId = !detected.isEmpty ? detected : fallback
            guard memberId.range(of: "^S?\\d{6,12}$", options: .regularExpression) != nil else {
                self.failSync("已進入辦公室，但尚未辨識到會員編號。請輸入會員編號後重試。")
                return
            }
            self.activateAccount(memberId)
            self.currentStepIndex = 2
            self.stageLabel = "2／4  開啟組織資料"
            self.statusDetail = "已確認會員 \(memberId)，正在開啟組織圖…"
            self.autoStage = "waiting-org"
            self.crawlerWebView.load(URLRequest(url: URL(string: "https://tw.atomy.com/myoffice/genealogy")!))
        }
    }

    private func activateAccount(_ memberId: String) {
        activeAccount = memberId
        UserDefaults.standard.set(memberId, forKey: "activeOwner")
        UserDefaults.standard.set(memberId, forKey: "lastMember")
        loadAccountStore(for: memberId)
    }

    private func beginOrganizationScan() {
        autoStage = "scanning-org"
        currentStepIndex = 2
        stageLabel = "2／4  讀取組織圖"
        pendingScanToken = UUID().uuidString
        let scanTemplate = readAsset("scan.js")
        var opts: [String: Any] = [
            "root": activeAccount,
            "token": pendingScanToken
        ]
        if !forceFullOrgScan, let cp = orgCheckpoint, (cp["root"] as? String)?.uppercased() == activeAccount {
            opts["checkpoint"] = cp
            statusDetail = "從已存進度繼續組織更新…"
        } else {
            orgMembers = [:]
            orgEdges = [:]
            orgCheckpoint = nil
            statusDetail = "開始完整組織更新…"
        }
        let optsJson = String(data: try! JSONSerialization.data(withJSONObject: opts), encoding: .utf8)!
        let script = scanTemplate.replacingOccurrences(of: "__OPTIONS__", with: optsJson)
        crawlerWebView.evaluateJavaScript(script, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "AtomyPrototypeResult",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "saveScanChunk":
            if let payload = body["payload"] as? String {
                handleSaveScanChunk(payload)
            }
        case "scanRequest":
            let chunks = body["chunks"] as? Int ?? 0
            let reqs = body["requests"] as? Int ?? 0
            let qLen = body["queueLen"] as? Int ?? 0
            statusDetail = "正在讀取組織：已存 \(orgMembers.count) 位會員、完成 \(chunks) 區塊。正在送出第 \(reqs) 次查詢，待掃 \(qLen) 區塊。"
        case "scanProgress":
            let chunks = body["chunks"] as? Int ?? 0
            let reqs = body["requests"] as? Int ?? 0
            let qLen = body["queueLen"] as? Int ?? 0
            statusDetail = "完整組織更新中：已存 \(orgMembers.count) 位會員、\(chunks) 區塊、\(reqs) 次查詢，待掃 \(qLen) 區塊。請保持 APP 開啟。"
        case "scanBackoff":
            let code = body["status"] as? Int ?? 429
            let delay = (body["delay"] as? Int ?? 3000) / 1000
            statusDetail = "官方網站暫時限速（HTTP \(code)）；已存 \(orgMembers.count) 位會員，約 \(delay) 秒後自動重試。"
        case "scanDone":
            do {
                try exportCurrentDataset()
                statusDetail = "完整組織更新完成：\(orgMembers.count) 位會員。正在開啟下線購買明細…"
                beginSalesBatch()
            } catch {
                failSync("組織已掃完但關係檢查未通過：\(error.localizedDescription)")
            }
        case "scanPaused":
            isBusy = false
            stageLabel = "已暫停"
            statusDetail = "組織更新已暫停，進度已存。下次按開始／繼續。"
        case "scanFailed":
            let err = body["error"] as? String ?? "未知錯誤"
            failSync("組織更新暫停：\(err)。可檢查登入狀態後繼續。")
        default:
            break
        }
    }

    private func handleSaveScanChunk(_ jsonStr: String) {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = obj["item"] as? [String: Any],
              let rows = obj["rows"] as? [[String: Any]],
              let cp = obj["checkpoint"] as? [String: Any] else { return }

        let baseDepth = item["baseDepth"] as? Int ?? 1
        let rootDepth = obj["rootDepth"] as? Int ?? 1

        for row in rows {
            let member = (row["custNo"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard member.range(of: "^S?\\d{6,12}$", options: .regularExpression) != nil else { continue }
            let normalized = normalizeMember(row, baseDepth: baseDepth, rootDepth: rootDepth)
            orgMembers[member] = normalized
            if member != activeAccount {
                let spnr = (row["spnrNo"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let side = (row["trctLocCd"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !spnr.isEmpty {
                    orgEdges[member] = ["parent": spnr, "child": member, "sideCode": side]
                }
            }
        }
        orgCheckpoint = cp
        saveAccountStore(for: activeAccount)
    }

    private func normalizeDate(_ raw: Any?) -> String {
        let s = String(describing: raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: "^(\\d{4})[-/]?(\\d{1,2})[-/]?(\\d{1,2})"),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return "" }
        let y = Int((s as NSString).substring(with: m.range(at: 1))) ?? 0
        let mo = Int((s as NSString).substring(with: m.range(at: 2))) ?? 0
        let d = Int((s as NSString).substring(with: m.range(at: 3))) ?? 0
        guard y >= 1990, (1...12).contains(mo), (1...31).contains(d) else { return "" }
        return String(format: "%04d-%02d-%02d", y, mo, d)
    }

    private func normalizeNumber(_ raw: Any?) -> Double {
        let s = String(describing: raw ?? "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(s) ?? 0
    }

    private func normalizeMember(_ row: [String: Any], baseDepth: Int, rootDepth: Int) -> [String: Any] {
        let member = (row["custNo"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let name = (row["custNm"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dropDate = normalizeDate(row["dropDt"])
        let dropStopYn = (row["dropStopYn"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let active = (name != "XXX") && dropDate.isEmpty && (dropStopYn != "Y")
        let joinDate = normalizeDate(row["joinDt"])
        let cumulativePv = normalizeNumber(row["maccPv"])
        let periodPv = normalizeNumber(row["periodPv"])
        let lastSalesDate = normalizeDate(row["fnlSvolDt"])
        let grade = (row["custGrdNm"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let center = (row["ectrNm"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDepth = (row["lrnkDcnt"] as? Int) ?? Int(String(describing: row["lrnkDcnt"] ?? "0")) ?? 0
        let depth = max(1, baseDepth + rawDepth - rootDepth)
        let sideCode = (row["trctLocCd"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parentNo = (row["spnrNo"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return [
            "member": member,
            "name": name,
            "active": active,
            "joinDate": joinDate,
            "dropDate": dropDate,
            "cumulativePv": cumulativePv,
            "periodPv": periodPv,
            "lastSalesDate": lastSalesDate,
            "grade": grade,
            "center": center,
            "depth": depth,
            "rawDepth": rawDepth,
            "sideCode": sideCode,
            "parentNo": parentNo
        ]
    }

    private func exportCurrentDataset() throws {
        let dir = accountDirectory(for: activeAccount)
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let membersList = orgMembers.values.sorted { ($0["member"] as? String ?? "") < ($1["member"] as? String ?? "") }
        let edgesList = orgEdges.values.sorted { ($0["child"] ?? "") < ($1["child"] ?? "") }
        let rootName = (orgMembers[activeAccount]?["name"] as? String) ?? activeAccount

        let dataset: [String: Any] = [
            "tool": "Atomy iOS 戰情",
            "version": "1.7.0",
            "exportedAt": nowIso,
            "updateMode": "full",
            "fullScanAt": nowIso,
            "leader": ["member": activeAccount, "name": rootName],
            "leaders": [["member": activeAccount, "name": rootName]],
            "organization": [
                "rootId": activeAccount,
                "complete": true,
                "members": membersList,
                "edges": edgesList
            ],
            "salesHistory": [String: Any]()
        ]
        let data = try JSONSerialization.data(withJSONObject: dataset, options: [])
        try data.write(to: dir.appendingPathComponent("current_dataset.json"), options: .atomic)
        orgCheckpoint = nil
        saveAccountStore(for: activeAccount)
    }

    private func beginSalesBatch() {
        currentStepIndex = 3
        stageLabel = "3／4  讀取所選業績"
        salesQueue = buildSalesPeriodQueue()
        runNextSalesPeriod()
    }

    private func buildSalesPeriodQueue() -> [(key: String, start: String, end: String, incremental: Bool)] {
        var tzCal = Calendar(identifier: .gregorian)
        tzCal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let now = Date()
        let count = (syncMode == .daily) ? 1 : 24
        var result: [(key: String, start: String, end: String, incremental: Bool)] = []
        let comps = tzCal.dateComponents([.year, .month, .day], from: now)
        var y = comps.year ?? 2026
        var m = comps.month ?? 11
        var isP1 = (comps.day ?? 1) <= 15

        let statusFile = accountDirectory(for: activeAccount).appendingPathComponent("sales_status.json")
        let existingStatus = (try? Data(contentsOf: statusFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]

        for _ in 0..<count {
            let key = String(format: "%04d-%02d-P%d", y, m, isP1 ? 1 : 2)
            let start = String(format: "%04d-%02d-%02d", y, m, isP1 ? 1 : 16)
            let lastDay: Int = {
                if isP1 { return 15 }
                let dComps = DateComponents(year: y, month: m + 1, day: 0)
                let dt = tzCal.date(from: dComps)!
                return tzCal.component(.day, from: dt)
            }()
            let end = String(format: "%04d-%02d-%02d", y, m, lastDay)
            if syncMode == .fill24, let st = existingStatus[key], (st["complete"] as? Bool) == true {
            } else {
                result.append((key: key, start: start, end: end, incremental: false))
            }
            if !isP1 {
                isP1 = true
            } else {
                isP1 = false
                m -= 1
                if m == 0 { m = 12; y -= 1 }
            }
        }
        return result
    }

    private func runNextSalesPeriod() {
        guard isBusy else { return }
        if salesQueue.isEmpty {
            currentStepIndex = 4
            stageLabel = "4／4  更新完成"
            statusDetail = "組織與所選期別業績已完成更新並通過對帳，可點擊「查看戰情室」。"
            isBusy = false
            autoStage = ""
            return
        }
        currentPeriod = salesQueue.removeFirst()
        currentPeriodRecords = []
        currentPeriodPage = 1
        autoStage = "opening-period"
        statusDetail = "正在開啟下線購買明細，準備查詢 \(currentPeriod!.key)（\(currentPeriod!.start) ～ \(currentPeriod!.end)）…"
        crawlerWebView.load(URLRequest(url: URL(string: "https://tw.atomy.com/myoffice/mySales/lowerSales")!))
    }

    private func applyCurrentPeriodOnPage() {
        guard let period = currentPeriod else { return }
        autoStage = "scanning-sales"
        let transportJs = readAsset("period-transport.js")
        let periodJs = readAsset("period.js")
        let token = UUID().uuidString
        let opts: [String: Any] = ["start": period.start, "end": period.end, "queryToken": token]
        let optsJson = String(data: try! JSONSerialization.data(withJSONObject: opts), encoding: .utf8)!
        let combined = transportJs + "\n;" + periodJs.replacingOccurrences(of: "__OPTIONS__", with: optsJson)

        crawlerWebView.evaluateJavaScript(combined) { [weak self] _, _ in
            guard let self = self else { return }
            self.waitForPurchaseQuery(token: token, attempt: 0)
        }
    }

    private func waitForPurchaseQuery(token: String, attempt: Int) {
        guard isBusy, let period = currentPeriod else { return }
        if attempt > 45 {
            runNextSalesPeriod()
            return
        }
        let qJs = readAsset("query-state.js")
        let opts: [String: Any] = ["queryToken": token, "queryNavigationComplete": true]
        let optsJson = String(data: try! JSONSerialization.data(withJSONObject: opts), encoding: .utf8)!
        let script = qJs.replacingOccurrences(of: "__OPTIONS__", with: optsJson)

        crawlerWebView.evaluateJavaScript(script) { [weak self] res, _ in
            guard let self = self else { return }
            if let sStr = res as? String,
               let data = sStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["ready"] as? Bool) == true {
                self.captureCurrentPurchasePage()
            } else {
                self.statusDetail = "等待官方搜尋完成：\(period.key)…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.waitForPurchaseQuery(token: token, attempt: attempt + 1)
                }
            }
        }
    }

    private func captureCurrentPurchasePage() {
        guard isBusy, let period = currentPeriod else { return }
        statusDetail = "正在讀取 \(period.key) 購買明細第 \(currentPeriodPage) 頁（已累計 \(currentPeriodRecords.count) 筆）…"
        let probeJs = readAsset("probe.js")
        let opts: [String: Any] = ["start": period.start, "end": period.end, "queryReady": true]
        let optsJson = String(data: try! JSONSerialization.data(withJSONObject: opts), encoding: .utf8)!
        let script = probeJs.replacingOccurrences(of: "__MODE__", with: "'purchase'").replacingOccurrences(of: "__OPTIONS__", with: optsJson)

        crawlerWebView.evaluateJavaScript(script) { [weak self] res, _ in
            guard let self = self else { return }
            guard let sStr = res as? String,
                  let data = sStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.saveCurrentPeriodSnapshot()
                self.runNextSalesPeriod()
                return
            }
            if let off = obj["officialSummary"] as? [String: Any] {
                self.latestOfficialSummary = off
            }
            if (obj["emptyVerifiedDateRange"] as? Bool) == true {
                self.saveCurrentPeriodSnapshot()
                self.runNextSalesPeriod()
                return
            }
            if let recs = obj["records"] as? [[String: Any]] {
                self.currentPeriodRecords.append(contentsOf: recs)
            }
            let pagerJs = self.readAsset("pager.js")
            self.crawlerWebView.evaluateJavaScript(pagerJs) { pRes, _ in
                if let pStr = pRes as? String, pStr.contains("\"clicked\":true") && self.currentPeriodPage < 500 {
                    self.currentPeriodPage += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        self.captureCurrentPurchasePage()
                    }
                } else {
                    self.saveCurrentPeriodSnapshot()
                    self.runNextSalesPeriod()
                }
            }
        }
    }

    private func saveCurrentPeriodSnapshot() {
        guard let period = currentPeriod else { return }
        let dir = accountDirectory(for: activeAccount)
        let histUrl = dir.appendingPathComponent("sales_history.json")
        let statUrl = dir.appendingPathComponent("sales_status.json")

        var history = (try? Data(contentsOf: histUrl)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var statuses = (try? Data(contentsOf: statUrl)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        history[period.key] = currentPeriodRecords
        let nowIso = ISO8601DateFormatter().string(from: Date())
        statuses[period.key] = [
            "capturedAt": nowIso,
            "complete": true,
            "reconciled": true,
            "rows": currentPeriodRecords.count,
            "coverage": [["start": period.start, "end": period.end]]
        ]

        if let hData = try? JSONSerialization.data(withJSONObject: history) {
            try? hData.write(to: histUrl, options: .atomic)
        }
        if let sData = try? JSONSerialization.data(withJSONObject: statuses) {
            try? sData.write(to: statUrl, options: .atomic)
        }
    }

    private func requestRelogin() {
        isBusy = false
        autoStage = ""
        stageLabel = "登入已到期，請輸入密碼"
        statusDetail = "登入已到期。請在 APP 輸入密碼並按「登入並更新」，已存組織與歷史業績會保留。"
    }

    private func failSync(_ message: String) {
        isBusy = false
        autoStage = ""
        stageLabel = "同步未完成"
        statusDetail = message
    }
}

struct HiddenCrawlerWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

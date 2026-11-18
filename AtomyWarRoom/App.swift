import SwiftUI

@main
struct AtomyWarRoomApp: App {
    @StateObject private var syncEngine = AtomySyncEngine()
    @State private var currentScreen: AppScreen = .brand

    enum AppScreen {
        case brand
        case sync
        case warRoom
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                switch currentScreen {
                case .brand:
                    BrandCoverView {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentScreen = .sync
                        }
                    }
                case .sync:
                    SyncMainView(
                        engine: syncEngine,
                        onOpenWarRoom: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentScreen = .warRoom
                            }
                        }
                    )
                case .warRoom:
                    WarRoomContainerView(
                        engine: syncEngine,
                        onBackToSync: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentScreen = .sync
                            }
                        }
                    )
                }
            }
            .preferredColorScheme(.light)
        }
    }
}

// MARK: - 1. BrandCoverView (1:1 Port of BrandActivity.java)
struct BrandCoverView: View {
    var onStart: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.059, green: 0.153, blue: 0.278), Color(red: 0.031, green: 0.427, blue: 0.635)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()
                Text("ATOMY")
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(4)
                    .foregroundColor(Color(red: 0.725, green: 0.906, blue: 1.0))

                Text("艾多美")
                    .font(.system(size: 42, weight: .black))
                    .foregroundColor(.white)

                Text("行動戰情室")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white.opacity(0.95))

                VStack(spacing: 6) {
                    Text("高雄飛揚教育中心")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(Color(red: 0.835, green: 0.929, blue: 0.98))
                    Text("中心長 黃鈺維 製作")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.top, 12)

                Spacer()

                Button(action: onStart) {
                    Text("開始使用")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(Color(red: 0.059, green: 0.153, blue: 0.278))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .cornerRadius(16)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - 2. SyncMainView (1:1 Port of SyncScreen.java & MainActivity.java)
struct SyncMainView: View {
    @ObservedObject var engine: AtomySyncEngine
    var onOpenWarRoom: () -> Void
    @State private var showPassword = false
    @State private var showOfficialSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Hero Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("ATOMY  /  行動戰情室")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(1.5)
                        .foregroundColor(Color(red: 0.725, green: 0.906, blue: 1.0))
                    Text("你的團隊，一眼掌握")
                        .font(.system(size: 26, weight: .black))
                        .foregroundColor(.white)
                    Text("登入後，自動整理組織與歷史業績")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.88))
                    if !engine.activeAccount.isEmpty {
                        Text("目前資料帳號 \(engine.activeAccount)")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.18))
                            .foregroundColor(.white)
                            .cornerRadius(999)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.07, green: 0.22, blue: 0.345), Color(red: 0.03, green: 0.43, blue: 0.635)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(22)

                // Credentials & Sync Mode Card
                VStack(alignment: .leading, spacing: 14) {
                    Text("連結你的艾多美帳號")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundColor(Color(red: 0.09, green: 0.215, blue: 0.31))
                    Text("輸入帳密，後面的更新交給 APP。")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.41, green: 0.50, blue: 0.57))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("會員編號 / 暱稱")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(red: 0.41, green: 0.50, blue: 0.57))
                        TextField("輸入會員編號或暱稱", text: $engine.accountInput)
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                            .padding(12)
                            .background(Color(red: 0.97, green: 0.98, blue: 0.99))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.85, green: 0.90, blue: 0.94)))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("密碼")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Color(red: 0.41, green: 0.50, blue: 0.57))
                            Spacer()
                            Toggle("顯示密碼", isOn: $showPassword)
                                .labelsHidden()
                            Text("顯示密碼")
                                .font(.system(size: 12))
                                .foregroundColor(Color(red: 0.41, green: 0.50, blue: 0.57))
                        }
                        if showPassword {
                            TextField(engine.hasSavedSession ? "留空可沿用登入狀態" : "輸入艾多美密碼", text: $engine.passwordInput)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .padding(12)
                                .background(Color(red: 0.97, green: 0.98, blue: 0.99))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.85, green: 0.90, blue: 0.94)))
                        } else {
                            SecureField(engine.hasSavedSession ? "留空可沿用登入狀態" : "輸入艾多美密碼", text: $engine.passwordInput)
                                .padding(12)
                                .background(Color(red: 0.97, green: 0.98, blue: 0.99))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.85, green: 0.90, blue: 0.94)))
                        }
                        Text("帳密只用於艾多美官方登入。APP 不儲存密碼。")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(red: 0.45, green: 0.54, blue: 0.62))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("更新方式")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(red: 0.41, green: 0.50, blue: 0.57))
                        Picker("更新方式", selection: $engine.syncMode) {
                            Text("日常快速更新（前 5 天～明天）").tag(AtomySyncEngine.SyncMode.daily)
                            Text("補齊最近 24 期（只補缺漏）").tag(AtomySyncEngine.SyncMode.fill24)
                            Text("重新讀取最近 24 期（較久）").tag(AtomySyncEngine.SyncMode.reload24)
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(red: 0.97, green: 0.98, blue: 0.99))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.85, green: 0.90, blue: 0.94)))

                        Toggle(isOn: $engine.forceFullOrgScan) {
                            Text("重新掃描完整組織（較久）")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(Color(red: 0.09, green: 0.215, blue: 0.31))
                        }
                        .padding(.top, 4)

                        Text("每次先快速更新近期組織分支；首次使用會建立完整組織。歷史業績保留，需要時再選補齊。")
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 0.45, green: 0.54, blue: 0.62))
                    }

                    // Action Buttons
                    VStack(spacing: 10) {
                        if engine.isBusy {
                            Button(action: { engine.cancelSync() }) {
                                Text("停止更新")
                                    .font(.system(size: 16, weight: .heavy))
                                    .foregroundColor(Color(red: 0.70, green: 0.14, blue: 0.09))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(red: 0.996, green: 0.95, blue: 0.945))
                                    .cornerRadius(12)
                            }
                        } else {
                            Button(action: { engine.startNativeLoginAndSync() }) {
                                Text("登入並更新")
                                    .font(.system(size: 16, weight: .heavy))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(red: 0.031, green: 0.494, blue: 0.725))
                                    .cornerRadius(12)
                            }
                        }

                        HStack(spacing: 10) {
                            Button(action: {
                                if engine.canOpenWarRoom {
                                    onOpenWarRoom()
                                } else {
                                    engine.statusDetail = "請先登入要查看的會員帳號。"
                                }
                            }) {
                                Text("查看戰情室")
                                    .font(.system(size: 15, weight: .heavy))
                                    .foregroundColor(Color(red: 0.09, green: 0.30, blue: 0.65))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Color(red: 0.918, green: 0.949, blue: 1.0))
                                    .cornerRadius(12)
                            }

                            Button(action: { showOfficialSheet = true }) {
                                Text("艾多美官方驗證")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(red: 0.41, green: 0.50, blue: 0.57))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                    .background(Color.white)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.85, green: 0.90, blue: 0.94)))
                            }
                        }

                        if !engine.activeAccount.isEmpty && !engine.isBusy {
                            Button(action: { engine.switchAccount() }) {
                                Text("切換帳號／重新登入")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Color(red: 0.41, green: 0.50, blue: 0.57))
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(18)
                .background(Color.white)
                .cornerRadius(20)
                .shadow(color: Color.black.opacity(0.03), radius: 10, y: 4)

                // Progress & Status Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(engine.stageLabel)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(Color(red: 0.07, green: 0.22, blue: 0.345))
                        Spacer()
                        if engine.isBusy {
                            ProgressView()
                                .scaleEffect(0.9)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(1...4, id: \.self) { step in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(step <= engine.currentStepIndex ? Color(red: 0.031, green: 0.494, blue: 0.725) : Color(red: 0.89, green: 0.93, blue: 0.96))
                                .frame(height: 6)
                        }
                    }

                    Text(engine.statusDetail)
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.32, green: 0.43, blue: 0.51))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .background(Color.white)
                .cornerRadius(20)
                .shadow(color: Color.black.opacity(0.03), radius: 10, y: 4)
            }
            .padding(16)
        }
        .background(Color(red: 0.953, green: 0.969, blue: 0.984).ignoresSafeArea())
        .sheet(isPresented: $showOfficialSheet) {
            NavigationView {
                HiddenCrawlerWebView(webView: engine.crawlerWebView)
                    .navigationTitle("艾多美官方畫面")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("返回 APP") { showOfficialSheet = false }
                        }
                    }
            }
        }
        .onChange(of: engine.needsUserVerification) { needed in
            if needed { showOfficialSheet = true }
        }
    }
}

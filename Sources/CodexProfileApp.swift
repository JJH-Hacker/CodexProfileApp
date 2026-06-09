import AppKit
import SwiftUI
import Foundation

@main
struct CodexProfileApp: App {
    @StateObject private var profileManager = ProfileManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .background(WindowAccessor())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        
        MenuBarExtra("Codex Profile", systemImage: "person.crop.circle.badge.plus") {
            VStack {
                Text("Active Account: \(profileManager.activeProfile?.id ?? "None")")
                Divider()
                ForEach(profileManager.profiles) { profile in
                    Button {
                        profileManager.setActive(profile)
                    } label: {
                        HStack {
                            Text(profile.id)
                            if profileManager.activeProfile?.id == profile.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button("Rotate to Next Account") {
                    profileManager.rotateToNext()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

// MARK: - Profile Manager
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
    
    @Published var profiles: [Profile] = []
    @Published var activeProfile: Profile?
    @Published var activeUsagePercent: Int?
    @Published var profileUsages: [String: Int] = [:]
    @Published var hasNotifiedFull = false
    @Published var isFetchingUsage = false
    @Published var outputLog: String = "Ready.\n"
    @Published var isBusy = false
    
    @Published var restartCodexOnSwitch: Bool {
        didSet {
            UserDefaults.standard.set(restartCodexOnSwitch, forKey: "restartCodexOnSwitch")
            log("Restart Codex on switch set to \(restartCodexOnSwitch)")
        }
    }
    
    @Published var autoResumeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoResumeEnabled, forKey: "autoResumeEnabled")
            log("Auto-Resume on restart set to \(autoResumeEnabled)")
        }
    }
    
    let defaultCodexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    let profilesRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-profiles", isDirectory: true)
    
    @Published var autoRotateEnabled = false {
        didSet {
            if autoRotateEnabled {
                startAutoRotateMonitor()
                log("Auto-Rotate Monitoring Enabled.")
            } else {
                logMonitorTimer?.invalidate()
                log("Auto-Rotate Monitoring Disabled.")
            }
        }
    }
    
    private var logMonitorTimer: Timer?
    private var lastLogOffset: UInt64 = 0
    private var currentLogPath: String = ""
    
    private let codexPath = findCodex()

    init() {
        self.restartCodexOnSwitch = UserDefaults.standard.object(forKey: "restartCodexOnSwitch") as? Bool ?? true
        self.autoResumeEnabled = UserDefaults.standard.object(forKey: "autoResumeEnabled") as? Bool ?? true
        refreshProfiles()
    }
    
    func refreshProfiles() {
        do {
            try FileManager.default.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: defaultCodexHome, withIntermediateDirectories: true)
            
            let urls = try FileManager.default.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            profiles = urls
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { Profile(id: $0.lastPathComponent, url: $0) }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            
            determineActiveProfile()
        } catch {
            log("Error refreshing profiles: \(error.localizedDescription)")
        }
    }
    
    func determineActiveProfile() {
        let mainAuthURL = defaultCodexHome.appendingPathComponent("auth.json")
        guard let mainData = try? Data(contentsOf: mainAuthURL) else {
            activeProfile = nil
            return
        }
        activeProfile = profiles.first { profile in
            if let profileData = try? Data(contentsOf: profile.url.appendingPathComponent("auth.json")) {
                return mainData == profileData
            }
            return false
        }
        
        if activeProfile != nil {
            fetchAllUsages()
        }
    }
    
    func setActive(_ profile: Profile) {
        let mainAuthURL = defaultCodexHome.appendingPathComponent("auth.json")
        let profileAuthURL = profile.url.appendingPathComponent("auth.json")
        
        do {
            if FileManager.default.fileExists(atPath: mainAuthURL.path) || isSymlink(mainAuthURL) {
                try FileManager.default.removeItem(at: mainAuthURL)
            }
            if FileManager.default.fileExists(atPath: profileAuthURL.path) {
                let data = try Data(contentsOf: profileAuthURL)
                try data.write(to: mainAuthURL, options: .atomic)
                log("Set \(profile.id) as Active Global Account.")
                activeProfile = profile
                if restartCodexOnSwitch {
                    forceRestartCodex()
                } else {
                    log("Hot-swapped auth.json without restarting Codex.")
                }
                fetchAllUsages()
            } else {
                log("Profile \(profile.id) does not have auth.json. Cannot set active.")
            }
        } catch {
            log("Failed to set active profile: \(error.localizedDescription)")
        }
    }
    
    private func forceRestartCodex() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "Codex" }
        for app in apps {
            app.terminate()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Codex"]
            try? process.run()
            
            if self.autoResumeEnabled {
                self.log("Auto-Resume enabled. Waiting 4 seconds to send 'keep going'...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    self.sendKeepGoingToCodex()
                }
            }
        }
    }
    
    private func sendKeepGoingToCodex() {
        let script = """
        set the clipboard to "계정 스위칭이 완료되었습니다. 끊긴 이전 작업을 그대로 이어서 진행해 줘."
        tell application "System Events"
            tell process "Codex"
                set frontmost to true
                delay 0.5
                keystroke "v" using command down
                delay 0.5
                keystroke return
            end tell
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            self.log("Sent auto-resume prompt to Codex via AppleScript.")
        } catch {
            self.log("Failed to send auto-resume prompt: \(error.localizedDescription)")
        }
    }
    
    func rotateToNext() {
        guard !profiles.isEmpty else { return }
        // For manual rotation, still go to next sequentially if usage is not known,
        // but if we have profileUsages, we can pick the best one.
        // Actually, let's just use the best available profile.
        let bestProfile = profiles.min { (p1, p2) -> Bool in
            let u1 = profileUsages[p1.id] ?? 0
            let u2 = profileUsages[p2.id] ?? 0
            return u1 < u2
        }
        
        if let best = bestProfile, best.id != activeProfile?.id {
            setActive(best)
        } else if let current = activeProfile, let idx = profiles.firstIndex(of: current) {
            // Fallback to sequential if all are equal or best is current
            let nextIdx = (idx + 1) % profiles.count
            setActive(profiles[nextIdx])
        } else {
            setActive(profiles[0])
        }
    }
    
    private func startAutoRotateMonitor() {
        logMonitorTimer?.invalidate()
        // Poll every 30 seconds
        logMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.fetchAllUsages()
        }
    }

    func fetchAllUsages() {
        guard !profiles.isEmpty else { return }
        
        DispatchQueue.main.async {
            self.isFetchingUsage = true
        }
        
        var codexbarPath = Bundle.main.url(forResource: "codexbar", withExtension: nil)?.path
        if codexbarPath == nil {
            let fallbackPath = FileManager.default.currentDirectoryPath + "/Resources/codexbar"
            if FileManager.default.fileExists(atPath: fallbackPath) {
                codexbarPath = fallbackPath
            } else {
                let parentFallbackPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .deletingLastPathComponent().path + "/Resources/codexbar"
                if FileManager.default.fileExists(atPath: parentFallbackPath) {
                    codexbarPath = parentFallbackPath
                }
            }
        }
        
        guard let path = codexbarPath, FileManager.default.fileExists(atPath: path) else {
            DispatchQueue.main.async {
                self.isFetchingUsage = false
                self.log("codexbar binary not found at \(codexbarPath ?? "unknown")")
            }
            return
        }
        
        let group = DispatchGroup()
        var newUsages: [String: Int] = [:]
        let lock = NSLock()
        
        for profile in profiles {
            group.enter()
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["usage", "--format", "json", "--provider", "codex"]
            
            var env = ProcessInfo.processInfo.environment
            env["CODEX_HOME"] = profile.url.path
            process.environment = env
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            do {
                try process.run()
                process.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                       let codexItem = array.first(where: { ($0["provider"] as? String) == "codex" }),
                       let usage = codexItem["usage"] as? [String: Any],
                       let primary = usage["primary"] as? [String: Any],
                       let percent = primary["usedPercent"] as? Int {
                        lock.lock()
                        newUsages[profile.id] = percent
                        lock.unlock()
                    }
                    group.leave()
                }
            } catch {
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isFetchingUsage = false
            self.profileUsages = newUsages
            
            if let active = self.activeProfile, let currentUsage = newUsages[active.id] {
                self.activeUsagePercent = currentUsage
                self.log("Current Usage: \(currentUsage)%")
                
                if self.autoRotateEnabled && currentUsage >= 100 {
                    self.log("Usage limit reached (100%). Finding best account...")
                    
                    let bestProfile = self.profiles.min { p1, p2 in
                        let u1 = newUsages[p1.id] ?? 100
                        let u2 = newUsages[p2.id] ?? 100
                        return u1 < u2
                    }
                    
                    if let best = bestProfile, let bestUsage = newUsages[best.id], bestUsage < 100 {
                        self.hasNotifiedFull = false
                        self.log("Auto-rotating to \(best.id) (Usage: \(bestUsage)%)")
                        self.setActive(best)
                    } else {
                        self.log("All accounts are at 100% usage. Waiting...")
                        if !self.hasNotifiedFull {
                            self.hasNotifiedFull = true
                            self.notifyAllAccountsFull()
                        }
                    }
                }
            }
        }
    }
    
    private func notifyAllAccountsFull() {
        let script = """
        display notification "모든 계정의 사용량이 100%에 도달했습니다. 잠시 후 다시 시도해주세요." with title "Codex Profile Manager" subtitle "사용량 한도 초과" sound name "Basso"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
    
    func quickAddKey(_ key: String) {
        let name = "Profile-\(profiles.count + 1)"
        let url = profilesRoot.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            log("Created profile \(name). Logging in...")
            
            isBusy = true
            CodexRunner.run(codexPath: codexPath, profileHome: url, arguments: ["login", "--with-api-key"], stdin: key + "\n", currentDirectory: nil) { result in
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.log(result)
                    self.refreshProfiles()
                    if let newProfile = self.profiles.first(where: { $0.id == name }) {
                        self.setActive(newProfile)
                    }
                }
            }
        } catch {
            log("Failed to create profile: \(error.localizedDescription)")
        }
    }
    
    func oauthAddProfile() {
        let name = "Profile-\(profiles.count + 1)"
        let url = profilesRoot.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            log("Created profile \(name). Opening browser for OAuth login...")
            
            isBusy = true
            CodexRunner.run(codexPath: codexPath, profileHome: url, arguments: ["login"], stdin: nil, currentDirectory: nil) { result in
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.log(result)
                    
                    let authFile = url.appendingPathComponent("auth.json")
                    if FileManager.default.fileExists(atPath: authFile.path) {
                        self.log("OAuth login successful for \(name).")
                        self.refreshProfiles()
                        if let newProfile = self.profiles.first(where: { $0.id == name }) {
                            self.setActive(newProfile)
                        }
                    } else {
                        self.log("OAuth login failed or cancelled. Cleaning up \(name)...")
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        } catch {
            log("Failed to start OAuth login: \(error.localizedDescription)")
        }
    }
    
    func openCodexApp() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Codex"] // Assuming the app is named Codex
        do {
            try task.run()
            log("Launched Codex App.")
        } catch {
            log("Failed to launch Codex App: \(error.localizedDescription)")
        }
    }

    func log(_ message: String) {
        outputLog += "[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n"
    }
    
    func clearLogs() {
        outputLog = "Logs cleared.\n"
    }
    
    func deleteProfile(_ profile: Profile) {
        do {
            try FileManager.default.removeItem(at: profile.url)
            log("Deleted profile: \(profile.id)")
            if activeProfile?.id == profile.id {
                activeProfile = nil
                try? FileManager.default.removeItem(at: defaultCodexHome.appendingPathComponent("auth.json"))
            }
            refreshProfiles()
        } catch {
            log("Failed to delete profile: \(error.localizedDescription)")
        }
    }

    func renameProfile(_ profile: Profile, newName: String) {
        let safeName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty, safeName != profile.id else { return }
        let newURL = profilesRoot.appendingPathComponent(safeName, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: profile.url, to: newURL)
            log("Renamed profile \(profile.id) to \(safeName)")
            if activeProfile?.id == profile.id {
                activeProfile = nil
            }
            refreshProfiles()
            if let renamed = profiles.first(where: { $0.id == safeName }) {
                setActive(renamed)
            }
        } catch {
            log("Failed to rename profile: \(error.localizedDescription)")
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func findCodex() -> String {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        return "/usr/bin/env"
    }
}

// MARK: - Models
struct Profile: Identifiable, Hashable {
    let id: String
    let url: URL
}

// MARK: - UI Views
struct ContentView: View {
    @ObservedObject var profileManager = ProfileManager.shared
    @State private var newApiKey: String = ""
    @State private var profileToRename: Profile?
    @State private var newProfileName: String = ""
    @State private var profileToDelete: Profile?

    var body: some View {
        ZStack {
            // Liquid Glass Background
            AnimatedMeshBackground()
                .ignoresSafeArea()
            
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
                .opacity(0.8)

            VStack(spacing: 0) {
                // Custom Title Bar Area
                HStack(spacing: 16) {
                    Text("Codex Profiles")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    
                    if let percent = profileManager.activeUsagePercent {
                        let remaining = max(0, 100 - percent)
                        HStack(spacing: 6) {
                            Image(systemName: "battery.100.bolt")
                            Text("\(remaining)% Remaining")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            remaining < 10 ? Color.red.opacity(0.8) :
                            remaining < 30 ? Color.orange.opacity(0.8) :
                            Color.green.opacity(0.8)
                        )
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    } else if profileManager.isFetchingUsage {
                        ProgressView().controlSize(.small)
                            .tint(.white)
                    }

                    Spacer()
                    Button(action: { profileManager.fetchAllUsages() }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(profileManager.isFetchingUsage)
                    
                    Button(action: { profileManager.openCodexApp() }) {
                        Label("Launch Codex App", systemImage: "app.badge")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
                .background(Color.black.opacity(0.1))

                HStack(alignment: .top, spacing: 20) {
                    // Sidebar
                    VStack {
                        GlassBox {
                            VStack(alignment: .leading, spacing: 15) {
                                Text("Profiles")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                
                                ScrollView {
                                    VStack(spacing: 10) {
                                        ForEach(profileManager.profiles) { profile in
                                            ProfileRow(profile: profile, isActive: profileManager.activeProfile?.id == profile.id, usagePercent: profileManager.profileUsages[profile.id])
                                                .onTapGesture {
                                                    profileManager.setActive(profile)
                                                }
                                                .contextMenu {
                                                    Button("Rename...") {
                                                        newProfileName = profile.id
                                                        profileToRename = profile
                                                    }
                                                    Button("Delete") {
                                                        profileToDelete = profile
                                                    }
                                                }
                                        }
                                    }
                                }
                                
                                Divider().background(Color.white.opacity(0.3))
                                
                                Button(action: { profileManager.rotateToNext() }) {
                                    HStack {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                        Text("Rotate to Next")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                
                                Toggle("Auto-Rotate on Limit", isOn: $profileManager.autoRotateEnabled)
                                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                                    .foregroundStyle(.white)
                                    .font(.footnote)
                                
                                Toggle("Restart Codex on Switch", isOn: $profileManager.restartCodexOnSwitch)
                                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                                    .foregroundStyle(.white)
                                    .font(.footnote)
                                    
                                Toggle("Auto-Resume ('keep going')", isOn: $profileManager.autoResumeEnabled)
                                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                                    .foregroundStyle(.white)
                                    .font(.footnote)
                            }
                            .padding()
                        }
                    }
                    .frame(width: 250)

                    // Main Content Area
                    VStack(spacing: 20) {
                        GlassBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Quick Add Profile")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Paste a Codex API Key to automatically create and login to a new profile.")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.7))
                                
                                HStack {
                                    SecureField("sk-...", text: $newApiKey)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .padding(10)
                                        .background(Color.black.opacity(0.2))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(.white)
                                    
                                    Button(action: {
                                        profileManager.quickAddKey(newApiKey)
                                        newApiKey = ""
                                    }) {
                                        if profileManager.isBusy {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Text("Add Account")
                                                .fontWeight(.semibold)
                                        }
                                    }
                                    .disabled(newApiKey.isEmpty || profileManager.isBusy)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(newApiKey.isEmpty ? Color.white.opacity(0.1) : Color.blue.opacity(0.8))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .buttonStyle(.plain)
                                }
                                
                                Button(action: { profileManager.oauthAddProfile() }) {
                                    HStack {
                                        Image(systemName: "safari")
                                        Text("Login with Web (OAuth)")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .disabled(profileManager.isBusy)
                            }
                            .padding()
                        }

                        GlassBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("System Log")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Button(action: { profileManager.clearLogs() }) {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.white.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                }
                                ScrollView {
                                    Text(profileManager.outputLog)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: .infinity)
                                .padding(10)
                                .background(Color.black.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .padding()
                        }
                    }
                }
                .padding(20)
            }
        }
        .alert("Rename Profile", isPresented: Binding<Bool>(
            get: { profileToRename != nil },
            set: { if !$0 { profileToRename = nil } }
        ), presenting: profileToRename) { profile in
            TextField("New Name", text: $newProfileName)
            Button("Cancel", role: .cancel) { profileToRename = nil }
            Button("Save") {
                profileManager.renameProfile(profile, newName: newProfileName)
                profileToRename = nil
            }
        }
        .alert("Delete Profile", isPresented: Binding<Bool>(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        ), presenting: profileToDelete) { profile in
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                profileManager.deleteProfile(profile)
                profileToDelete = nil
            }
        } message: { profile in
            Text("Are you sure you want to delete '\(profile.id)'? This action cannot be undone.")
        }
    }
}

// MARK: - Components
struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool
    let usagePercent: Int?
    
    var body: some View {
        HStack {
            Image(systemName: isActive ? "checkmark.circle.fill" : "person.crop.circle")
                .foregroundStyle(isActive ? .green : .white.opacity(0.7))
            Text(profile.id)
                .foregroundStyle(isActive ? .white : .white.opacity(0.7))
                .fontWeight(isActive ? .bold : .regular)
            Spacer()
            
            if let percent = usagePercent {
                let remaining = max(0, 100 - percent)
                Text("\(remaining)%")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        remaining < 10 ? Color.red.opacity(0.8) :
                        remaining < 30 ? Color.orange.opacity(0.8) :
                        Color.green.opacity(0.8)
                    )
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(isActive ? Color.white.opacity(0.2) : Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.white.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

struct GlassBox<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        content
            .background(Color.white.opacity(0.05))
            .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

struct AnimatedMeshBackground: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.15).ignoresSafeArea()
            
            Circle()
                .fill(Color.blue.opacity(0.6))
                .frame(width: 400, height: 400)
                .blur(radius: 80)
                .offset(x: isAnimating ? 200 : -200, y: isAnimating ? -100 : 200)
            
            Circle()
                .fill(Color.purple.opacity(0.6))
                .frame(width: 500, height: 500)
                .blur(radius: 100)
                .offset(x: isAnimating ? -300 : 100, y: isAnimating ? 200 : -200)
            
            Circle()
                .fill(Color.pink.opacity(0.5))
                .frame(width: 300, height: 300)
                .blur(radius: 60)
                .offset(x: isAnimating ? 100 : -100, y: isAnimating ? 100 : -100)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - CodexRunner
enum CodexRunner {
    static func run(codexPath: String, profileHome: URL, arguments: [String], stdin: String?, currentDirectory: String?, completion: @escaping (String) -> Void) {
        let process = Process()
        if codexPath == "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex"] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = arguments
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profileHome.path
        process.environment = environment

        if let currentDirectory, !currentDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        if let stdin {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion("Failed to run codex: \(error.localizedDescription)")
            }
            return
        }

        process.terminationHandler = { process in
            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                completion(stdout + stderr)
            }
        }
    }
}

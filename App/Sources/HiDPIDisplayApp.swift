// G9 Helper
// HiDPI scaling utility for Samsung Odyssey G9 and large monitors
// Created by AL in Dallas

import SwiftUI
import AppKit
import CoreGraphics

func debugLog(_ message: String) {
    NSLog("HiDPI: %@", message)
    // Also write to a file for easier debugging
    let logFile = "/tmp/g9helper.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}

// MARK: - Launch Agent Manager

class LaunchAgentManager {
    static let shared = LaunchAgentManager()

    private let plistName = "com.hidpi.g9helper.plist"

    private var plistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(plistName)"
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Install the launch agent plist. The plist is written with RunAtLoad
    /// for next-login startup, but we skip `launchctl load` while the app
    /// is already running to avoid spawning a duplicate instance.
    func install() -> Bool {
        // Create LaunchAgents directory if needed
        let dir = (plistPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            debugLog("Failed to create LaunchAgents directory: \(error)")
            return false
        }

        // Use the installed app's executable path (not the running one, in case we're in a build dir)
        let execPath = "/Applications/G9 Helper.app/Contents/MacOS/HiDPIDisplay"
        guard FileManager.default.fileExists(atPath: execPath) else {
            // Writing a plist pointing at a missing binary would silently do
            // nothing at login; fail so the caller shows the install alert.
            debugLog("Launch agent install failed: app not found at /Applications/G9 Helper.app")
            return false
        }

        let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.hidpi.g9helper</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                    <key>Crashed</key>
                    <true/>
                </dict>
                <key>ThrottleInterval</key>
                <integer>2</integer>
                <key>StandardOutPath</key>
                <string>/tmp/g9helper.log</string>
                <key>StandardErrorPath</key>
                <string>/tmp/g9helper.log</string>
                <key>ProcessType</key>
                <string>Interactive</string>
                <key>AbandonProcessGroup</key>
                <true/>
            </dict>
            </plist>
            """

        do {
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            debugLog("Failed to write launch agent plist: \(error)")
            return false
        }

        // Don't call `launchctl load` here — RunAtLoad would immediately
        // spawn a second instance while we're already running. The plist
        // is in place and launchd will pick it up on next login. The
        // KeepAlive/Crashed setting will also work after the next reboot.
        debugLog("Launch agent plist installed (will activate on next login)")
        return true
    }

    func uninstall() -> Bool {
        // Unload the agent first
        let unload = Process()
        unload.launchPath = "/bin/launchctl"
        unload.arguments = ["unload", plistPath]
        do {
            try unload.run()
            unload.waitUntilExit()
            if unload.terminationStatus != 0 {
                debugLog("launchctl unload returned status \(unload.terminationStatus)")
                // Agent might not be loaded (e.g., fresh install before reboot) — continue with file removal
            }
        } catch {
            debugLog("launchctl unload failed to run: \(error)")
        }

        // Remove the plist file
        do {
            try FileManager.default.removeItem(atPath: plistPath)
            debugLog("Launch agent uninstalled")
            return true
        } catch {
            debugLog("Failed to remove launch agent plist: \(error)")
            return false
        }
    }
}

// MARK: - Custom Scale Window

class CustomScaleWindowController {
    private var window: NSWindow?
    private var slider: NSSlider?
    private var scaleValueLabel: NSTextField?
    private var resolutionLabel: NSTextField?
    private var nativeWidth: UInt32 = 0
    private var nativeHeight: UInt32 = 0
    private var ppi: UInt32 = 140
    private var applyCallback: ((PresetConfig) -> Void)?

    static let shared = CustomScaleWindowController()

    func show(nativeWidth: UInt32, nativeHeight: UInt32, ppi: UInt32, onApply: @escaping (PresetConfig) -> Void) {
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.ppi = ppi
        self.applyCallback = onApply

        DispatchQueue.main.async { [weak self] in
            self?.createAndShowWindow()
        }
    }

    private func createAndShowWindow() {
        // Close any existing window
        window?.close()

        let windowRect = NSRect(x: 0, y: 0, width: 420, height: 180)
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Custom Scale"
        window.level = .floating
        window.center()

        let contentView = NSView(frame: windowRect)

        // Native resolution label
        let titleLabel = NSTextField(labelWithString: "Native: \(nativeWidth)×\(nativeHeight)")
        titleLabel.frame = NSRect(x: 20, y: 145, width: 380, height: 20)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        contentView.addSubview(titleLabel)

        // Scale factor row
        let scaleLabel = NSTextField(labelWithString: "Scale:")
        scaleLabel.frame = NSRect(x: 20, y: 108, width: 50, height: 20)
        scaleLabel.font = NSFont.systemFont(ofSize: 12)
        contentView.addSubview(scaleLabel)

        let slider = NSSlider(value: 1.4, minValue: 1.1, maxValue: 2.0, target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 75, y: 108, width: 260, height: 20)
        slider.isContinuous = true
        contentView.addSubview(slider)
        self.slider = slider

        let scaleValueLabel = NSTextField(labelWithString: "1.40x")
        scaleValueLabel.frame = NSRect(x: 345, y: 108, width: 55, height: 20)
        scaleValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        contentView.addSubview(scaleValueLabel)
        self.scaleValueLabel = scaleValueLabel

        // Resolution preview
        let logicalW = UInt32(Double(nativeWidth) / 1.4)
        let logicalH = UInt32(Double(nativeHeight) / 1.4)
        let resLabel = NSTextField(labelWithString: "Resolution: \(logicalW)×\(logicalH) HiDPI")
        resLabel.frame = NSRect(x: 20, y: 75, width: 380, height: 20)
        resLabel.font = NSFont.systemFont(ofSize: 13)
        resLabel.textColor = NSColor.secondaryLabelColor
        contentView.addSubview(resLabel)
        self.resolutionLabel = resLabel

        // Apply button
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applyClicked(_:)))
        applyButton.frame = NSRect(x: 300, y: 20, width: 100, height: 32)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        contentView.addSubview(applyButton)

        // Cancel button
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.frame = NSRect(x: 190, y: 20, width: 100, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        let scale = (sender.doubleValue * 100).rounded() / 100
        let logicalW = UInt32(Double(nativeWidth) / scale)
        let logicalH = UInt32(Double(nativeHeight) / scale)

        scaleValueLabel?.stringValue = String(format: "%.2fx", scale)
        resolutionLabel?.stringValue = "Resolution: \(logicalW)×\(logicalH) HiDPI"
    }

    @objc func applyClicked(_ sender: NSButton) {
        guard let slider = slider else { return }
        let scale = (slider.doubleValue * 100).rounded() / 100

        let logicalW = UInt32(Double(nativeWidth) / scale)
        let logicalH = UInt32(Double(nativeHeight) / scale)

        let config = PresetConfig(
            name: "Custom-\(logicalW)x\(logicalH)",
            width: logicalW * 2,
            height: logicalH * 2,
            logicalWidth: logicalW,
            logicalHeight: logicalH,
            ppi: ppi,
            hiDPI: true
        )

        window?.close()
        window = nil
        applyCallback?(config)
    }

    @objc func cancelClicked(_ sender: NSButton) {
        window?.close()
        window = nil
    }
}

// MARK: - Status Window

class StatusWindowController {
    private var window: NSWindow?
    private var progressIndicator: NSProgressIndicator?
    private var statusLabel: NSTextField?

    static let shared = StatusWindowController()

    private init() {}

    func show(message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.createAndShowWindow(message: message)
        }
    }

    func updateStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel?.stringValue = message
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
    }

    private func createAndShowWindow(message: String) {
        // Close any window from a previous show() — otherwise it stays
        // floating on screen with no reference left to hide it
        window?.close()

        // Create window
        let windowRect = NSRect(x: 0, y: 0, width: 300, height: 120)
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.level = .floating
        window.center()

        // Create content view
        let contentView = NSView(frame: windowRect)

        // App icon or display icon
        let iconView = NSImageView(frame: NSRect(x: 30, y: 45, width: 40, height: 40))
        if let icon = NSImage(systemSymbolName: "display", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .medium)
            iconView.image = icon.withSymbolConfiguration(config)
            iconView.contentTintColor = NSColor.controlAccentColor
        }
        contentView.addSubview(iconView)

        // Progress indicator
        let progress = NSProgressIndicator(frame: NSRect(x: 85, y: 65, width: 20, height: 20))
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        contentView.addSubview(progress)
        self.progressIndicator = progress

        // Title label
        let titleLabel = NSTextField(labelWithString: "G9 Helper")
        titleLabel.frame = NSRect(x: 110, y: 60, width: 160, height: 24)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.textColor = NSColor.labelColor
        contentView.addSubview(titleLabel)

        // Status label
        let statusLabel = NSTextField(labelWithString: message)
        statusLabel.frame = NSRect(x: 30, y: 20, width: 240, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.alignment = .center
        contentView.addSubview(statusLabel)
        self.statusLabel = statusLabel

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

// MARK: - Auto Update Checker

class UpdateChecker {
    static let shared = UpdateChecker()

    private let repoOwner = "knightynite"
    private let repoName = "HiDPIVirtualDisplay"
    private let currentVersion: String
    private let kLastUpdateCheckKey = "lastUpdateCheck"
    private let kSkippedVersionKey = "skippedVersion"
    private let kAutoCheckUpdatesKey = "autoCheckUpdates"

    private init() {
        // Get current version from bundle
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        debugLog("UpdateChecker initialized, current version: \(currentVersion)")
    }

    // Check if auto-update is enabled (default: true)
    var autoCheckEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: kAutoCheckUpdatesKey) == nil {
                return true  // Default to enabled
            }
            return UserDefaults.standard.bool(forKey: kAutoCheckUpdatesKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kAutoCheckUpdatesKey)
        }
    }

    // Check for updates (called on app launch)
    func checkForUpdatesInBackground() {
        guard autoCheckEnabled else {
            debugLog("Auto-update check disabled")
            return
        }

        // Don't check more than once per hour
        let lastCheck = UserDefaults.standard.double(forKey: kLastUpdateCheckKey)
        let hourAgo = Date().timeIntervalSince1970 - 3600
        if lastCheck > hourAgo {
            debugLog("Skipping update check - checked recently")
            return
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.fetchLatestRelease { result in
                switch result {
                case .success(let release):
                    self?.handleReleaseInfo(release)
                case .failure(let error):
                    debugLog("Update check failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // Manual check (from menu)
    func checkForUpdatesManually() {
        debugLog("Manual update check initiated")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.fetchLatestRelease { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let release):
                        self?.handleReleaseInfo(release, manual: true)
                    case .failure(let error):
                        self?.showError("Could not check for updates: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, Error>) -> Void) {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "UpdateChecker", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "UpdateChecker", code: -2, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                completion(.success(release))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func handleReleaseInfo(_ release: GitHubRelease, manual: Bool = false) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: kLastUpdateCheckKey)

        let latestVersion = release.tagName.replacingOccurrences(of: "v", with: "")
        debugLog("Latest version: \(latestVersion), current: \(currentVersion)")

        if isNewerVersion(latestVersion, than: currentVersion) {
            // Check if user skipped this version
            let skippedVersion = UserDefaults.standard.string(forKey: kSkippedVersionKey)
            if !manual && skippedVersion == latestVersion {
                debugLog("User previously skipped version \(latestVersion)")
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.showUpdateAlert(release: release, latestVersion: latestVersion)
            }
        } else if manual {
            DispatchQueue.main.async { [weak self] in
                self?.showUpToDateAlert()
            }
        }
    }

    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(newParts.count, currentParts.count) {
            let newPart = i < newParts.count ? newParts[i] : 0
            let currentPart = i < currentParts.count ? currentParts[i] : 0

            if newPart > currentPart { return true }
            if newPart < currentPart { return false }
        }
        return false
    }

    private func showUpdateAlert(release: GitHubRelease, latestVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "G9 Helper \(latestVersion) is available (you have \(currentVersion)).\n\n\(release.name ?? "")\n\nWould you like to download it?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            downloadUpdate(release: release)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(latestVersion, forKey: kSkippedVersionKey)
            debugLog("User skipped version \(latestVersion)")
        default:
            break
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "G9 Helper \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func downloadUpdate(release: GitHubRelease) {
        // Find the DMG asset
        guard let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            debugLog("No DMG found in release")
            // Fallback to opening release page
            if let url = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        debugLog("Downloading: \(dmgAsset.browserDownloadUrl)")

        // Show download progress
        StatusWindowController.shared.show(message: "Downloading update...")

        guard let url = URL(string: dmgAsset.browserDownloadUrl) else { return }

        let downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                StatusWindowController.shared.hide()

                if let error = error {
                    self?.showError("Download failed: \(error.localizedDescription)")
                    return
                }

                guard let tempURL = tempURL else {
                    self?.showError("Download failed: No file received")
                    return
                }

                // Move to Downloads folder
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let destURL = downloadsURL.appendingPathComponent(dmgAsset.name)

                do {
                    // Remove existing file if present
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destURL)

                    debugLog("Downloaded to: \(destURL.path)")

                    // Open the DMG
                    NSWorkspace.shared.open(destURL)

                    // Show instructions
                    self?.showInstallInstructions()

                } catch {
                    self?.showError("Could not save update: \(error.localizedDescription)")
                }
            }
        }
        downloadTask.resume()
    }

    private func showInstallInstructions() {
        let alert = NSAlert()
        alert.messageText = "Update Downloaded"
        alert.informativeText = "The update has been downloaded and opened.\n\n1. Drag the new G9 Helper to Applications\n2. Replace the existing version\n3. Relaunch G9 Helper"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// GitHub API Response Models
struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let htmlUrl: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlUrl = "html_url"
        case assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

@main
struct HiDPIDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private let outputReconfigurationCallback: CGDisplayReconfigurationCallBack = { display, flags, context in
    guard let context = context else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { [weak delegate] in
        delegate?.handleOutputTopologyChange(display, flags: flags)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var currentPresetName = ""
    private var isActive = false
    private var currentVirtualID: CGDirectDisplayID = 0
    private var targetExternalDisplayID: CGDirectDisplayID = 0  // Track which external display we're mirroring to

    // State persistence keys
    private let kLastPresetKey = "lastActivePreset"
    private let kWasCrashKey = "wasRunningWhenCrashed"
    private let kAutoRestoreKey = "autoRestoreOnCrash"
    private let kAutoApplyOnConnectKey = "autoApplyOnConnect"
    private let kRefreshRateKey = "customRefreshRate"  // 0.0 = auto-detect
    private let kKeepHDREnabledKey = "keepHDREnabledBeta"  // Migration from 8.6 and earlier
    private let kOutputPreferencesKey = "displayOutputPreferencesV1"
    private var outputMenu: NSMenu?
    private var outputObservationTimer: Timer?
    private var outputCallbackRegistered = false
    private var outputRestore = OutputRestoreBudget()
    private var hdrSelectionObserver = HDRSelectionObserver()
    private var outputObservationAfter: TimeInterval = 0
    private var forceAutomaticOutput = false
    private var outputRestoreMessage: String?
    private let kKeepPrimaryDisplayKey = "keepExternalAsMainDisplay"  // Keep the external monitor as the main display (menu bar)
    private let kBoundMonitorVendorKey = "boundMonitorVendor"
    private let kBoundMonitorModelKey = "boundMonitorModel"
    private let kBoundMonitorSerialKey = "boundMonitorSerial"

    // Track if we're waiting for monitor reconnection
    private var wasDisconnected = false

    // Track if we're in the middle of setting up HiDPI (don't trigger cleanup during setup)
    private var isSettingUp = false
    private var isRestarting = false

    // Monotonic token for delayed setup closures. Every apply/restore/disable
    // path increments it; a delayed create/mirror step only runs if the
    // generation it captured is still current. Prevents an overlapping wake
    // restore, reconnect restore, or manual apply from firing a stale
    // performMirror with display IDs that no longer exist.
    private var setupGeneration = 0
    private var connectionReadiness = DisplayConnectionReadiness()
    private var connectionReadinessGeneration = -1
    private var connectionRecoveryMessage: String?
    private var connectionRecoveryBlocked = false
    private var blockedConnectionCapabilities: DisplayLinkCapabilities?
    private var mirrorReattachWorkItem: DispatchWorkItem?
    private var setupTimingRequirement: DisplayTimingRequirement?
    private let kStableTimingKey = "lastStableDisplayTimingV1"
    private let kConnectionRecoveryCountKey = "consecutiveConnectionRecoveries"

    // A disconnect confirmation pass is scheduled (debounce for transient
    // dropouts like DP link retraining on wake or monitor power-cycling).
    private var disconnectConfirmationPending = false

    // Track consecutive mirror failures to prevent infinite restart loops
    private let kMirrorFailureCountKey = "consecutiveMirrorFailures"
    private let maxMirrorRetries = 3

    // Display change observer
    private var displayObserver: Any?
    private var displayCheckTimer: Timer?
    private var fixedRefreshWorkItem: DispatchWorkItem?
    private var fixedRefreshRepairAttempts = 0
    private var wakeObserver: Any?
    private var screenSleepObserver: Any?
    private var screenWakeObserver: Any?

    // Screens are asleep (display sleep, not system sleep). The G9 drops off
    // the display list for the whole time the panel is dark, which is not a
    // disconnect. While this is set, disconnect handling is deferred; the
    // wake/display-change handlers repair the mirror when the screens return.
    private var screensAsleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: launchd RunAtLoad plus a manual open (or a
        // relaunch race) can start a second copy, and two instances fight over
        // virtual displays and mirroring. exit() directly — NSApp.terminate
        // would run applicationWillTerminate and tear down the OTHER
        // instance's mirror.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                debugLog("Another instance is already running (pid \(others[0].processIdentifier)) — exiting")
                exit(0)
            }
        }

        rotateLogFileIfNeeded()
        debugLog("App launched")

        // Log which slice of the universal binary is running, plus version.
        // Helps diagnose Intel reports (the app ships arm64 + x86_64).
        #if arch(arm64)
        let runningArch = "arm64"
        #elseif arch(x86_64)
        let runningArch = "x86_64"
        #else
        let runningArch = "unknown"
        #endif
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        debugLog("Version \(appVersion), architecture: \(runningArch)")

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "HiDPI Display")
        }

        // Restore wasDisconnected state from UserDefaults (persists across restart)
        wasDisconnected = UserDefaults.standard.bool(forKey: kWasDisconnectedKey)
        debugLog("Restored wasDisconnected state: \(wasDisconnected)")
        if UserDefaults.standard.integer(forKey: kConnectionRecoveryCountKey) > 3 {
            wasDisconnected = false
            UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
            UserDefaults.standard.set(false, forKey: kWasCrashKey)
            connectionRecoveryMessage = "Connection recovery paused; select a preset to retry."
        }

        // Capture the initial HDR choice before cleanup can reset the link.
        // Existing per-monitor preferences always win over reconnect defaults.
        if let physical = findExternalDisplay() {
            prepareOutputPreference(for: physical)
            rememberUnmirroredNativeTiming(physical)
        }

        // Clean up any stale state from previous sessions
        cleanupStaleState()

        // If orphaned virtual displays exist from a previous crash and this
        // isn't already a cleanup restart, terminate and relaunch so macOS
        // reclaims the displays (we can't destroy cross-process displays via API)
        if hasOrphanedVirtualDisplay() && !isCleanupRestart() {
            debugLog("Orphaned virtual displays detected from previous crash, restarting to clean up...")
            markCleanupRestart()
            relaunchApp()
            return
        }

        // Check for existing virtual display
        checkCurrentState()

        // Check if we should auto-restore after a crash OR after disconnect restart
        checkAndRestoreFromCrash()

        // Build menu
        rebuildMenu()

        // Mark that the app is running (for crash detection)
        UserDefaults.standard.set(true, forKey: kWasCrashKey)

        // Start monitoring for display changes (disconnect detection)
        startDisplayChangeMonitoring()

        // Check for updates in background
        UpdateChecker.shared.checkForUpdatesInBackground()
    }

    /// Keep /tmp/g9helper.log from growing without bound (launchd also appends
    /// stdout/stderr there). Checked once per launch — the app relaunches
    /// often enough for that to be sufficient.
    func rotateLogFileIfNeeded() {
        let logFile = "/tmp/g9helper.log"
        let maxSize: UInt64 = 5 * 1024 * 1024
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile),
              let size = attrs[.size] as? UInt64, size > maxSize else { return }
        let oldFile = logFile + ".old"
        try? FileManager.default.removeItem(atPath: oldFile)
        try? FileManager.default.moveItem(atPath: logFile, toPath: oldFile)
    }

    func startDisplayChangeMonitoring() {
        // Use NotificationCenter to monitor screen configuration changes
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugLog(">>> Display change notification received")
            self?.handleDisplayConfigurationChange()
        }

        let callbackResult = CGDisplayRegisterReconfigurationCallback(
            outputReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        outputCallbackRegistered = callbackResult == .success
        // HDR changes do not always generate an NSScreen notification.
        let outputTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.observeManualHDRSelection()
            if let self = self, self.outputRestore.pending, self.fixedRefreshWorkItem == nil {
                self.scheduleFixedRefreshCheck()
            }
        }
        outputObservationTimer = outputTimer
        RunLoop.main.add(outputTimer, forMode: .common)

        // Backup timer — notifications handle most changes, this catches edge cases
        displayCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.periodicDisplayCheck()
        }

        // Monitor for system wake to restore HiDPI configuration
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugLog(">>> System wake notification received")
            self?.handleWakeFromSleep()
        }

        // Track display sleep so a dark panel isn't treated as an unplug
        screenSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugLog(">>> Screens did sleep — deferring disconnect handling")
            self?.screensAsleep = true
            self?.beginOutputRestore()
        }

        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugLog(">>> Screens did wake")
            self?.screensAsleep = false
            self?.beginOutputRestore()
            self?.scheduleFixedRefreshCheck()
            // The panel takes a few seconds to re-enumerate; the display-change
            // notification then repairs the mirror if it broke. The periodic
            // check is the backstop if no notification arrives.
        }

        debugLog("Display change monitoring started (notification + timer + wake + screen sleep)")
        // The monitor may already be back before the cleanup process restarts;
        // a new notification is not guaranteed. Start the readiness check now.
        if wasDisconnected {
            DispatchQueue.main.async { [weak self] in self?.handleDisplayConfigurationChange() }
        }
    }

    func stopDisplayChangeMonitoring() {
        outputObservationTimer?.invalidate()
        outputObservationTimer = nil
        if outputCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                outputReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
            outputCallbackRegistered = false
        }
        if let observer = displayObserver {
            NotificationCenter.default.removeObserver(observer)
            displayObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        if let observer = screenSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            screenSleepObserver = nil
        }
        if let observer = screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            screenWakeObserver = nil
        }
        fixedRefreshWorkItem?.cancel()
        fixedRefreshWorkItem = nil
        mirrorReattachWorkItem?.cancel()
        mirrorReattachWorkItem = nil
        displayCheckTimer?.invalidate()
        displayCheckTimer = nil
        debugLog("Display change monitoring stopped")
    }

    func periodicDisplayCheck() {
        // Don't trigger cleanup during setup or pending restart
        if isSettingUp || isRestarting { return }

        // HDR may change the output timing without changing the display count.
        scheduleFixedRefreshCheck()

        // HDMI hotplug can reuse both the display ID and the display count.
        // Recheck the real target and mirror even when the count is unchanged.
        let realMonitor = findRealPhysicalMonitor()

        // Case 1: HiDPI active but monitor disconnected
        if isActive && realMonitor == nil {
            debugLog(">>> Periodic check: Physical monitor gone - confirming before cleanup")
            scheduleDisconnectConfirmation()
            return
        }

        if isActive && realMonitor != nil {
            ensureMirrorIntact()
            return
        }

        // Case 1b: Orphaned virtual display exists (monitor gone, but isActive is false)
        // This can happen if mirror failed or app state got out of sync
        if !isActive && realMonitor == nil && hasOrphanedVirtualDisplay() {
            debugLog(">>> Periodic check: Orphaned virtual display detected - confirming before cleanup")
            scheduleDisconnectConfirmation()
            return
        }

        // A timed-out capability probe remains idle until the link changes or
        // the user explicitly retries. Do not repeat setup every 30 seconds.
        if !isActive && !shouldRetryConnection(on: realMonitor) { return }

        // Case 2: HiDPI not active, monitor reconnected, auto-apply enabled
        if !isActive && wasDisconnected && realMonitor != nil {
            let failCount = UserDefaults.standard.integer(forKey: kMirrorFailureCountKey)
            if failCount >= maxMirrorRetries {
                debugLog(">>> Periodic check: Monitor present but mirror failed \(failCount) times, not retrying (apply manually from menu)")
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                return
            }

            let autoApply = UserDefaults.standard.bool(forKey: kAutoApplyOnConnectKey)
            if autoApply, let lastPreset = UserDefaults.standard.string(forKey: kLastPresetKey), !lastPreset.isEmpty {
                if !connectedMonitorMatchesSavedPreset() {
                    debugLog(">>> Periodic check: Monitor present but doesn't match saved preset — skipping auto-apply")
                    return
                }
                debugLog(">>> Periodic check: Monitor reconnected - auto-applying \(lastPreset)")
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                restorePreset(lastPreset)
            }
        }
    }

    func handleWakeFromSleep() {
        // Don't restore during setup
        if isSettingUp || isRestarting {
            debugLog("Wake: Setup/restart in progress, skipping restore")
            return
        }

        // Check if we have a saved preset to restore
        guard let lastPreset = UserDefaults.standard.string(forKey: kLastPresetKey), !lastPreset.isEmpty else {
            debugLog("Wake: No saved preset to restore")
            return
        }

        debugLog(">>> Wake: assessing display state before deciding on restore")
        beginOutputRestore()

        // Mark as setting up to prevent other handlers from interfering
        isSettingUp = true
        setupGeneration += 1
        let generation = setupGeneration

        // Delay assessment to let the display system wake up, then decide the
        // LEAST destructive action. Destroying the virtual display evicts every
        // window living on it, which is why windows used to shuffle after sleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.assessDisplayStateAfterWake(preset: lastPreset, attempt: 1, generation: generation)
        }
    }

    /// Post-wake decision ladder: (1) mirror survived sleep — touch nothing;
    /// (2) virtual display alive but mirror broken — re-attach the mirror in
    /// place so windows stay put; (3) otherwise fall back to the full
    /// teardown + rebuild. The external monitor can take several seconds to
    /// re-enumerate after wake (DP link retraining), so retry before giving up.
    func assessDisplayStateAfterWake(preset: String, attempt: Int, generation: Int) {
        guard generation == setupGeneration else {
            debugLog("Wake: assessment superseded by newer setup, aborting")
            return
        }

        guard findRealPhysicalMonitor(verbose: attempt == 1) != nil else {
            if attempt < 5 {
                debugLog("Wake: external monitor not enumerated yet (attempt \(attempt)/5), retrying in 2s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.assessDisplayStateAfterWake(preset: preset, attempt: attempt + 1, generation: generation)
                }
            } else {
                debugLog("Wake: no external monitor after \(attempt) attempts, leaving restore to reconnect handling")
                isSettingUp = false
            }
            return
        }

        if !connectedMonitorMatchesSavedPreset() {
            debugLog("Wake: connected monitor doesn't match saved preset — skipping restore")
            isSettingUp = false
            return
        }

        // Cases 1 and 2: the virtual display survived sleep. Keeping it alive
        // keeps every window exactly where it was.
        if ensureMirrorIntact() {
            debugLog("Wake: virtual display intact — no rebuild needed, windows preserved")
            isSettingUp = false
            reassertPreferencesAfterSetup()
            return
        }

        if mirrorReattachWorkItem != nil || isRestarting {
            isSettingUp = false
            return
        }

        // Case 3: virtual display gone (or re-mirror failed) — full rebuild.
        debugLog(">>> Wake: full rebuild required, restoring preset: \(preset)")
        UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)
        restorePreset(preset)
    }

    /// True if `displayID` is currently in the online display list.
    func displayIsOnline(_ displayID: CGDirectDisplayID) -> Bool {
        guard displayID != 0 else { return false }
        var displayList = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayList, &displayCount)
        return displayList[0..<Int(displayCount)].contains(displayID)
    }

    /// If our virtual display is still online, make sure the physical monitor
    /// mirrors it — re-attaching the mirror in place when the link broke
    /// (sleep/wake and transient dropouts often sever just the mirror). The
    /// virtual display is never destroyed here, so windows don't move.
    /// Returns false when there is nothing usable to re-attach.
    @discardableResult
    func ensureMirrorIntact() -> Bool {
        // findExternalDisplay (not findRealPhysicalMonitor) so that with
        // multiple externals we re-attach to the fingerprint-matched monitor,
        // not whichever one CoreGraphics lists first.
        guard isActive, currentVirtualID != 0, displayIsOnline(currentVirtualID),
              let physical = findExternalDisplay() else {
            return false
        }
        // macOS can give the same monitor a new ID after reconnecting even
        // when it has already restored the mirror. Rebind before the no-op.
        if targetExternalDisplayID != physical {
            targetExternalDisplayID = physical
            prepareOutputPreference(for: physical)
            beginOutputRestore()
        }
        if CGDisplayMirrorsDisplay(physical) == currentVirtualID {
            return true
        }
        guard mirrorReattachWorkItem == nil else { return false }
        guard let requirement = requiredTiming(for: physical),
              let capabilities = linkCapabilities(for: physical),
              requirement.accepts(capabilities),
              let sourceMode = CGDisplayCopyDisplayMode(currentVirtualID),
              abs(sourceMode.refreshRate - requirement.refreshRate) <= 0.5 else {
            suspendMirrorForConnection("Connection timing changed during reconnect")
            return false
        }
        prepareOutputPreference(for: physical)
        beginOutputRestore()
        connectionReadiness = DisplayConnectionReadiness()
        setupGeneration += 1
        let generation = setupGeneration
        debugLog("Mirror link broken — waiting for stable native timing before re-attaching")
        scheduleMirrorReattach(physical: physical, requirement: requirement, generation: generation)
        return false
    }

    private func scheduleMirrorReattach(physical: CGDirectDisplayID,
                                        requirement: DisplayTimingRequirement, generation: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.mirrorReattachWorkItem = nil
            guard generation == self.setupGeneration, self.isActive, !self.isRestarting,
                  !self.screensAsleep, self.displayIsOnline(self.currentVirtualID) else { return }
            let capabilities = self.linkCapabilities(for: physical)
            guard let capabilities = capabilities, requirement.accepts(capabilities) else {
                self.suspendMirrorForConnection("Waiting for the previous native timing")
                return
            }
            switch self.connectionReadiness.observe(capabilities, requiring: requirement,
                                                     at: ProcessInfo.processInfo.systemUptime) {
            case .waiting:
                self.scheduleMirrorReattach(physical: physical, requirement: requirement, generation: generation)
            case .timedOut:
                self.suspendMirrorForConnection("Connection did not settle")
            case .ready:
                let ok = VirtualDisplayManager.shared().mirrorDisplay(
                    self.currentVirtualID, toDisplay: physical, atRate: requirement.refreshRate)
                debugLog("Stable mirror re-attach result: \(ok)")
                if ok {
                    self.targetExternalDisplayID = physical
                    self.reassertPreferencesAfterSetup()
                } else {
                    self.suspendMirrorForConnection("Mirror timing changed while applying")
                }
            }
        }
        mirrorReattachWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Release the virtual desktop once, then let the next process wait without
    /// a hidden/incorrect desktop or stale per-process display mode enumeration.
    private func suspendMirrorForConnection(_ reason: String) {
        guard !isRestarting else { return }
        let attempts = UserDefaults.standard.integer(forKey: kConnectionRecoveryCountKey) + 1
        UserDefaults.standard.set(attempts, forKey: kConnectionRecoveryCountKey)
        debugLog("Connection recovery \(attempts)/3: \(reason); releasing mirror before waiting")
        beginOutputRestore()
        if attempts <= 3 {
            wasDisconnected = true
            cleanupAfterDisconnect()
        } else {
            // One final clean restart removes the virtual display but does not
            // auto-apply again. Only an explicit preset/rate choice resets this.
            isRestarting = true
            wasDisconnected = false
            UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
            UserDefaults.standard.set(false, forKey: kWasCrashKey)
            relaunchApp()
        }
    }

    /// Settle fixed physical timing first, then restore HDR and the exact link
    /// format. Pinning a timing after restoring HDR can otherwise undo it.
    func reassertPreferencesAfterSetup() {
        fixedRefreshRepairAttempts = 0
        beginOutputRestore()
        scheduleFixedRefreshCheck()
        let generation = setupGeneration
        if UserDefaults.standard.bool(forKey: kKeepPrimaryDisplayKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self = self, generation == self.setupGeneration,
                      self.isActive, !self.isRestarting, !self.screensAsleep else { return }
                self.applyPrimaryDisplayPreference()
            }
        }
    }

    /// HDR and link reconfiguration can re-enable VRR on an otherwise intact
    /// mirror. Debounce notifications, touch only our active target, and stop
    /// after three failed repairs until a stable mode or a new setup is observed.
    func scheduleFixedRefreshCheck() {
        guard isActive, !isSettingUp, !isRestarting, !screensAsleep else { return }
        fixedRefreshWorkItem?.cancel()
        let generation = setupGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.fixedRefreshWorkItem = nil
            let target = self.targetExternalDisplayID
            guard generation == self.setupGeneration,
                  self.isActive, !self.isSettingUp, !self.isRestarting, !self.screensAsleep,
                  target != 0, self.currentVirtualID != 0,
                  self.displayIsOnline(target), self.displayIsOnline(self.currentVirtualID),
                  CGDisplayMirrorsDisplay(target) == self.currentVirtualID else { return }

            VirtualDisplayManager.shared().repairDockPlacement(
                forSource: self.currentVirtualID, mirroredToDisplay: target)
            self.observeManualHDRSelection()
            guard let requirement = self.requiredTiming(for: target),
                  let capabilities = self.linkCapabilities(for: target),
                  requirement.accepts(capabilities),
                  let source = CGDisplayCopyDisplayMode(self.currentVirtualID),
                  abs(source.refreshRate - requirement.refreshRate) <= 0.5 else {
                self.suspendMirrorForConnection("Native mode or source refresh no longer matches")
                return
            }
            if self.physicalTimingMatches(target, requirement: requirement) {
                self.fixedRefreshRepairAttempts = 0
                self.rememberStableTiming(requirement, for: target)
                self.restoreOutputPreferenceIfNeeded()
                return
            }
            guard self.fixedRefreshRepairAttempts < 3 else {
                self.suspendMirrorForConnection("Physical timing failed verification three times")
                return
            }
            // A manual HDR change may have enabled VRR. Its stable choice has
            // been captured above; do not learn the pin's transient SDR state.
            if !self.outputRestore.pending { self.beginOutputRestore() }
            self.outputObservationAfter = Date().timeIntervalSinceReferenceDate + 4
            self.fixedRefreshRepairAttempts += 1
            let ok = VirtualDisplayManager.shared().pinNativeMode(
                forDisplay: target, atRate: requirement.refreshRate)
            debugLog("Fixed refresh repair \(self.fixedRefreshRepairAttempts)/3: \(ok)")
            self.scheduleFixedRefreshCheck()
        }
        fixedRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func handleDisplayConfigurationChange() {
        debugLog("Display configuration changed, checking state...")
        observeManualHDRSelection()

        // Don't trigger cleanup during setup or pending restart
        if isSettingUp || isRestarting {
            debugLog("Setup/restart in progress, skipping disconnect check")
            return
        }

        // Case 1: HiDPI is active, check if physical monitor was disconnected
        if isActive && currentVirtualID != 0 {
            // Only check if the real physical monitor is still connected
            // Don't check mirroring status - macOS can break mirroring unexpectedly
            let realMonitor = findRealPhysicalMonitor(verbose: true)

            if realMonitor == nil {
                debugLog("Physical monitor not found - confirming before cleanup")
                scheduleDisconnectConfirmation()
                return
            } else {
                debugLog("Physical monitor still connected: \(realMonitor!)")
                // Sleep or a transient dropout may have severed just the
                // mirror (e.g. the monitor enumerated after the wake
                // assessment gave up). Repair in place; no-op when intact.
                ensureMirrorIntact()
                scheduleFixedRefreshCheck()
            }
            return
        }

        // Case 2: HiDPI is not active, check if monitor was reconnected
        let realMonitor = findRealPhysicalMonitor(verbose: true)
        if !isActive && realMonitor != nil && wasDisconnected {
            guard shouldRetryConnection(on: realMonitor) else { return }
            let failCount = UserDefaults.standard.integer(forKey: kMirrorFailureCountKey)
            if failCount >= maxMirrorRetries {
                debugLog("Display reconnected but mirror failed \(failCount) times, not retrying (apply manually from menu)")
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                return
            }

            debugLog("External display reconnected")

            let autoApply = UserDefaults.standard.bool(forKey: kAutoApplyOnConnectKey)
            if autoApply, let lastPreset = UserDefaults.standard.string(forKey: kLastPresetKey), !lastPreset.isEmpty {
                if !connectedMonitorMatchesSavedPreset() {
                    debugLog("Display reconnected but doesn't match saved preset — skipping auto-apply")
                    wasDisconnected = false
                    UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                    return
                }
                debugLog("Auto-applying last preset: \(lastPreset)")
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)

                // Delay to let the display settle. Generation-guarded so a
                // manual apply during the delay isn't clobbered by this
                // stale reconnect restore.
                let generation = setupGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, generation == self.setupGeneration else {
                        debugLog("Reconnect restore superseded by newer action, skipping")
                        return
                    }
                    self.restorePreset(lastPreset)
                }
            } else {
                debugLog("Auto-apply disabled or no saved preset")
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
            }
        }
    }

    // Find a real physical monitor (not built-in, not virtual, not a ghost/phantom display)
    func findRealPhysicalMonitor(verbose: Bool = false) -> CGDirectDisplayID? {
        var displayList = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayList, &displayCount)

        for i in 0..<Int(displayCount) {
            let displayID = displayList[i]
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let vendorID = CGDisplayVendorNumber(displayID)

            // Our virtual displays use vendor ID 0x1234 (4660 decimal)
            let isVirtualDisplay = vendorID == 0x1234

            // Vendor 0x756E6B6E (1970170734) = "unkn" in ASCII — macOS placeholder for
            // displays whose EDID hasn't been read yet. These are ghost/phantom displays
            // from Thunderbolt hubs, USB-C ports, or DisplayPort MST during initialization.
            // Mirroring to them always fails.
            let isGhostDisplay = vendorID == 0x756E6B6E

            if verbose {
                // CGDisplayScreenSize on virtual displays kicks off ColorSync lookups that peg the CPU
                if !isVirtualDisplay {
                    let size = CGDisplayScreenSize(displayID)
                    debugLog("  Display \(displayID): builtin=\(isBuiltin), vendor=\(vendorID), virtual=\(isVirtualDisplay), ghost=\(isGhostDisplay), size=\(size.width)mm")
                } else {
                    debugLog("  Display \(displayID): builtin=\(isBuiltin), vendor=\(vendorID), virtual=\(isVirtualDisplay), size=skipped")
                }
            }

            // Real monitors are: not built-in, not virtual (0x1234), not ghost (0x756E6B6E "unkn")
            if !isBuiltin && !isVirtualDisplay && !isGhostDisplay {
                if verbose {
                    debugLog("Found real physical monitor: \(displayID) (vendor: \(vendorID))")
                }
                return displayID
            }
        }
        if verbose {
            debugLog("No real physical monitor found")
        }
        return nil
    }

    // Check if there's an orphaned virtual display (vendor 0x1234) that we created
    func hasOrphanedVirtualDisplay() -> Bool {
        var displayList = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayList, &displayCount)

        for i in 0..<Int(displayCount) {
            let displayID = displayList[i]
            // Skip the display we currently own — it's not orphaned
            if currentVirtualID != 0 && displayID == currentVirtualID { continue }
            let vendorID = CGDisplayVendorNumber(displayID)
            // Our virtual displays use vendor ID 0x1234 (4660 decimal)
            if vendorID == 0x1234 {
                debugLog("Found orphaned virtual display: \(displayID)")
                return true
            }
        }
        return false
    }

    /// The monitor can vanish from the display list for a few seconds without
    /// being unplugged — DisplayPort link retraining on wake, the panel
    /// power-cycling, or EDID re-reads (it shows up as a ghost "unkn" display
    /// meanwhile). Tearing down the virtual display for those transients
    /// evicts every window from the desktop, so confirm the monitor is really
    /// gone across several checks before cleaning up. If it comes back, just
    /// repair the mirror in place.
    func scheduleDisconnectConfirmation() {
        if disconnectConfirmationPending || isSettingUp || isRestarting { return }
        if screensAsleep {
            debugLog("Monitor gone but screens are asleep — not a disconnect, deferring")
            return
        }
        beginOutputRestore()
        disconnectConfirmationPending = true
        debugLog("Disconnect suspected — re-checking for \(3 * 4)s before tearing down")
        confirmDisconnect(attempt: 1)
    }

    private func confirmDisconnect(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self else { return }
            if self.isSettingUp || self.isRestarting || self.screensAsleep {
                self.disconnectConfirmationPending = false
                return
            }
            if self.findRealPhysicalMonitor() != nil {
                self.disconnectConfirmationPending = false
                debugLog("Monitor is back (transient dropout) — verifying mirror instead of cleaning up")
                if self.isActive && !self.ensureMirrorIntact() {
                    if self.mirrorReattachWorkItem != nil || self.isRestarting { return }
                    // Virtual display didn't survive the dropout — full restore.
                    if let preset = UserDefaults.standard.string(forKey: self.kLastPresetKey), !preset.isEmpty {
                        debugLog("Mirror unrecoverable after dropout — rebuilding")
                        UserDefaults.standard.set(0, forKey: self.kMirrorFailureCountKey)
                        self.isSettingUp = true
                        self.setupGeneration += 1
                        self.restorePreset(preset)
                    }
                } else if self.isActive {
                    self.reassertPreferencesAfterSetup()
                }
                return
            }
            if attempt < 3 {
                debugLog("Monitor still gone (check \(attempt)/3)")
                self.confirmDisconnect(attempt: attempt + 1)
                return
            }
            self.disconnectConfirmationPending = false
            debugLog("Disconnect confirmed after \(attempt) checks - cleaning up")
            self.wasDisconnected = true
            UserDefaults.standard.set(0, forKey: self.kMirrorFailureCountKey)  // Reset for reconnection
            self.cleanupAfterDisconnect()
        }
    }

    func cleanupAfterDisconnect() {
        // Re-entrancy guard: a second display-change notification during
        // cleanup used to spawn a second relaunch (observed in the wild —
        // two cleanups within one second).
        if isRestarting {
            debugLog("Disconnect cleanup already in progress, ignoring")
            return
        }
        isRestarting = true
        debugLog(">>> Starting disconnect cleanup")

        // Mark that we're disconnected (for auto-restore on reconnect)
        UserDefaults.standard.set(true, forKey: kWasDisconnectedKey)

        // The CGVirtualDisplay framework doesn't actually destroy displays when we release
        // the object - they persist until the app terminates. The only reliable way to
        // clean up orphaned virtual displays is to restart the app.
        debugLog(">>> Restarting app to clean up virtual displays...")

        // Relaunch the app
        relaunchApp()
    }

    private let kWasDisconnectedKey = "wasDisconnected"

    func relaunchApp() {
        captureHDRBeforeTeardown()
        // Switching a preset (or cleaning up after a disconnect) restarts the app
        // so macOS reclaims the old virtual display object — CGVirtualDisplay only
        // frees on process exit. Coming back reliably needs BOTH mechanisms below,
        // because neither covers every install on its own:
        //
        //  * Under the launch agent (com.hidpi.g9helper, KeepAlive with
        //    SuccessfulExit=false) a CLEAN exit (0) is read as "user quit" and the
        //    job is left dead. The old code called NSApp.terminate(nil), which
        //    exits 0, so picking a resolution killed the menu-bar app for good
        //    (looked like a crash). Reopening a KeepAlive-suppressed job with
        //    `open` is also refused, so the helper alone could not revive it.
        //    Exiting NON-ZERO flips launchd's decision to "relaunch" — the
        //    deterministic path.
        //
        //  * Drag-installed with no agent (or the Start-at-Login plist is written
        //    but not yet loaded, before the next login) a non-zero exit relaunches
        //    nothing, so a detached helper reopens the bundle. It waits for this
        //    process to fully exit, pauses past the agent's ThrottleInterval, then
        //    reopens ONLY if nothing came back on its own — so it never spawns a
        //    duplicate alongside a launchd relaunch.
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "for i in $(seq 1 40); do /usr/bin/pgrep -x HiDPIDisplay >/dev/null || break; /bin/sleep 0.5; done; /bin/sleep 5; /usr/bin/pgrep -x HiDPIDisplay >/dev/null || /usr/bin/open \"\(bundlePath)\""]
        task.launch()

        // Run the same teardown applicationWillTerminate would (exit() bypasses
        // it) so the preset is preserved for auto-restore, then exit non-zero so
        // the launch agent's KeepAlive brings us right back.
        stopDisplayChangeMonitoring()
        disableHiDPIForDisconnect()
        debugLog("Restarting to switch preset (exit non-zero; helper on standby)")
        exit(2)
    }

    private let cleanupMarkerPath = "/tmp/g9helper-cleanup-marker"

    /// Check if this launch is a cleanup restart (prevent infinite restart loops)
    func isCleanupRestart() -> Bool {
        guard FileManager.default.fileExists(atPath: cleanupMarkerPath) else { return false }
        // Only treat as cleanup restart if marker is recent (within 30 seconds)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cleanupMarkerPath),
              let date = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(date) < 30 else {
            try? FileManager.default.removeItem(atPath: cleanupMarkerPath)
            return false
        }
        try? FileManager.default.removeItem(atPath: cleanupMarkerPath)
        return true
    }

    /// Mark that we're about to do a cleanup restart
    func markCleanupRestart() {
        FileManager.default.createFile(atPath: cleanupMarkerPath, contents: nil)
    }

    // Disable HiDPI when monitor is disconnected - preserves preset for auto-restore
    func disableHiDPIForDisconnect() {
        debugLog("Disabling HiDPI for disconnect (preserving preset) - currentVirtualID: \(currentVirtualID)")
        setupGeneration += 1  // Cancel any in-flight setup steps
        isSettingUp = false   // A cancelled setup step won't clear this itself
        mirrorReattachWorkItem?.cancel()
        mirrorReattachWorkItem = nil

        let manager = VirtualDisplayManager.shared()

        // Reset ALL mirroring to ensure clean state
        manager.resetAllMirroring()

        // Destroy our virtual display
        manager.destroyAllVirtualDisplays()

        currentVirtualID = 0
        targetExternalDisplayID = 0
        isActive = false
        currentPresetName = ""

        // DO NOT clear saved preset - we want to restore it when monitor reconnects
        debugLog("HiDPI disabled (preset preserved for reconnection)")
    }

    // NOTE: earlier versions force-moved every window of every app to
    // {100,100} via System Events AppleScript whenever the display went away.
    // That erased macOS's own per-display window layout memory, so windows
    // never returned to their original screen on reconnect (issue #10), and it
    // triggered an Automation permission prompt. macOS already relocates
    // windows from a removed display and restores them when it returns, so we
    // let it.

    func checkAndRestoreFromCrash() {
        let wasRunning = UserDefaults.standard.bool(forKey: kWasCrashKey)
        let autoRestore = UserDefaults.standard.bool(forKey: kAutoRestoreKey)

        // Default to auto-restore enabled
        if UserDefaults.standard.object(forKey: kAutoRestoreKey) == nil {
            UserDefaults.standard.set(true, forKey: kAutoRestoreKey)
        }

        // Default to auto-apply on reconnect enabled
        if UserDefaults.standard.object(forKey: kAutoApplyOnConnectKey) == nil {
            UserDefaults.standard.set(true, forKey: kAutoApplyOnConnectKey)
        }

        // If we restarted after disconnect (not crash), don't try to restore here
        // Let the reconnect detection handle it when monitor is plugged back in
        if wasDisconnected {
            debugLog("Restarted after disconnect - waiting for monitor reconnection")
            return
        }

        if wasRunning && autoRestore {
            if let lastPreset = UserDefaults.standard.string(forKey: kLastPresetKey),
               !lastPreset.isEmpty {
                // Only restore if external display is connected
                if findExternalDisplay() != nil {
                    if !connectedMonitorMatchesSavedPreset() {
                        debugLog("Detected restart after crash, but connected monitor doesn't match saved preset — skipping auto-restore")
                        return
                    }
                    debugLog("Detected restart after crash, auto-restoring preset: \(lastPreset)")

                    // Delay restoration to let the system settle.
                    // Generation-guarded against a manual apply in between.
                    let generation = setupGeneration
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self, generation == self.setupGeneration else {
                            debugLog("Crash-restore superseded by newer action, skipping")
                            return
                        }
                        self.restorePreset(lastPreset)
                    }
                } else {
                    debugLog("Detected restart after crash, but no external display - waiting for reconnection")
                    wasDisconnected = true
                    UserDefaults.standard.set(true, forKey: kWasDisconnectedKey)
                }
            }
        }

        // Clear the crash flag (will be set again when app is running)
        UserDefaults.standard.set(false, forKey: kWasCrashKey)
    }

    // Map old preset names to new ones for backwards compatibility
    func migratePresetName(_ oldName: String) -> String {
        let migrations: [String: String] = [
            "g9-native-hidpi": "g9-57-3840x1080",
            "g9-5120x1440": "g9-57-5120x1440",
            "g9-4800x1350": "g9-57-4800x1350",
            "g9-4480x1260": "g9-57-4389x1234",  // closest match
            "g9-49-native": "g9-49-2560x720",
            "g9-49-3840x1080": "g9-49-3840x1080",  // same
            "uw34-2560x1080": "uw34-2293x960",  // closest match
            "4k-native": "4k-1920x1080",
            "4k-2560x1440": "4k-2560x1440",  // same
        ]
        return migrations[oldName] ?? oldName
    }

    func restorePreset(_ presetName: String) {
        let migratedName = migratePresetName(presetName)
        let config: PresetConfig

        if let standard = presetConfigs[migratedName] {
            config = standard
        } else if presetName.hasPrefix("custom-"),
                  let dict = UserDefaults.standard.dictionary(forKey: "customPresetConfig"),
                  let name = dict["name"] as? String,
                  let width = (dict["width"] as? NSNumber)?.uint32Value,
                  let height = (dict["height"] as? NSNumber)?.uint32Value,
                  let logicalWidth = (dict["logicalWidth"] as? NSNumber)?.uint32Value,
                  let logicalHeight = (dict["logicalHeight"] as? NSNumber)?.uint32Value,
                  let ppi = (dict["ppi"] as? NSNumber)?.uint32Value,
                  let hiDPI = dict["hiDPI"] as? Bool {
            config = PresetConfig(name: name, width: width, height: height, logicalWidth: logicalWidth, logicalHeight: logicalHeight, ppi: ppi, hiDPI: hiDPI)
        } else {
            debugLog("ERROR: Unknown preset for restore: \(presetName) (migrated: \(migratedName))")
            // Callers (e.g. the wake path) may have set isSettingUp before
            // calling us — clear it or disconnect/reconnect handling stays
            // disabled until the next app restart.
            isSettingUp = false
            return
        }

        // Update saved preset to new name if migrated
        if migratedName != presetName {
            debugLog("Migrated preset name: \(presetName) -> \(migratedName)")
            saveCurrentPreset(migratedName)
        }

        debugLog(">>> Auto-restoring preset: \(presetName)")
        if let physical = findExternalDisplay() { prepareOutputPreference(for: physical) }
        beginOutputRestore()

        // Mark that we're setting up (don't trigger cleanup during setup)
        isSettingUp = true
        setupGeneration += 1
        let generation = setupGeneration

        StatusWindowController.shared.show(message: "Restoring display configuration...")

        let manager = VirtualDisplayManager.shared()
        manager.resetAllMirroring()
        manager.destroyAllVirtualDisplays()
        currentVirtualID = 0
        isActive = false
        currentPresetName = ""

        // Schedule creation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            autoreleasepool {
                self?.createVirtualDisplayAsync(config: config, generation: generation)
            }
        }

        // Re-save the preset since we're using it
        saveCurrentPreset(presetName)
    }

    func saveCurrentPreset(_ presetName: String) {
        connectionRecoveryBlocked = false
        blockedConnectionCapabilities = nil
        connectionReadinessGeneration = -1
        connectionRecoveryMessage = nil
        UserDefaults.standard.set(presetName, forKey: kLastPresetKey)
        UserDefaults.standard.set(true, forKey: kWasCrashKey)
        debugLog("Saved preset for crash recovery: \(presetName)")
    }

    func clearSavedPreset() {
        UserDefaults.standard.removeObject(forKey: kLastPresetKey)
        UserDefaults.standard.set(false, forKey: kWasCrashKey)
        debugLog("Cleared saved preset")
    }

    func cleanupStaleState() {
        debugLog("Cleaning up stale display state...")
        let manager = VirtualDisplayManager.shared()

        // Check if we have an external display connected
        let hasExternalDisplay = findExternalDisplay() != nil
        debugLog("External display connected: \(hasExternalDisplay)")

        // Reset any existing mirroring that might be left over
        manager.resetAllMirroring()

        // Destroy any virtual displays from previous session
        manager.destroyAllVirtualDisplays()

        debugLog("Stale state cleanup complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("App terminating - cleaning up...")
        captureHDRBeforeTeardown()

        // Stop monitoring
        stopDisplayChangeMonitoring()

        // Disable HiDPI but preserve preset for auto-restore on next launch
        disableHiDPIForDisconnect()

        debugLog("Cleanup complete, terminating")
    }

    func checkCurrentState() {
        // Check if there's an active mirror setup
        var displayList = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayList, &displayCount)

        for i in 0..<Int(displayCount) {
            let displayID = displayList[i]
            let mirrorOf = CGDisplayMirrorsDisplay(displayID)
            if mirrorOf != kCGNullDirectDisplay {
                // Only claim mirror sets whose master is one of our virtual
                // displays (vendor 0x1234) — a mirror the user configured
                // between two of their own displays isn't ours and must not
                // flip the app to "active".
                guard CGDisplayVendorNumber(mirrorOf) == 0x1234 else { continue }
                if let mode = CGDisplayCopyDisplayMode(mirrorOf) {
                    let width = mode.width
                    let height = mode.height
                    currentPresetName = "\(width)x\(height)"
                    isActive = true
                    debugLog("Found existing mirror: \(displayID) mirrors \(mirrorOf) at \(width)x\(height)")
                }
                break
            }
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        // Status header
        if isActive {
            let statusItem = NSMenuItem(title: "Active: \(currentPresetName)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem.separator())

            let disableItem = NSMenuItem(title: "Disable HiDPI", action: #selector(disableHiDPIAction), keyEquivalent: "")
            disableItem.target = self
            menu.addItem(disableItem)
            menu.addItem(NSMenuItem.separator())
        } else {
            let statusItem = NSMenuItem(title: "No HiDPI active", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(NSMenuItem.separator())
        }

        if let message = connectionRecoveryMessage {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        let colorMenu = NSMenu()
        colorMenu.delegate = self
        outputMenu = colorMenu
        populateOutputMenu(colorMenu)
        let colorItem = NSMenuItem(title: "HDR & Color Output", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        menu.addItem(NSMenuItem.separator())

        // 8K UHD (7680x4320), a 16:9 panel rather than the G9's 32:9 grid.
        let k8Menu = NSMenu()
        addPresetItem(to: k8Menu, preset: "8k-6144x3456", title: "6144×3456 (125%) - More Space")
        addPresetItem(to: k8Menu, preset: "8k-5760x3240", title: "5760×3240 (133.3%)")
        addPresetItem(to: k8Menu, preset: "8k-5120x2880", title: "5120×2880 (150%)")
        addPresetItem(to: k8Menu, preset: "8k-4800x2700", title: "4800×2700 (160%)")
        addPresetItem(to: k8Menu, preset: "8k-4384x2466", title: "4384×2466 (≈175%)")
        addPresetItem(to: k8Menu, preset: "8k-4096x2304", title: "4096×2304 (187.5%)")
        addPresetItem(to: k8Menu, preset: "8k-3840x2160", title: "3840×2160 (200%) - Native 2x")
        addCustomScaleItem(to: k8Menu, nativeWidth: 7680, nativeHeight: 4320, ppi: 163)

        let k8Item = NSMenuItem(title: "8K UHD Displays (7680×4320)", action: nil, keyEquivalent: "")
        k8Item.submenu = k8Menu
        menu.addItem(k8Item)

        // Samsung G9 57" (7680x2160) presets - ordered by scale factor (smaller = more space)
        let g9Menu = NSMenu()
        addPresetItem(to: g9Menu, preset: "g9-57-6144x1728", title: "6144×1728 (1.25x) - More Space")
        addPresetItem(to: g9Menu, preset: "g9-57-5908x1662", title: "5908×1662 (1.3x)")
        addPresetItem(to: g9Menu, preset: "g9-57-5632x1584", title: "5632×1584 (1.36x)")
        addPresetItem(to: g9Menu, preset: "g9-57-5486x1543", title: "5486×1543 (1.4x)")
        addPresetItem(to: g9Menu, preset: "g9-57-5297x1490", title: "5297×1490 (1.45x)")
        addPresetItem(to: g9Menu, preset: "g9-57-5120x1440", title: "5120×1440 (1.5x) ★ Recommended")
        addPresetItem(to: g9Menu, preset: "g9-57-4800x1350", title: "4800×1350 (1.6x)")
        addPresetItem(to: g9Menu, preset: "g9-57-4389x1234", title: "4389×1234 (1.75x)")
        addPresetItem(to: g9Menu, preset: "g9-57-3840x1080", title: "3840×1080 (2.0x) - Larger Text")
        addCustomScaleItem(to: g9Menu, nativeWidth: 7680, nativeHeight: 2160, ppi: 140)

        let g9Item = NSMenuItem(title: "Samsung G9 57\"", action: nil, keyEquivalent: "")
        g9Item.submenu = g9Menu
        menu.addItem(g9Item)

        // Samsung G9 49" (5120x1440) presets
        let g49Menu = NSMenu()
        addPresetItem(to: g49Menu, preset: "g9-49-4096x1152", title: "4096×1152 (1.25x) - More Space")
        addPresetItem(to: g49Menu, preset: "g9-49-3938x1108", title: "3938×1108 (1.3x)")
        addPresetItem(to: g49Menu, preset: "g9-49-3840x1080", title: "3840×1080 (1.33x) ★ Recommended")
        addPresetItem(to: g49Menu, preset: "g9-49-3413x960", title: "3413×960 (1.5x)")
        addPresetItem(to: g49Menu, preset: "g9-49-2926x823", title: "2926×823 (1.75x)")
        addPresetItem(to: g49Menu, preset: "g9-49-2560x720", title: "2560×720 (2.0x) - Larger Text")
        addCustomScaleItem(to: g49Menu, nativeWidth: 5120, nativeHeight: 1440, ppi: 109)

        let g49Item = NSMenuItem(title: "Samsung G9 49\"", action: nil, keyEquivalent: "")
        g49Item.submenu = g49Menu
        menu.addItem(g49Item)

        // 34" Ultrawide (3440x1440) presets
        let uwMenu = NSMenu()
        addPresetItem(to: uwMenu, preset: "uw34-2752x1152", title: "2752×1152 (1.25x) - More Space")
        addPresetItem(to: uwMenu, preset: "uw34-2646x1108", title: "2646×1108 (1.3x)")
        addPresetItem(to: uwMenu, preset: "uw34-2293x960", title: "2293×960 (1.5x) ★ Recommended")
        addPresetItem(to: uwMenu, preset: "uw34-1966x823", title: "1966×823 (1.75x)")
        addPresetItem(to: uwMenu, preset: "uw34-1720x720", title: "1720×720 (2.0x) - Larger Text")
        addCustomScaleItem(to: uwMenu, nativeWidth: 3440, nativeHeight: 1440, ppi: 110)

        let uwItem = NSMenuItem(title: "34\" Ultrawide (3440×1440)", action: nil, keyEquivalent: "")
        uwItem.submenu = uwMenu
        menu.addItem(uwItem)

        // 38" Ultrawide (3840x1600) presets
        let uw38Menu = NSMenu()
        addPresetItem(to: uw38Menu, preset: "uw38-3072x1280", title: "3072×1280 (1.25x) - More Space")
        addPresetItem(to: uw38Menu, preset: "uw38-2954x1231", title: "2954×1231 (1.3x)")
        addPresetItem(to: uw38Menu, preset: "uw38-2560x1067", title: "2560×1067 (1.5x) ★ Recommended")
        addPresetItem(to: uw38Menu, preset: "uw38-2194x914", title: "2194×914 (1.75x)")
        addPresetItem(to: uw38Menu, preset: "uw38-1920x800", title: "1920×800 (2.0x) - Larger Text")
        addCustomScaleItem(to: uw38Menu, nativeWidth: 3840, nativeHeight: 1600, ppi: 110)

        let uw38Item = NSMenuItem(title: "38\" Ultrawide (3840×1600)", action: nil, keyEquivalent: "")
        uw38Item.submenu = uw38Menu
        menu.addItem(uw38Item)

        // 4K (3840x2160) presets
        let k4Menu = NSMenu()
        addPresetItem(to: k4Menu, preset: "4k-3072x1728", title: "3072×1728 (1.25x) - More Space")
        addPresetItem(to: k4Menu, preset: "4k-2954x1662", title: "2954×1662 (1.3x)")
        addPresetItem(to: k4Menu, preset: "4k-2560x1440", title: "2560×1440 (1.5x) ★ Recommended")
        addPresetItem(to: k4Menu, preset: "4k-2194x1234", title: "2194×1234 (1.75x)")
        addPresetItem(to: k4Menu, preset: "4k-1920x1080", title: "1920×1080 (2.0x) - Larger Text")
        addCustomScaleItem(to: k4Menu, nativeWidth: 3840, nativeHeight: 2160, ppi: 163)

        let k4Item = NSMenuItem(title: "4K Displays (3840×2160)", action: nil, keyEquivalent: "")
        k4Item.submenu = k4Menu
        menu.addItem(k4Item)

        // Show cleanup option if orphaned virtual displays exist
        if hasOrphanedVirtualDisplay() {
            menu.addItem(NSMenuItem.separator())
            let cleanupItem = NSMenuItem(title: "Clean Up Phantom Displays", action: #selector(cleanUpDisplays), keyEquivalent: "")
            cleanupItem.target = self
            menu.addItem(cleanupItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Settings submenu
        let settingsMenu = NSMenu()

        let startAtLoginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin(_:)), keyEquivalent: "")
        startAtLoginItem.target = self
        startAtLoginItem.state = LaunchAgentManager.shared.isInstalled ? .on : .off
        settingsMenu.addItem(startAtLoginItem)

        let autoApplyItem = NSMenuItem(title: "Auto-Apply on Reconnect", action: #selector(toggleAutoApply(_:)), keyEquivalent: "")
        autoApplyItem.target = self
        autoApplyItem.state = UserDefaults.standard.bool(forKey: kAutoApplyOnConnectKey) ? .on : .off
        settingsMenu.addItem(autoApplyItem)

        let autoRestoreItem = NSMenuItem(title: "Auto-Restore After Crash", action: #selector(toggleAutoRestore(_:)), keyEquivalent: "")
        autoRestoreItem.target = self
        autoRestoreItem.state = UserDefaults.standard.bool(forKey: kAutoRestoreKey) ? .on : .off
        settingsMenu.addItem(autoRestoreItem)

        // Keep the external monitor as the main display (menu bar). macOS moves
        // the menu bar back to the built-in screen after sleep/wake; this
        // re-asserts the external monitor as primary whenever the mirror is set up.
        let keepPrimaryItem = NSMenuItem(title: "Keep External as Main Display", action: #selector(toggleKeepPrimary(_:)), keyEquivalent: "")
        keepPrimaryItem.target = self
        keepPrimaryItem.state = UserDefaults.standard.bool(forKey: kKeepPrimaryDisplayKey) ? .on : .off
        settingsMenu.addItem(keepPrimaryItem)

        let autoUpdateItem = NSMenuItem(title: "Check for Updates Automatically", action: #selector(toggleAutoUpdate(_:)), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.state = UpdateChecker.shared.autoCheckEnabled ? .on : .off
        settingsMenu.addItem(autoUpdateItem)

        settingsMenu.addItem(NSMenuItem.separator())

        // Refresh rate submenu
        let refreshMenu = NSMenu()
        let currentRate = UserDefaults.standard.double(forKey: kRefreshRateKey)
        let rates: [(String, Double)] = [
            ("Auto (detect from monitor)", 0.0),
            ("60 Hz", 60.0),
            ("120 Hz", 120.0),
            ("144 Hz", 144.0),
            ("165 Hz", 165.0),
            ("240 Hz", 240.0),
        ]
        for (title, rate) in rates {
            let item = NSMenuItem(title: title, action: #selector(setRefreshRate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate as NSNumber
            item.state = (currentRate == rate) ? .on : .off
            refreshMenu.addItem(item)
        }
        let refreshItem = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        refreshItem.submenu = refreshMenu
        settingsMenu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let checkUpdateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

        let aboutItem = NSMenuItem(title: "About G9 Helper", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc func toggleStartAtLogin(_ sender: NSMenuItem) {
        let wasInstalled = LaunchAgentManager.shared.isInstalled
        let success: Bool
        if wasInstalled {
            success = LaunchAgentManager.shared.uninstall()
            debugLog("Start at Login disabled: \(success)")
        } else {
            success = LaunchAgentManager.shared.install()
            debugLog("Start at Login enabled: \(success)")
        }
        rebuildMenu()
        if !success {
            let alert = NSAlert()
            alert.messageText = wasInstalled ? "Could Not Disable Start at Login" : "Could Not Enable Start at Login"
            alert.informativeText = "Make sure G9 Helper.app is installed in /Applications and try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func toggleAutoApply(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: kAutoApplyOnConnectKey)
        UserDefaults.standard.set(!current, forKey: kAutoApplyOnConnectKey)
        debugLog("Auto-apply on reconnect: \(!current)")
        rebuildMenu()
    }

    @objc func toggleAutoRestore(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: kAutoRestoreKey)
        UserDefaults.standard.set(!current, forKey: kAutoRestoreKey)
        debugLog("Auto-restore after crash: \(!current)")
        rebuildMenu()
    }

    @objc func toggleAutoUpdate(_ sender: NSMenuItem) {
        UpdateChecker.shared.autoCheckEnabled = !UpdateChecker.shared.autoCheckEnabled
        debugLog("Auto-check updates: \(UpdateChecker.shared.autoCheckEnabled)")
        rebuildMenu()
    }

    private func outputMonitorKey(_ target: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(target))-\(CGDisplayModelNumber(target))-\(CGDisplaySerialNumber(target))"
    }

    private func outputPreference(for target: CGDirectDisplayID) -> DisplayOutputPreference? {
        let records = UserDefaults.standard.dictionary(forKey: kOutputPreferencesKey) ?? [:]
        return (records[outputMonitorKey(target)] as? [String: Any])
            .flatMap(DisplayOutputPreference.init(dictionary:))
    }

    private func saveOutputPreference(_ preference: DisplayOutputPreference, for target: CGDirectDisplayID) {
        var records = UserDefaults.standard.dictionary(forKey: kOutputPreferencesKey) ?? [:]
        records[outputMonitorKey(target)] = preference.dictionary
        UserDefaults.standard.set(records, forKey: kOutputPreferencesKey)
        // A confirmed disconnect can immediately relaunch the app.
        UserDefaults.standard.synchronize()
    }

    private func prepareOutputPreference(for target: CGDirectDisplayID) {
        guard displayIsOnline(target), CGDisplayIsBuiltin(target) == 0,
              !VirtualDisplayManager.shared().isVirtualDisplay(target),
              outputPreference(for: target) == nil else { return }
        let manager = VirtualDisplayManager.shared()
        let legacy = UserDefaults.standard.bool(forKey: kKeepHDREnabledKey) &&
            !UserDefaults.standard.bool(forKey: "legacyHDRPreferenceMigrated")
        let hdr = legacy || manager.isHDREnabled(forDisplay: target)
        saveOutputPreference(DisplayOutputPreference(hdrEnabled: hdr), for: target)
        UserDefaults.standard.set(true, forKey: "legacyHDRPreferenceMigrated")
        debugLog("Output: saved initial HDR \(hdr) for monitor \(outputMonitorKey(target))")
    }

    func beginOutputRestore() {
        outputRestore.begin()
        outputRestoreMessage = nil
        hdrSelectionObserver.reset(to: hdrSelectionObserver.baseline)
    }

    func handleOutputTopologyChange(_ display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard isActive, display == targetExternalDisplayID else { return }
        if flags.contains(.removeFlag) || flags.contains(.addFlag) {
            // Topology changes are not a manual HDR-off choice. Preserve the
            // last stable preference before a reconnect defaults to SDR.
            beginOutputRestore()
            scheduleFixedRefreshCheck()
        }
    }

    private func stableOutputTarget() -> CGDirectDisplayID? {
        let target = targetExternalDisplayID
        guard isActive, !isSettingUp, !isRestarting, !screensAsleep,
              !disconnectConfirmationPending, displayIsOnline(target),
              displayIsOnline(currentVirtualID),
              CGDisplayMirrorsDisplay(target) == currentVirtualID else { return nil }
        return target
    }

    func observeManualHDRSelection() {
        guard !outputRestore.pending,
              Date().timeIntervalSinceReferenceDate >= outputObservationAfter,
              let target = stableOutputTarget() else { return }
        let manager = VirtualDisplayManager.shared()
        // A user's HDR toggle can itself enable VRR. Capture that choice
        // before pinning fixed timing, but still reject reduced-rate or scaled
        // physical modes seen during an incomplete HDMI reconnect.
        guard manager.displaySupportsHDR(target),
              let requirement = requiredTiming(for: target),
              physicalTimingMatches(target, requirement: requirement,
                                    requiresFixedRefresh: false) else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let hdr = manager.isHDREnabled(forDisplay: target)
        guard let changed = hdrSelectionObserver.observe(hdr, at: now),
              var preference = outputPreference(for: target) else { return }
        preference.hdrEnabled = changed
        saveOutputPreference(preference, for: target)
        debugLog("Output: remembered manual System Settings HDR \(changed)")
        beginOutputRestore()  // Also restore the chosen format for this HDR/SDR state.
        scheduleFixedRefreshCheck()
        rebuildMenu()
    }

    private func captureHDRBeforeTeardown() {
        let target = targetExternalDisplayID
        guard !outputRestore.pending, !screensAsleep, !disconnectConfirmationPending,
              Date().timeIntervalSinceReferenceDate >= outputObservationAfter,
              isActive, displayIsOnline(target), displayIsOnline(currentVirtualID),
              CGDisplayMirrorsDisplay(target) == currentVirtualID,
              VirtualDisplayManager.shared().displaySupportsHDR(target),
              outputRestoreMessage == nil,
              let requirement = requiredTiming(for: target),
              physicalTimingMatches(target, requirement: requirement),
              var preference = outputPreference(for: target) else { return }
        preference.hdrEnabled = VirtualDisplayManager.shared().isHDREnabled(forDisplay: target)
        saveOutputPreference(preference, for: target)
    }

    private func finishOutputRestore(actualHDR: Bool, message: String? = nil) {
        if let requirement = requiredTiming(for: targetExternalDisplayID),
           physicalTimingMatches(targetExternalDisplayID, requirement: requirement) {
            UserDefaults.standard.set(0, forKey: kConnectionRecoveryCountKey)
        }
        outputRestore.finish()
        forceAutomaticOutput = false
        hdrSelectionObserver.reset(to: actualHDR)
        outputObservationAfter = Date().timeIntervalSinceReferenceDate + 2
        outputRestoreMessage = message
        if let message = message { debugLog("Output: \(message)") }
        rebuildMenu()
    }

    func restoreOutputPreferenceIfNeeded() {
        guard outputRestore.pending, let target = stableOutputTarget(),
              let preference = outputPreference(for: target) else { return }
        let manager = VirtualDisplayManager.shared()
        let hdr = manager.isHDREnabled(forDisplay: target)
        let state = manager.outputState(forDisplay: target)
        let modes = (state?["modes"] as? [[String: Any]] ?? [])
            .compactMap(DisplayOutputMode.init(dictionary:))
        let current = (state?["current"] as? [String: Any]).flatMap(DisplayOutputMode.init(dictionary:))
        let preferred = preference.mode(forHDR: preference.hdrEnabled)
        let compatible = preferred.flatMap { modes.contains($0) ? $0 : nil }
        let unavailable = preferred != nil && compatible == nil
        let matches = hdr == preference.hdrEnabled &&
            (compatible == nil || compatible == current) && !forceAutomaticOutput
        if matches {
            debugLog("Output: restored \(current?.statusTitle ?? (hdr ? "HDR on" : "HDR off"))")
            finishOutputRestore(actualHDR: hdr, message: unavailable
                ? "Saved format unavailable at this timing; using macOS format." : nil)
            return
        }
        guard !preference.hdrEnabled || manager.displaySupportsHDR(target) else {
            finishOutputRestore(actualHDR: hdr, message: "HDR unavailable on this connection.")
            return
        }
        guard outputRestore.consumeAttempt() else {
            finishOutputRestore(actualHDR: hdr, message: "Setting did not hold. Select a format to retry.")
            return
        }
        outputObservationAfter = Date().timeIntervalSinceReferenceDate + 4
        let ok: Bool
        if let mode = compatible {
            ok = manager.setOutputMode(mode.dictionary, forDisplay: target)
        } else {
            // The SkyLight HDR setter selects macOS's default compatible link.
            // Calling it even when HDR already matches implements Automatic.
            ok = manager.setHDREnabled(preference.hdrEnabled, forDisplay: target)
        }
        if ok { forceAutomaticOutput = false }
        debugLog("Output: restore attempt \(outputRestore.attempts)/3 accepted=\(ok)")
        scheduleFixedRefreshCheck() // Recheck fixed refresh AND actual link format.
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === outputMenu { populateOutputMenu(menu) }
    }

    private func populateOutputMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        func note(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        guard let target = stableOutputTarget() else {
            note("Enable HiDPI on the connected display first.")
            return
        }
        let manager = VirtualDisplayManager.shared()
        prepareOutputPreference(for: target)
        guard let preference = outputPreference(for: target) else { return }
        let monitor = outputMonitorKey(target)
        let state = manager.outputState(forDisplay: target)
        let modes = (state?["modes"] as? [[String: Any]] ?? [])
            .compactMap(DisplayOutputMode.init(dictionary:)).filter(\.isSelectable)
        let current = (state?["current"] as? [String: Any]).flatMap(DisplayOutputMode.init(dictionary:))
        let hdr = manager.isHDREnabled(forDisplay: target)
        note("Current: \(current?.statusTitle ?? (hdr ? "HDR on · Format unavailable" : "HDR off · Format unavailable"))")
        if outputRestore.pending { note("Applying saved HDR and color settings…") }
        if let message = outputRestoreMessage { note(message) }
        menu.addItem(.separator())

        let hdrItem = NSMenuItem(title: "HDR", action: #selector(togglePhysicalHDR(_:)), keyEquivalent: "")
        hdrItem.target = self
        hdrItem.representedObject = monitor
        hdrItem.state = preference.hdrEnabled ? .on : .off
        hdrItem.isEnabled = manager.displaySupportsHDR(target)
        menu.addItem(hdrItem)
        if hdr != preference.hdrEnabled { note("Saved: HDR \(preference.hdrEnabled ? "on" : "off")") }
        menu.addItem(.separator())

        for wantsHDR in [true, false] {
            let group = NSMenu()
            group.autoenablesItems = false
            let chosen = preference.mode(forHDR: wantsHDR)
            let automatic = NSMenuItem(title: "Automatic (macOS)", action: #selector(selectAutomaticOutput(_:)), keyEquivalent: "")
            automatic.target = self
            automatic.representedObject = ["monitor": monitor, "hdr": wantsHDR] as [String: Any]
            automatic.state = chosen == nil ? .on : .off
            automatic.isEnabled = !wantsHDR || manager.displaySupportsHDR(target)
            group.addItem(automatic)
            for mode in modes.filter({ $0.isHDR == wantsHDR }).sorted(by: {
                if $0.encoding != $1.encoding { return $0.encoding < $1.encoding }
                if $0.range != $1.range { return $0.range > $1.range }
                return $0.bitsPerComponent > $1.bitsPerComponent
            }) {
                let item = NSMenuItem(title: mode.title, action: #selector(selectPhysicalOutput(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["monitor": monitor, "mode": mode.dictionary] as [String: Any]
                item.state = chosen == mode ? .on : .off
                item.isEnabled = true
                group.addItem(item)
            }
            if let chosen = chosen, !modes.contains(chosen) {
                let item = NSMenuItem(title: "Saved: \(chosen.title) (unavailable)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                group.addItem(item)
            }
            let item = NSMenuItem(title: wantsHDR ? "HDR10 Output" : "SDR Output", action: nil, keyEquivalent: "")
            item.submenu = group
            item.isEnabled = true
            menu.addItem(item)
        }
        menu.addItem(.separator())
        note("Saved for this display; restored after reconnect.")
        note("System Settings HDR changes are remembered.")
    }

    @objc private func togglePhysicalHDR(_ sender: NSMenuItem) {
        guard let target = stableOutputTarget(), sender.representedObject as? String == outputMonitorKey(target),
              var preference = outputPreference(for: target) else { return }
        preference.hdrEnabled.toggle()
        saveOutputPreference(preference, for: target)
        forceAutomaticOutput = false
        beginOutputRestore()
        scheduleFixedRefreshCheck()
        rebuildMenu()
    }

    @objc private func selectAutomaticOutput(_ sender: NSMenuItem) {
        guard let target = stableOutputTarget(), let choice = sender.representedObject as? [String: Any],
              choice["monitor"] as? String == outputMonitorKey(target),
              let hdr = choice["hdr"] as? Bool, var preference = outputPreference(for: target) else { return }
        preference.select(nil, forHDR: hdr)
        saveOutputPreference(preference, for: target)
        forceAutomaticOutput = true
        beginOutputRestore()
        scheduleFixedRefreshCheck()
        rebuildMenu()
    }

    @objc private func selectPhysicalOutput(_ sender: NSMenuItem) {
        guard let target = stableOutputTarget(), let choice = sender.representedObject as? [String: Any],
              choice["monitor"] as? String == outputMonitorKey(target),
              let dictionary = choice["mode"] as? [String: Any],
              let mode = DisplayOutputMode(dictionary: dictionary), mode.isSelectable,
              var preference = outputPreference(for: target) else { return }
        // Revalidate the menu selection in case the timing changed while open.
        let state = VirtualDisplayManager.shared().outputState(forDisplay: target)
        let available = (state?["modes"] as? [[String: Any]] ?? [])
            .compactMap(DisplayOutputMode.init(dictionary:))
        guard available.contains(mode) else { rebuildMenu(); return }
        preference.select(mode, forHDR: mode.isHDR)
        saveOutputPreference(preference, for: target)
        forceAutomaticOutput = false
        beginOutputRestore()
        scheduleFixedRefreshCheck()
        rebuildMenu()
    }

    @objc func toggleKeepPrimary(_ sender: NSMenuItem) {
        let newValue = !UserDefaults.standard.bool(forKey: kKeepPrimaryDisplayKey)
        UserDefaults.standard.set(newValue, forKey: kKeepPrimaryDisplayKey)
        debugLog("Keep external as main display: \(newValue)")
        // Apply immediately so enabling it moves the menu bar without waiting
        // for the next mirror setup or wake.
        if newValue {
            applyPrimaryDisplayPreference()
        }
        rebuildMenu()
    }

    /// Make the given display the main display (the one that owns the menu bar).
    /// macOS designates whichever display sits at global origin (0,0) as the main
    /// display, so we translate the whole arrangement by the target's current
    /// origin — keeping every display's relative position while landing the target
    /// at (0,0). Returns true if the target is (or becomes) the main display.
    func setMainDisplay(_ targetID: CGDirectDisplayID) -> Bool {
        guard targetID != 0 else { return false }

        if CGMainDisplayID() == targetID {
            debugLog("Primary: display \(targetID) is already the main display")
            return true
        }

        let targetOrigin = CGDisplayBounds(targetID).origin
        if targetOrigin == .zero {
            debugLog("Primary: display \(targetID) already at origin (0,0)")
            return true
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            debugLog("Primary: begin display configuration failed")
            return false
        }

        var displayList = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayList, &displayCount)

        for i in 0..<Int(displayCount) {
            let id = displayList[i]
            let bounds = CGDisplayBounds(id)
            let newX = Int32(bounds.origin.x - targetOrigin.x)
            let newY = Int32(bounds.origin.y - targetOrigin.y)
            let err = CGConfigureDisplayOrigin(config, id, newX, newY)
            if err != .success {
                // Abort rather than commit a partial arrangement (a display
                // can disappear mid-transaction during wake).
                debugLog("Primary: configure origin failed for display \(id) (\(err.rawValue)), cancelling")
                CGCancelDisplayConfiguration(config)
                return false
            }
        }

        // Session-scoped (not permanent) to avoid the ColorSync profile
        // persistence I/O that can stall the daemon — we re-assert on every
        // mirror setup and wake anyway.
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        let ok = result == .success
        debugLog("Primary: set display \(targetID) as main -> \(ok ? "ok" : "failed (\(result.rawValue))")")
        return ok
    }

    /// Apply the "Keep External as Main Display" preference. macOS resets the
    /// main display back to the built-in screen after sleep/wake, so we re-assert
    /// the external monitor as primary once the mirror is established. The mirror
    /// set's master is the virtual display (the physical monitor mirrors it), so
    /// that's what we promote to origin (0,0). No-op when disabled or inactive.
    func applyPrimaryDisplayPreference() {
        guard UserDefaults.standard.bool(forKey: kKeepPrimaryDisplayKey) else { return }

        // Prefer the virtual display (the mirror master that owns the desktop);
        // fall back to the physical target if we somehow don't have it.
        let anchor = currentVirtualID != 0 ? currentVirtualID : targetExternalDisplayID
        guard anchor != 0 else {
            debugLog("Primary: no active display to promote, skipping")
            return
        }
        _ = setMainDisplay(anchor)
    }

    @objc func setRefreshRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? NSNumber else { return }
        let oldRate = UserDefaults.standard.double(forKey: kRefreshRateKey)
        UserDefaults.standard.set(rate.doubleValue, forKey: kRefreshRateKey)
        UserDefaults.standard.set(0, forKey: kConnectionRecoveryCountKey)
        connectionRecoveryBlocked = false
        debugLog("Refresh rate set to: \(rate.doubleValue == 0 ? "Auto" : "\(rate.doubleValue) Hz")")

        // CGVirtualDisplay objects persist until the process exits, so changing
        // the rate on a live display has no effect — we must relaunch. The saved
        // preset is already in kLastPresetKey from when it was applied, so
        // checkAndRestoreFromCrash() will re-apply it with the new rate.
        if (isActive || hasOrphanedVirtualDisplay()) && oldRate != rate.doubleValue {
            debugLog("Active display present, relaunching to apply new refresh rate...")
            isRestarting = true
            StatusWindowController.shared.show(message: "Applying refresh rate...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                relaunchApp()
            }
            return
        }
        rebuildMenu()
    }

    @objc func checkForUpdates() {
        UpdateChecker.shared.checkForUpdatesManually()
    }

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "G9 Helper"
        alert.informativeText = """
            Version \(version)

            Unlock crisp HiDPI scaling on Samsung Odyssey G9 and other large monitors.

            Created by AL in Dallas
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func addPresetItem(to menu: NSMenu, preset: String, title: String) {
        let item = NSMenuItem(title: title, action: #selector(applyPreset(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = preset
        menu.addItem(item)
    }

    func addCustomScaleItem(to menu: NSMenu, nativeWidth: UInt32, nativeHeight: UInt32, ppi: UInt32) {
        menu.addItem(NSMenuItem.separator())
        let item = NSMenuItem(title: "Custom Scale...", action: #selector(showCustomScale(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["width": nativeWidth, "height": nativeHeight, "ppi": ppi] as [String: UInt32]
        menu.addItem(item)
    }

    @objc func showCustomScale(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: UInt32],
              let nativeW = info["width"],
              let nativeH = info["height"],
              let ppi = info["ppi"] else { return }

        CustomScaleWindowController.shared.show(nativeWidth: nativeW, nativeHeight: nativeH, ppi: ppi) { [weak self] config in
            self?.applyCustomConfig(config)
        }
    }

    func applyCustomConfig(_ config: PresetConfig) {
        // User manually applying — reset failure counters for a fresh attempt.
        UserDefaults.standard.set(0, forKey: kConnectionRecoveryCountKey)
        UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)
        // Save custom config to UserDefaults for crash recovery
        let presetKey = "custom-\(config.logicalWidth)x\(config.logicalHeight)"
        let customDict: [String: Any] = [
            "name": config.name,
            "width": config.width,
            "height": config.height,
            "logicalWidth": config.logicalWidth,
            "logicalHeight": config.logicalHeight,
            "ppi": config.ppi,
            "hiDPI": config.hiDPI
        ]
        UserDefaults.standard.set(customDict, forKey: "customPresetConfig")
        saveCurrentPreset(presetKey)

        // If a virtual display is already active, restart to switch cleanly
        if isActive || hasOrphanedVirtualDisplay() {
            debugLog("Active display exists, restarting to apply custom config cleanly...")
            isRestarting = true
            StatusWindowController.shared.show(message: "Switching preset...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                relaunchApp()
            }
            return
        }

        isSettingUp = true
        setupGeneration += 1
        let generation = setupGeneration
        StatusWindowController.shared.show(message: "Preparing display configuration...")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            autoreleasepool {
                self?.createVirtualDisplayAsync(config: config, generation: generation)
            }
        }
    }

    @objc func applyPreset(_ sender: NSMenuItem) {
        captureHDRBeforeTeardown()
        guard let presetName = sender.representedObject as? String else { return }
        debugLog(">>> Applying preset: \(presetName)")

        // User manually applying — reset failure counters for a fresh attempt.
        UserDefaults.standard.set(0, forKey: kConnectionRecoveryCountKey)
        UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)

        guard let config = presetConfigs[presetName] else {
            debugLog("ERROR: Unknown preset \(presetName)")
            return
        }

        // If a virtual display is already active, we must restart the app to switch.
        // CGVirtualDisplay objects persist until the process exits — releasing them
        // does NOT remove the display. Restarting lets macOS reclaim the old one,
        // and checkAndRestoreFromCrash() applies the new preset on relaunch.
        if isActive || hasOrphanedVirtualDisplay() {
            debugLog("Active display exists, saving new preset and restarting to switch cleanly...")
            isRestarting = true
            StatusWindowController.shared.show(message: "Switching preset...")
            saveCurrentPreset(presetName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                relaunchApp()
            }
            return
        }

        // Mark that we're setting up (don't trigger cleanup during setup)
        isSettingUp = true
        setupGeneration += 1
        let generation = setupGeneration

        // Show status window
        StatusWindowController.shared.show(message: "Preparing display configuration...")

        // Save the preset for crash recovery
        saveCurrentPreset(presetName)

        // Schedule creation after a delay using DispatchQueue instead of Timer
        // This gives us better control over autorelease pool behavior
        debugLog("Scheduling display creation in 1.5 seconds...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            autoreleasepool {
                self?.createVirtualDisplayAsync(config: config, generation: generation)
            }
        }
    }

    // Disable HiDPI when user explicitly requests it - clears preset (no auto-restore)
    func disableHiDPISync() {
        captureHDRBeforeTeardown()
        outputRestore.finish()
        connectionRecoveryMessage = nil
        connectionRecoveryBlocked = false
        debugLog("Disabling HiDPI (user action) - currentVirtualID: \(currentVirtualID)")
        setupGeneration += 1  // Cancel any in-flight setup steps
        isSettingUp = false   // A cancelled setup step won't clear this itself
        mirrorReattachWorkItem?.cancel()
        mirrorReattachWorkItem = nil

        let manager = VirtualDisplayManager.shared()

        // Reset ALL mirroring to ensure clean state
        manager.resetAllMirroring()

        // Destroy our virtual display
        manager.destroyAllVirtualDisplays()

        currentVirtualID = 0
        targetExternalDisplayID = 0
        isActive = false
        currentPresetName = ""

        // Clear saved preset - user explicitly disabled, don't auto-restore
        clearSavedPreset()

        // Also clear the disconnected flag since user is taking explicit action
        wasDisconnected = false
        UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)

        debugLog("HiDPI disabled (preset cleared)")
    }

    /// Every refresh rate the panel offers on its native pixel grid, ascending.
    /// Empty when the native size can't be read or the panel publishes no rate
    /// there, in which case callers keep their pre-1.2.6 behavior.
    func nativeRefreshRates(_ displayID: CGDirectDisplayID) -> [Double] {
        var nativeWidth = 0, nativeHeight = 0
        guard VDMNativePixelSize(displayID, &nativeWidth, &nativeHeight) else { return [] }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else {
            return []
        }
        // Same eligibility test the pin uses. A rate that only exists on a mode
        // the pin would skip is a rate we must not hand back, or the virtual
        // source and the panel end up running at different rates.
        let rates = modes.compactMap { mode -> Double? in
            guard mode.isUsableForDesktopGUI(), mode.isNativeGrid(nativeWidth, nativeHeight),
                  mode.refreshRate > 0 else { return nil }
            return mode.refreshRate
        }
        return Array(Set(rates)).sorted()
    }

    /// One-line summary of what the panel offers, written to the log whenever we
    /// set up a mirror. Bug reports about softness or refresh rate are almost
    /// always answered by this line, and asking a reporter to enumerate modes by
    /// hand is a round trip nobody enjoys.
    func logPanelModeSummary(_ displayID: CGDirectDisplayID) {
        var nativeWidth = 0, nativeHeight = 0
        guard VDMNativePixelSize(displayID, &nativeWidth, &nativeHeight) else {
            debugLog("Panel \(displayID): native size unreadable")
            return
        }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]) ?? []
        let atNative = nativeRefreshRates(displayID).map { Int($0.rounded()) }
        let anyRates = Set(modes.compactMap { $0.refreshRate > 0 ? Int($0.refreshRate.rounded()) : nil }).sorted()
        debugLog("Panel \(displayID): native \(nativeWidth)x\(nativeHeight), rates at native \(atNative) Hz, all rates \(anyRates) Hz")
    }

    private func linkCapabilities(for target: CGDirectDisplayID) -> DisplayLinkCapabilities? {
        guard displayIsOnline(target), let raw = VDMNativeTimingCapabilities(target),
              let width = raw["width"] as? NSNumber, let height = raw["height"] as? NSNumber,
              let rates = raw["fixedRefreshRates"] as? [NSNumber] else { return nil }
        return DisplayLinkCapabilities(displayID: target, width: width.intValue, height: height.intValue,
                                       fixedRefreshRates: rates.map(\.doubleValue))
    }

    private func rememberedTiming(for target: CGDirectDisplayID) -> DisplayTimingRequirement? {
        let records = UserDefaults.standard.dictionary(forKey: kStableTimingKey) ?? [:]
        return (records[outputMonitorKey(target)] as? [String: Any])
            .flatMap(DisplayTimingRequirement.init(dictionary:))
    }

    private func requiredTiming(for target: CGDirectDisplayID) -> DisplayTimingRequirement? {
        guard target != 0 else { return nil }
        return DisplayTimingRequirement.recovering(remembered: rememberedTiming(for: target),
            capabilities: linkCapabilities(for: target),
            preferredRate: UserDefaults.standard.double(forKey: kRefreshRateKey))
    }

    private func physicalTimingMatches(_ target: CGDirectDisplayID,
                                       requirement: DisplayTimingRequirement,
                                       requiresFixedRefresh: Bool = true) -> Bool {
        guard let mode = CGDisplayCopyDisplayMode(target) else { return false }
        return requirement.matchesPhysical(width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate,
            variableRefresh: VDMVariableRefreshState(target) == 1,
            requiresFixedRefresh: requiresFixedRefresh)
    }

    private func rememberStableTiming(_ requirement: DisplayTimingRequirement, for target: CGDirectDisplayID) {
        guard rememberedTiming(for: target) != requirement else { return }
        var records = UserDefaults.standard.dictionary(forKey: kStableTimingKey) ?? [:]
        records[outputMonitorKey(target)] = requirement.dictionary
        UserDefaults.standard.set(records, forKey: kStableTimingKey)
        debugLog("Connection: remembered native timing \(requirement.title)")
    }

    private func rememberUnmirroredNativeTiming(_ target: CGDirectDisplayID) {
        guard CGDisplayMirrorsDisplay(target) == 0,
              let requirement = requiredTiming(for: target),
              let capabilities = linkCapabilities(for: target), requirement.accepts(capabilities),
              let mode = CGDisplayCopyDisplayMode(target),
              mode.pixelWidth == requirement.width, mode.pixelHeight == requirement.height,
              abs(mode.refreshRate - requirement.refreshRate) <= 0.5 else { return }
        rememberStableTiming(requirement, for: target)
    }

    private func shouldRetryConnection(on target: CGDirectDisplayID?) -> Bool {
        guard connectionRecoveryBlocked else { return true }
        let capabilities = target.flatMap { linkCapabilities(for: $0) }
        guard capabilities != blockedConnectionCapabilities else { return false }
        connectionRecoveryBlocked = false
        return true
    }

    private func waitForConnection(config: PresetConfig, generation: Int,
                                   external: CGDirectDisplayID?) -> DisplayTimingRequirement? {
        if connectionReadinessGeneration != generation {
            connectionReadinessGeneration = generation
            connectionReadiness = DisplayConnectionReadiness()
        }
        let capabilities = external.flatMap { linkCapabilities(for: $0) }
        let requirement = external.flatMap { requiredTiming(for: $0) }
        let decision = connectionReadiness.observe(capabilities, requiring: requirement,
                                                  at: ProcessInfo.processInfo.systemUptime)
        if decision == .ready {
            connectionRecoveryMessage = nil
            setupTimingRequirement = requirement
            return requirement
        }
        let message = requirement.map { "Waiting for \($0.title) to settle…" } ?? "Waiting for display capabilities…"
        if connectionRecoveryMessage != message {
            connectionRecoveryMessage = message
            debugLog("Connection: \(message)")
            StatusWindowController.shared.updateStatus(message)
            rebuildMenu()
        }
        if decision == .timedOut {
            isSettingUp = false
            outputRestore.finish()
            connectionRecoveryBlocked = true
            blockedConnectionCapabilities = capabilities
            connectionRecoveryMessage = "Connection not ready; select a preset to retry."
            wasDisconnected = true
            UserDefaults.standard.set(true, forKey: kWasDisconnectedKey)
            debugLog("Connection probe stopped after 30s; native desktop retained, no virtual display created")
            StatusWindowController.shared.hide()
            rebuildMenu()
            return nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.createVirtualDisplayAsync(config: config, generation: generation)
        }
        return nil
    }

    func createVirtualDisplayAsync(config: PresetConfig, generation: Int) {
        guard generation == setupGeneration else {
            debugLog("Stale setup (create step) superseded, aborting")
            return
        }
        debugLog("Creating virtual display: \(config.width)x\(config.height)")

        let external = findExternalDisplay()
        guard let requirement = waitForConnection(config: config, generation: generation, external: external),
              let externalID = external else { return }
        debugLog("Using stable external display \(externalID): \(requirement.title)")
        prepareOutputPreference(for: externalID)
        beginOutputRestore()
        logPanelModeSummary(externalID)
        StatusWindowController.shared.updateStatus("Creating virtual display…")
        let refreshRate = requirement.refreshRate
        debugLog("Will create virtual display at \(refreshRate) Hz; timing fixed for this setup generation")

        // Create virtual display with color primaries matching the physical display.
        // This lets ColorSync use an identity transform instead of doing expensive
        // per-frame color conversion that was causing WindowServer deadlocks.
        let manager = VirtualDisplayManager.shared()
        debugLog("Calling createVirtualDisplay (matching display \(externalID))...")
        let virtualID = manager.createVirtualDisplay(
            withWidth: config.width,
            height: config.height,
            ppi: config.ppi,
            hiDPI: config.hiDPI,
            name: config.name,
            refreshRate: refreshRate,
            matchingDisplay: externalID
        )
        debugLog("createVirtualDisplay returned: \(virtualID)")

        if virtualID == 0 || virtualID == UInt32.max {
            debugLog("ERROR: Failed to create virtual display (returned \(virtualID))")
            isSettingUp = false  // Clear setup flag so reconnect detection works
            StatusWindowController.shared.updateStatus("Failed to create virtual display")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                StatusWindowController.shared.hide()
            }
            rebuildMenu()
            return
        }
        debugLog("Created virtual display: \(virtualID)")
        currentVirtualID = virtualID

        StatusWindowController.shared.updateStatus("Configuring display mirror...")

        // Wait for display to initialize
        debugLog("Scheduling mirror in 3 seconds...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            autoreleasepool {
                self?.performMirror(virtualID: virtualID, externalID: externalID, config: config, generation: generation)
            }
        }
    }

    func performMirror(virtualID: CGDirectDisplayID, externalID: CGDirectDisplayID, config: PresetConfig, generation: Int) {
        guard generation == setupGeneration else {
            debugLog("Stale setup (mirror step) superseded, aborting")
            return
        }
        debugLog("Setting up mirror: \(virtualID) -> \(externalID)")
        let manager = VirtualDisplayManager.shared()
        // Pin the physical target to the same rate the virtual was created at,
        // so the panel scans out at the requested rate instead of being left in
        // VRR mode (which can downgrade effective rate and break the cursor).
        guard let requirement = setupTimingRequirement,
              displayIsOnline(virtualID), displayIsOnline(externalID),
              let capabilities = linkCapabilities(for: externalID), requirement.accepts(capabilities),
              let source = CGDisplayCopyDisplayMode(virtualID),
              abs(source.refreshRate - requirement.refreshRate) <= 0.5 else {
            suspendMirrorForConnection("Connection changed between create and mirror")
            return
        }
        let pinRate = requirement.refreshRate
        let success = manager.mirrorDisplay(virtualID, toDisplay: externalID, atRate: pinRate)
        debugLog("Mirror result: \(success)")

        // Setup is complete (whether successful or not)
        isSettingUp = false

        if success {
            isActive = true
            currentPresetName = "\(config.logicalWidth)x\(config.logicalHeight)"
            targetExternalDisplayID = externalID  // Track target for disconnect detection
            UserDefaults.standard.set(0, forKey: kMirrorFailureCountKey)  // Reset failure counter
            saveMonitorFingerprint(externalID)
            StatusWindowController.shared.updateStatus("HiDPI enabled: \(config.logicalWidth)x\(config.logicalHeight)")
            debugLog(">>> HiDPI setup complete, monitoring for disconnect")

            // Verify actual backing scale after display configuration settles
            if config.hiDPI {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self, generation == self.setupGeneration,
                          self.isActive, self.currentVirtualID == virtualID else { return }
                    self.verifyBackingScale(externalID: externalID, config: config)
                }
            }

            // Re-apply physical output and main-display preferences once the mirror
            // has settled — macOS resets both on login/sleep-wake.
            reassertPreferencesAfterSetup()
        } else {
            debugLog("Mirror failed, cleaning up...")
            manager.destroyVirtualDisplay(virtualID)
            currentVirtualID = 0
            isActive = false
            currentPresetName = ""

            // Track consecutive failures to prevent infinite restart loops
            let failCount = UserDefaults.standard.integer(forKey: kMirrorFailureCountKey) + 1
            UserDefaults.standard.set(failCount, forKey: kMirrorFailureCountKey)

            if failCount < maxMirrorRetries {
                // Allow retry — set wasDisconnected so periodic check will auto-apply
                wasDisconnected = true
                UserDefaults.standard.set(true, forKey: kWasDisconnectedKey)
                debugLog("Mirror failure \(failCount)/\(maxMirrorRetries), will retry when monitor is ready")
                StatusWindowController.shared.updateStatus("Waiting for display...")
            } else {
                // Too many failures — stop the auto-retry loop
                wasDisconnected = false
                UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
                debugLog("Mirror failed \(failCount) times, stopping auto-retry. Use menu to apply manually.")
                StatusWindowController.shared.updateStatus("Setup failed — apply manually from menu")
            }
            isRestarting = true
            UserDefaults.standard.set(wasDisconnected, forKey: kWasDisconnectedKey)
            if !wasDisconnected { UserDefaults.standard.set(false, forKey: kWasCrashKey) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in relaunchApp() }
        }

        // A superseded setup must not hide a newer connection-wait message.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, generation == self.setupGeneration else { return }
            StatusWindowController.shared.hide()
        }

        rebuildMenu()
    }

    func verifyBackingScale(externalID: CGDirectDisplayID, config: PresetConfig) {
        var actualScale: CGFloat = 0
        var matchedScreen: NSScreen?

        for screen in NSScreen.screens {
            let deviceDesc = screen.deviceDescription
            if let screenNumber = deviceDesc[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if screenNumber == externalID || screenNumber == currentVirtualID {
                    matchedScreen = screen
                    actualScale = screen.backingScaleFactor
                    break
                }
            }
        }

        // Mirrors collapse into a single NSScreen, fall back to main
        if matchedScreen == nil {
            if let main = NSScreen.main {
                matchedScreen = main
                actualScale = main.backingScaleFactor
            }
        }

        let isActuallyHiDPI = actualScale >= 2.0
        debugLog("Backing scale verification: scale=\(actualScale), isHiDPI=\(isActuallyHiDPI)")

        if let screen = matchedScreen {
            let frame = screen.frame
            let visibleFrame = screen.visibleFrame
            debugLog("  Screen frame: \(frame.width)x\(frame.height), visible: \(visibleFrame.width)x\(visibleFrame.height)")
        }

        if isActuallyHiDPI {
            debugLog("Verified: display is running at \(actualScale)x backing scale (true HiDPI)")
            currentPresetName = "\(config.logicalWidth)x\(config.logicalHeight)"
            StatusWindowController.shared.updateStatus("HiDPI active: \(config.logicalWidth)x\(config.logicalHeight) @\(Int(actualScale))x")
        } else {
            debugLog("WARNING: backing scale is \(actualScale)x — display is NOT in true HiDPI mode")
            currentPresetName = "\(config.logicalWidth)x\(config.logicalHeight) (1x)"
            StatusWindowController.shared.updateStatus("\(config.logicalWidth)x\(config.logicalHeight) active (not HiDPI — \(actualScale)x scale)")
        }

        rebuildMenu()

        let generation = setupGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, generation == self.setupGeneration else { return }
            StatusWindowController.shared.hide()
        }
    }

    func findExternalDisplay() -> CGDirectDisplayID? {
        var displayList = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayList, &displayCount)

        debugLog("findExternalDisplay: found \(displayCount) displays, currentVirtualID=\(currentVirtualID)")

        // Collect candidate displays with their physical sizes
        var candidates: [(id: CGDirectDisplayID, size: CGSize)] = []

        for i in 0..<Int(displayCount) {
            let displayID = displayList[i]
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let vendorID = CGDisplayVendorNumber(displayID)
            let isVirtualDisplay = vendorID == 0x1234  // Our virtual displays use vendor 0x1234
            let isGhostDisplay = vendorID == 0x756E6B6E  // "unkn" — phantom display without EDID

            // Skip builtin, virtual, and ghost/phantom displays
            if !isBuiltin && !isVirtualDisplay && !isGhostDisplay {
                // Only call CGDisplayScreenSize on real displays — calling it on
                // virtual displays triggers expensive ColorSync profile lookups
                // that can deadlock colorsync.displayservices and freeze WindowServer.
                let size = CGDisplayScreenSize(displayID)
                debugLog("  Display \(displayID): builtin=\(isBuiltin), vendor=\(vendorID), size=\(size.width)x\(size.height)mm")
                candidates.append((id: displayID, size: size))
            } else {
                debugLog("  Display \(displayID): builtin=\(isBuiltin), vendor=\(vendorID), isVirtual=\(isVirtualDisplay) — skipped")
            }
        }

        // Prefer displays with large physical size (real monitors vs virtual)
        // G9 57" is about 1400mm wide, G9 49" is about 1200mm wide
        // Sort by width descending to prefer larger displays
        candidates.sort { $0.size.width > $1.size.width }

        // With multiple externals, prefer the monitor the saved preset was
        // applied to — otherwise the fingerprint check can pass on one display
        // while setup mirrors a different one.
        if let bound = candidates.first(where: { displayMatchesSavedFingerprint($0.id) }) {
            debugLog("  -> Selected external display: \(bound.id) (matches saved monitor fingerprint)")
            return bound.id
        }

        if let best = candidates.first {
            debugLog("  -> Selected external display: \(best.id) (\(best.size.width)mm wide)")
            return best.id
        }

        debugLog("  -> No external display found")
        return nil
    }

    func saveMonitorFingerprint(_ displayID: CGDirectDisplayID) {
        let vendor = Int(CGDisplayVendorNumber(displayID))
        let model = Int(CGDisplayModelNumber(displayID))
        let serial = Int(CGDisplaySerialNumber(displayID))
        UserDefaults.standard.set(vendor, forKey: kBoundMonitorVendorKey)
        UserDefaults.standard.set(model, forKey: kBoundMonitorModelKey)
        UserDefaults.standard.set(serial, forKey: kBoundMonitorSerialKey)
        debugLog("Saved monitor fingerprint: vendor=\(vendor), model=\(model), serial=\(serial)")
    }

    /// True when `displayID` is the monitor the saved preset was applied to.
    /// Vendor must match; then model OR EDID serial. The G9 57 reports a
    /// different product ID depending on the negotiated display mode
    /// (observed 29814 vs 29818 on the same panel), so model alone would
    /// wrongly block auto-restore. Serial is the stable identifier.
    func displayMatchesSavedFingerprint(_ displayID: CGDirectDisplayID) -> Bool {
        guard UserDefaults.standard.object(forKey: kBoundMonitorVendorKey) != nil else { return false }
        let savedVendor = UserDefaults.standard.integer(forKey: kBoundMonitorVendorKey)
        let savedModel = UserDefaults.standard.integer(forKey: kBoundMonitorModelKey)
        let savedSerial = UserDefaults.standard.integer(forKey: kBoundMonitorSerialKey)

        guard Int(CGDisplayVendorNumber(displayID)) == savedVendor else { return false }
        if Int(CGDisplayModelNumber(displayID)) == savedModel { return true }
        let serial = Int(CGDisplaySerialNumber(displayID))
        return savedSerial != 0 && serial != 0 && serial == savedSerial
    }

    func connectedMonitorMatchesSavedPreset() -> Bool {
        guard UserDefaults.standard.object(forKey: kBoundMonitorVendorKey) != nil else {
            return true
        }

        let savedVendor = UserDefaults.standard.integer(forKey: kBoundMonitorVendorKey)
        let savedModel = UserDefaults.standard.integer(forKey: kBoundMonitorModelKey)
        let savedSerial = UserDefaults.standard.integer(forKey: kBoundMonitorSerialKey)

        // Check every connected real monitor — with multiple externals the
        // saved G9 may not be the first one CoreGraphics returns. Setup
        // targets the fingerprint-matching display (see findExternalDisplay).
        var displayList = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayList, &displayCount)

        var seen: [String] = []
        for i in 0..<Int(displayCount) {
            let displayID = displayList[i]
            let vendorID = CGDisplayVendorNumber(displayID)
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let isVirtualDisplay = vendorID == 0x1234
            let isGhostDisplay = vendorID == 0x756E6B6E
            if isBuiltin || isVirtualDisplay || isGhostDisplay { continue }
            if displayMatchesSavedFingerprint(displayID) {
                return true
            }
            seen.append("(\(vendorID),\(CGDisplayModelNumber(displayID)),\(CGDisplaySerialNumber(displayID)))")
        }

        if !seen.isEmpty {
            debugLog("Monitor mismatch: saved=(\(savedVendor),\(savedModel),\(savedSerial)) connected=\(seen.joined(separator: " ")) — skipping auto-apply")
        }
        return false
    }

    @objc func cleanUpDisplays() {
        debugLog("Manual cleanup requested by user")
        isRestarting = true
        StatusWindowController.shared.show(message: "Cleaning up phantom displays...")

        // Reset mirroring and destroy any in-process displays
        let manager = VirtualDisplayManager.shared()
        manager.resetAllMirroring()
        manager.destroyAllVirtualDisplays()

        isActive = false
        currentPresetName = ""
        currentVirtualID = 0

        // Keep kLastPresetKey — user wants to clean phantoms, not lose their preset.
        // checkAndRestoreFromCrash() will re-apply it after the restart.

        StatusWindowController.shared.updateStatus("Restarting to finish cleanup...")

        // Restart the app — macOS reclaims virtual displays from the dead process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            markCleanupRestart()
            relaunchApp()
        }
    }

    @objc func disableHiDPIAction() {
        // Virtual displays persist until process exit — must restart to truly remove them
        if isActive || hasOrphanedVirtualDisplay() {
            StatusWindowController.shared.show(message: "Disabling HiDPI...")
            isRestarting = true
            // Clear preset so relaunch does NOT restore
            clearSavedPreset()
            wasDisconnected = false
            UserDefaults.standard.set(false, forKey: kWasDisconnectedKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                relaunchApp()
            }
            return
        }
        // No active display — just clean up in-process state
        disableHiDPISync()
        rebuildMenu()
    }

    @objc func quitApp() {
        debugLog("Quit requested by user")
        disableHiDPISync()
        NSApp.terminate(nil)
    }
}

// MARK: - Preset Configurations

extension CGDisplayMode {
    /// A real scanout mode sitting exactly on the panel's native grid. Mirrors
    /// the one-to-one test the pin uses, so the rate we pick and the mode we pin
    /// can never disagree about what counts as native.
    func isNativeGrid(_ nativeWidth: Int, _ nativeHeight: Int) -> Bool {
        return pixelWidth == nativeWidth && pixelHeight == nativeHeight &&
               width == pixelWidth && height == pixelHeight
    }
}

struct PresetConfig {
    let name: String
    let width: UInt32      // Framebuffer width
    let height: UInt32     // Framebuffer height
    let logicalWidth: UInt32
    let logicalHeight: UInt32
    let ppi: UInt32
    let hiDPI: Bool
}

let presetConfigs: [String: PresetConfig] = [
    // 8K UHD (7680x4320 native). All presets preserve 16:9 and use a
    // framebuffer twice the logical dimensions in each direction.
    // 175% is rounded to the nearest 16:9 integer size (actual scale ~175.18%).
    "8k-6144x3456": PresetConfig(name: "8K-6144", width: 12288, height: 6912, logicalWidth: 6144, logicalHeight: 3456, ppi: 163, hiDPI: true),
    "8k-5760x3240": PresetConfig(name: "8K-5760", width: 11520, height: 6480, logicalWidth: 5760, logicalHeight: 3240, ppi: 163, hiDPI: true),
    "8k-5120x2880": PresetConfig(name: "8K-5120", width: 10240, height: 5760, logicalWidth: 5120, logicalHeight: 2880, ppi: 163, hiDPI: true),
    "8k-4800x2700": PresetConfig(name: "8K-4800", width: 9600, height: 5400, logicalWidth: 4800, logicalHeight: 2700, ppi: 163, hiDPI: true),
    "8k-4384x2466": PresetConfig(name: "8K-4384", width: 8768, height: 4932, logicalWidth: 4384, logicalHeight: 2466, ppi: 163, hiDPI: true),
    "8k-4096x2304": PresetConfig(name: "8K-4096", width: 8192, height: 4608, logicalWidth: 4096, logicalHeight: 2304, ppi: 163, hiDPI: true),
    "8k-3840x2160": PresetConfig(name: "8K-3840", width: 7680, height: 4320, logicalWidth: 3840, logicalHeight: 2160, ppi: 163, hiDPI: true),

    // Samsung G9 57" (7680x2160 native) - Fractional scaling options
    // Scale factor = native / logical, e.g., 7680/5120 = 1.5x
    "g9-57-6144x1728": PresetConfig(name: "G9-57-6144", width: 12288, height: 3456, logicalWidth: 6144, logicalHeight: 1728, ppi: 140, hiDPI: true),  // 1.25x
    "g9-57-5908x1662": PresetConfig(name: "G9-57-5908", width: 11816, height: 3324, logicalWidth: 5908, logicalHeight: 1662, ppi: 140, hiDPI: true),  // 1.3x
    "g9-57-5632x1584": PresetConfig(name: "G9-57-5632", width: 11264, height: 3168, logicalWidth: 5632, logicalHeight: 1584, ppi: 140, hiDPI: true),  // 1.36x
    "g9-57-5486x1543": PresetConfig(name: "G9-57-5486", width: 10972, height: 3086, logicalWidth: 5486, logicalHeight: 1543, ppi: 140, hiDPI: true),  // 1.4x
    "g9-57-5297x1490": PresetConfig(name: "G9-57-5297", width: 10594, height: 2980, logicalWidth: 5297, logicalHeight: 1490, ppi: 140, hiDPI: true),  // 1.45x
    "g9-57-5120x1440": PresetConfig(name: "G9-57-5120", width: 10240, height: 2880, logicalWidth: 5120, logicalHeight: 1440, ppi: 140, hiDPI: true),  // 1.5x (recommended)
    "g9-57-4800x1350": PresetConfig(name: "G9-57-4800", width: 9600, height: 2700, logicalWidth: 4800, logicalHeight: 1350, ppi: 140, hiDPI: true),   // 1.6x
    "g9-57-4389x1234": PresetConfig(name: "G9-57-4389", width: 8778, height: 2468, logicalWidth: 4389, logicalHeight: 1234, ppi: 140, hiDPI: true),   // 1.75x
    "g9-57-3840x1080": PresetConfig(name: "G9-57-3840", width: 7680, height: 2160, logicalWidth: 3840, logicalHeight: 1080, ppi: 140, hiDPI: true),   // 2.0x (native HiDPI)

    // Samsung G9 49" (5120x1440 native) - Fractional scaling options
    "g9-49-4096x1152": PresetConfig(name: "G9-49-4096", width: 8192, height: 2304, logicalWidth: 4096, logicalHeight: 1152, ppi: 109, hiDPI: true),   // 1.25x
    "g9-49-3938x1108": PresetConfig(name: "G9-49-3938", width: 7876, height: 2216, logicalWidth: 3938, logicalHeight: 1108, ppi: 109, hiDPI: true),   // 1.3x
    "g9-49-3840x1080": PresetConfig(name: "G9-49-3840", width: 7680, height: 2160, logicalWidth: 3840, logicalHeight: 1080, ppi: 109, hiDPI: true),   // 1.33x
    "g9-49-3413x960": PresetConfig(name: "G9-49-3413", width: 6826, height: 1920, logicalWidth: 3413, logicalHeight: 960, ppi: 109, hiDPI: true),     // 1.5x (recommended)
    "g9-49-2926x823": PresetConfig(name: "G9-49-2926", width: 5852, height: 1646, logicalWidth: 2926, logicalHeight: 823, ppi: 109, hiDPI: true),     // 1.75x
    "g9-49-2560x720": PresetConfig(name: "G9-49-2560", width: 5120, height: 1440, logicalWidth: 2560, logicalHeight: 720, ppi: 109, hiDPI: true),     // 2.0x (native HiDPI)

    // 34" Ultrawide (3440x1440 native) - Fractional scaling options
    "uw34-2752x1152": PresetConfig(name: "UW34-2752", width: 5504, height: 2304, logicalWidth: 2752, logicalHeight: 1152, ppi: 110, hiDPI: true),     // 1.25x
    "uw34-2646x1108": PresetConfig(name: "UW34-2646", width: 5292, height: 2216, logicalWidth: 2646, logicalHeight: 1108, ppi: 110, hiDPI: true),     // 1.3x
    "uw34-2293x960": PresetConfig(name: "UW34-2293", width: 4586, height: 1920, logicalWidth: 2293, logicalHeight: 960, ppi: 110, hiDPI: true),       // 1.5x (recommended)
    "uw34-1966x823": PresetConfig(name: "UW34-1966", width: 3932, height: 1646, logicalWidth: 1966, logicalHeight: 823, ppi: 110, hiDPI: true),       // 1.75x
    "uw34-1720x720": PresetConfig(name: "UW34-1720", width: 3440, height: 1440, logicalWidth: 1720, logicalHeight: 720, ppi: 110, hiDPI: true),       // 2.0x (native HiDPI)

    // 38" Ultrawide (3840x1600 native) - Fractional scaling options
    "uw38-3072x1280": PresetConfig(name: "UW38-3072", width: 6144, height: 2560, logicalWidth: 3072, logicalHeight: 1280, ppi: 110, hiDPI: true),     // 1.25x
    "uw38-2954x1231": PresetConfig(name: "UW38-2954", width: 5908, height: 2462, logicalWidth: 2954, logicalHeight: 1231, ppi: 110, hiDPI: true),     // 1.3x
    "uw38-2560x1067": PresetConfig(name: "UW38-2560", width: 5120, height: 2134, logicalWidth: 2560, logicalHeight: 1067, ppi: 110, hiDPI: true),     // 1.5x (recommended)
    "uw38-2194x914": PresetConfig(name: "UW38-2194", width: 4388, height: 1828, logicalWidth: 2194, logicalHeight: 914, ppi: 110, hiDPI: true),       // 1.75x
    "uw38-1920x800": PresetConfig(name: "UW38-1920", width: 3840, height: 1600, logicalWidth: 1920, logicalHeight: 800, ppi: 110, hiDPI: true),       // 2.0x (native HiDPI)

    // 4K (3840x2160 native) - Fractional scaling options
    "4k-3072x1728": PresetConfig(name: "4K-3072", width: 6144, height: 3456, logicalWidth: 3072, logicalHeight: 1728, ppi: 163, hiDPI: true),         // 1.25x
    "4k-2954x1662": PresetConfig(name: "4K-2954", width: 5908, height: 3324, logicalWidth: 2954, logicalHeight: 1662, ppi: 163, hiDPI: true),         // 1.3x
    "4k-2560x1440": PresetConfig(name: "4K-2560", width: 5120, height: 2880, logicalWidth: 2560, logicalHeight: 1440, ppi: 163, hiDPI: true),         // 1.5x (recommended)
    "4k-2194x1234": PresetConfig(name: "4K-2194", width: 4388, height: 2468, logicalWidth: 2194, logicalHeight: 1234, ppi: 163, hiDPI: true),         // 1.75x
    "4k-1920x1080": PresetConfig(name: "4K-1920", width: 3840, height: 2160, logicalWidth: 1920, logicalHeight: 1080, ppi: 163, hiDPI: true),         // 2.0x (native HiDPI)
]

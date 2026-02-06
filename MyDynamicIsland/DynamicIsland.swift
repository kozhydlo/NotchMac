import AppKit
import AudioToolbox
import Combine
import IOKit.ps
import SwiftUI

// MARK: - Lock Screen Window Manager (SkyLight)

final class LockScreenWindowManager {
    static let shared: LockScreenWindowManager? = LockScreenWindowManager()

    private enum SpaceLevel: Int32 {
        case `default` = 0
        case setupAssistant = 100
        case securityAgent = 200
        case screenLock = 300
        case notificationCenterAtScreenLock = 400
        case bootProgress = 500
        case voiceOver = 600
    }

    private let connection: Int32
    private let space: Int32

    private let SLSMainConnectionID: @convention(c) () -> Int32
    private let SLSSpaceCreate: @convention(c) (Int32, Int32, Int32) -> Int32
    private let SLSSpaceDestroy: @convention(c) (Int32, Int32) -> Int32
    private let SLSSpaceSetAbsoluteLevel: @convention(c) (Int32, Int32, Int32) -> Int32
    private let SLSShowSpaces: @convention(c) (Int32, CFArray) -> Int32
    private let SLSHideSpaces: @convention(c) (Int32, CFArray) -> Int32
    private let SLSSpaceAddWindowsAndRemoveFromSpaces: @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private init?() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/SkyLight.framework")
        ) else { return nil }

        guard let mainConnPtr = CFBundleGetFunctionPointerForName(bundle, "SLSMainConnectionID" as CFString) else { return nil }
        SLSMainConnectionID = unsafeBitCast(mainConnPtr, to: (@convention(c) () -> Int32).self)

        guard let createPtr = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceCreate" as CFString) else { return nil }
        SLSSpaceCreate = unsafeBitCast(createPtr, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)

        guard let destroyPtr = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceDestroy" as CFString) else { return nil }
        SLSSpaceDestroy = unsafeBitCast(destroyPtr, to: (@convention(c) (Int32, Int32) -> Int32).self)

        guard let setLevelPtr = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceSetAbsoluteLevel" as CFString) else { return nil }
        SLSSpaceSetAbsoluteLevel = unsafeBitCast(setLevelPtr, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)

        guard let showPtr = CFBundleGetFunctionPointerForName(bundle, "SLSShowSpaces" as CFString) else { return nil }
        SLSShowSpaces = unsafeBitCast(showPtr, to: (@convention(c) (Int32, CFArray) -> Int32).self)

        guard let hidePtr = CFBundleGetFunctionPointerForName(bundle, "SLSHideSpaces" as CFString) else { return nil }
        SLSHideSpaces = unsafeBitCast(hidePtr, to: (@convention(c) (Int32, CFArray) -> Int32).self)

        guard let addPtr = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceAddWindowsAndRemoveFromSpaces" as CFString) else { return nil }
        SLSSpaceAddWindowsAndRemoveFromSpaces = unsafeBitCast(addPtr, to: (@convention(c) (Int32, Int32, CFArray, Int32) -> Int32).self)

        connection = SLSMainConnectionID()
        space = SLSSpaceCreate(connection, 1, 0)

        _ = SLSSpaceSetAbsoluteLevel(connection, space, SpaceLevel.notificationCenterAtScreenLock.rawValue)
        _ = SLSShowSpaces(connection, [space] as CFArray)
    }

    deinit {
        _ = SLSHideSpaces(connection, [space] as CFArray)
        _ = SLSSpaceDestroy(connection, space)
    }

    func moveWindowToLockScreen(_ window: NSWindow) {
        _ = SLSSpaceAddWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)

        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        hasShadow = false

        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        canBecomeVisibleWithoutLogin = true
        level = .mainMenu + 1
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Live Activity

enum LiveActivity: Equatable {
    case none
    case music(app: String)
    case timer(remaining: TimeInterval, total: TimeInterval)
}

// MARK: - HUD Type

enum HUDType: Equatable {
    case none
    case volume(level: CGFloat, muted: Bool)
    case brightness(level: CGFloat)
}

// MARK: - HUD Display Mode

enum HUDDisplayMode: String, CaseIterable {
    case minimal = "Minimal"
    case progressBar = "Progress Bar"
    case notched = "Notched"
}

// MARK: - Battery State

enum ChargingState: Equatable {
    case unplugged
    case charging
    case full
}

struct BatteryInfo: Equatable {
    var level: Int = 100
    var isCharging: Bool = false
    var chargingState: ChargingState = .unplugged
    var timeRemaining: Int? = nil // minutes
}

// MARK: - Notch State

final class NotchState: ObservableObject {
    @Published var activity: LiveActivity = .none
    @Published var isExpanded: Bool = false
    @Published var isHovered: Bool = false
    @Published var hud: HUDType = .none
    @Published var isScreenLocked: Bool = false
    @Published var showUnlockAnimation: Bool = false

    // Battery
    @Published var battery: BatteryInfo = BatteryInfo()
    @Published var showChargingAnimation: Bool = false
    @Published var showUnplugAnimation: Bool = false

    // Notch dimensions
    @Published var notchWidth: CGFloat = 200
    @Published var notchHeight: CGFloat = 32
}

// MARK: - Dynamic Island

final class DynamicIsland {
    private var panel: NSPanel?
    private let state = NotchState()
    private var mediaKeyManager: MediaKeyManager?
    private var musicObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var batteryRunLoopSource: CFRunLoopSource?
    private var lastChargingState: Bool = false
    private var isAppActive = true

    init() {
        setupWindow()
        setupMusicDetection()
        setupMediaKeys()
        setupLockDetection()
        setupBatteryMonitoring()
        setupLifecycleObservers()
    }

    deinit {
        // Cleanup lifecycle observers
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        nowPlayingTimer?.invalidate()
    }

    // MARK: - Lifecycle Observers

    private func setupLifecycleObservers() {
        // Pause non-essential monitoring when displays sleep
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.pauseMonitoring()
            }
        )

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resumeMonitoring()
            }
        )
    }

    private func setupWindow() {
        guard let screen = NSScreen.main else { return }

        // Detect notch size
        detectNotchSize(screen: screen)

        let panel = NotchPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: true
        )

        let view = NotchContentView(state: state)
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()

        // Move to lock screen space so it's visible when locked
        LockScreenWindowManager.shared?.moveWindowToLockScreen(panel)

        self.panel = panel

        // Listen for screen changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func detectNotchSize(screen: NSScreen) {
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            state.notchHeight = safeTop
        } else {
            state.notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
        }

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            state.notchWidth = screen.frame.width - left.width - right.width
        } else {
            state.notchWidth = 200
        }
    }

    private func handleScreenChange() {
        guard let screen = NSScreen.main else { return }
        detectNotchSize(screen: screen)
        panel?.setFrame(screen.frame, display: true)
    }

    // MARK: - Music Detection

    private func setupMusicDetection() {
        let center = DistributedNotificationCenter.default()

        // Apple Music
        musicObservers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] notif in
            self?.handleGenericMusicNotification(notif, app: "Music")
        })

        // iTunes (legacy)
        musicObservers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.iTunes.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] notif in
            self?.handleGenericMusicNotification(notif, app: "Music")
        })

        // Spotify
        musicObservers.append(center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] notif in
            self?.handleSpotifyNotification(notif)
        })

        // TIDAL
        musicObservers.append(center.addObserver(
            forName: NSNotification.Name("com.tidal.desktop.playbackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] notif in
            self?.handleGenericMusicNotification(notif, app: "TIDAL")
        })

        // Deezer
        musicObservers.append(center.addObserver(
            forName: NSNotification.Name("com.deezer.Deezer.playbackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] notif in
            self?.handleGenericMusicNotification(notif, app: "Deezer")
        })

        // Amazon Music
        musicObservers.append(center.addObserver(
            forName: NSNotification.Name("com.amazon.music.playbackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] notif in
            self?.handleGenericMusicNotification(notif, app: "Amazon Music")
        })

        // Start Now Playing monitor for Safari/Chrome/etc
        startNowPlayingMonitor()
    }

    private func handleGenericMusicNotification(_ notif: Notification, app: String) {
        guard let info = notif.userInfo,
              let playerState = info["Player State"] as? String else { return }

        DispatchQueue.main.async {
            if playerState == "Playing" {
                self.state.activity = .music(app: app)
            } else if case .music(let currentApp) = self.state.activity, currentApp == app {
                self.state.activity = .none
            }
        }
    }

    private func handleSpotifyNotification(_ notif: Notification) {
        guard let info = notif.userInfo,
              let playerState = info["Player State"] as? String else { return }

        DispatchQueue.main.async {
            if playerState == "Playing" {
                self.state.activity = .music(app: "Spotify")
            } else if case .music(let app) = self.state.activity, app == "Spotify" {
                self.state.activity = .none
            }
        }
    }

    // MARK: - Now Playing Monitor (for browsers)

    private var nowPlayingTimer: Timer?
    private var isNowPlayingCheckPaused = false

    private func startNowPlayingMonitor() {
        // Monitor system Now Playing info for browsers
        // Uses longer interval (5s) to reduce CPU load - browser media isn't time-critical
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkNowPlayingIfNeeded()
        }
    }

    private func checkNowPlayingIfNeeded() {
        // Skip if a dedicated music app is already playing
        if case .music(let app) = state.activity {
            if app == "Spotify" || app == "Music" || app == "TIDAL" || app == "Deezer" || app == "Amazon Music" {
                return // Don't check - dedicated app has priority
            }
        }

        checkNowPlaying()
    }

    private func checkNowPlaying() {
        // Use MRMediaRemoteGetNowPlayingInfo if available
        // This catches Safari, Chrome, Firefox media playback
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
              let MRMediaRemoteGetNowPlayingInfoPointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else {
            return
        }

        typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        let MRMediaRemoteGetNowPlayingInfo = unsafeBitCast(MRMediaRemoteGetNowPlayingInfoPointer, to: MRMediaRemoteGetNowPlayingInfoFunction.self)

        MRMediaRemoteGetNowPlayingInfo(DispatchQueue.main) { [weak self] info in
            guard let self else { return }

            let isPlaying = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0

            if isPlaying {
                // Try to get app name
                var appName = "Media"
                if let bundleId = info["kMRMediaRemoteNowPlayingInfoClientPropertiesDeviceIdentifier"] as? String {
                    if bundleId.contains("safari") { appName = "Safari" }
                    else if bundleId.contains("chrome") { appName = "Chrome" }
                    else if bundleId.contains("firefox") { appName = "Firefox" }
                    else if bundleId.contains("arc") { appName = "Arc" }
                }

                // Only update if not already showing music from a dedicated app
                if case .music(let current) = self.state.activity {
                    // Don't override Spotify/Music with browser
                    if current == "Spotify" || current == "Music" { return }
                }

                if case .none = self.state.activity {
                    self.state.activity = .music(app: appName)
                }
            } else {
                // If we were showing browser media, clear it
                if case .music(let app) = self.state.activity {
                    if app == "Safari" || app == "Chrome" || app == "Firefox" || app == "Arc" || app == "Media" {
                        self.state.activity = .none
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle Management

    func pauseMonitoring() {
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = nil
    }

    func resumeMonitoring() {
        if nowPlayingTimer == nil {
            startNowPlayingMonitor()
        }
    }

    // MARK: - Media Keys

    private func setupMediaKeys() {
        mediaKeyManager = MediaKeyManager(state: state)
        mediaKeyManager?.start()
    }

    // MARK: - Lock Screen Detection

    private func setupLockDetection() {
        let center = DistributedNotificationCenter.default()

        // Screen locked
        lockObservers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenLocked()
        })

        // Screen unlocked
        lockObservers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenUnlocked()
        })
    }

    private var showLockIndicator: Bool {
        UserDefaults.standard.object(forKey: "showLockIndicator") as? Bool ?? true
    }

    private func handleScreenLocked() {
        DispatchQueue.main.async {
            self.state.isScreenLocked = true
            self.state.showUnlockAnimation = false
        }
    }

    private func handleScreenUnlocked() {
        DispatchQueue.main.async {
            self.state.isScreenLocked = false

            // Only show unlock animation if enabled
            guard self.showLockIndicator else { return }

            self.state.showUnlockAnimation = true

            // Play unlock sound
            self.playUnlockSound()

            // Strong haptic feedback
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

            // Second haptic after short delay for emphasis
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }

            // Third haptic for extra "unlock feel"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }

            // Hide unlock animation after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.state.showUnlockAnimation = false
            }
        }
    }

    private func playUnlockSound() {
        // Check if sound is enabled in settings
        let soundEnabled = UserDefaults.standard.object(forKey: "unlockSoundEnabled") as? Bool ?? true
        guard soundEnabled else { return }

        // Try Glass sound first (clean, pleasant)
        if let sound = NSSound(named: "Glass") {
            sound.volume = 0.4
            sound.play()
        } else if let sound = NSSound(named: "Blow") {
            sound.volume = 0.35
            sound.play()
        } else if let sound = NSSound(named: "Pop") {
            sound.volume = 0.4
            sound.play()
        } else {
            // Fallback to system sound
            AudioServicesPlaySystemSound(1057)
        }
    }

    // MARK: - Battery Monitoring

    private var showBatteryIndicator: Bool {
        UserDefaults.standard.object(forKey: "showBatteryIndicator") as? Bool ?? true
    }

    private func setupBatteryMonitoring() {
        // Get initial battery state
        updateBatteryInfo()
        lastChargingState = state.battery.isCharging

        // Event-driven: only listen for power source changes (no polling timer)
        let context = Unmanaged.passUnretained(self).toOpaque()

        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let island = Unmanaged<DynamicIsland>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                island.checkBatteryChanges()
            }
        }, context)?.takeRetainedValue() {
            batteryRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func checkBatteryChanges() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return
        }

        // Get current charging state SYNCHRONOUSLY
        let powerSource = info[kIOPSPowerSourceStateKey] as? String
        let isCharging = powerSource == kIOPSACPowerValue
        let wasCharging = lastChargingState

        // Update state on main thread
        DispatchQueue.main.async {
            // Battery level
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                self.state.battery.level = capacity
            }

            self.state.battery.isCharging = isCharging

            // Determine charging state
            if let isCharged = info[kIOPSIsChargedKey] as? Bool, isCharged {
                self.state.battery.chargingState = .full
            } else if isCharging {
                self.state.battery.chargingState = .charging
            } else {
                self.state.battery.chargingState = .unplugged
            }

            // Time remaining
            if let timeRemaining = info[kIOPSTimeToEmptyKey] as? Int, timeRemaining > 0 {
                self.state.battery.timeRemaining = timeRemaining
            } else if let timeToFull = info[kIOPSTimeToFullChargeKey] as? Int, timeToFull > 0 {
                self.state.battery.timeRemaining = timeToFull
            } else {
                self.state.battery.timeRemaining = nil
            }

            // Detect plug/unplug changes
            guard self.showBatteryIndicator else { return }

            if isCharging && !wasCharging {
                // Just plugged in
                self.triggerChargingStarted()
            } else if !isCharging && wasCharging {
                // Just unplugged
                self.triggerChargingStopped()
            }
        }

        // Update last state (synchronously, before next callback)
        lastChargingState = isCharging
    }

    private func updateBatteryInfo() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return
        }

        let powerSource = info[kIOPSPowerSourceStateKey] as? String
        let isCharging = powerSource == kIOPSACPowerValue

        DispatchQueue.main.async {
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                self.state.battery.level = capacity
            }

            self.state.battery.isCharging = isCharging

            if let isCharged = info[kIOPSIsChargedKey] as? Bool, isCharged {
                self.state.battery.chargingState = .full
            } else if isCharging {
                self.state.battery.chargingState = .charging
            } else {
                self.state.battery.chargingState = .unplugged
            }

            if let timeRemaining = info[kIOPSTimeToEmptyKey] as? Int, timeRemaining > 0 {
                self.state.battery.timeRemaining = timeRemaining
            } else if let timeToFull = info[kIOPSTimeToFullChargeKey] as? Int, timeToFull > 0 {
                self.state.battery.timeRemaining = timeToFull
            } else {
                self.state.battery.timeRemaining = nil
            }
        }

        // Update last state for initial setup
        lastChargingState = isCharging
    }

    private func triggerChargingStarted() {
        // Already on main thread
        state.showChargingAnimation = true
        state.isExpanded = true

        // Haptic feedback
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        // Play charging sound
        playChargingSound()

        // Hide animation after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.state.showChargingAnimation = false
            if !self.state.isHovered {
                self.state.isExpanded = false
            }
        }
    }

    private func triggerChargingStopped() {
        // Already on main thread
        state.showUnplugAnimation = true
        state.isExpanded = true

        // Haptic feedback
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        // Play unplug sound
        playUnplugSound()

        // Hide animation after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.state.showUnplugAnimation = false
            if !self.state.isHovered {
                self.state.isExpanded = false
            }
        }
    }

    private func playChargingSound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "chargingSoundEnabled") as? Bool ?? true
        guard soundEnabled else { return }

        // Pleasant charging sound
        if let sound = NSSound(named: "Blow") {
            sound.volume = 0.4
            sound.play()
        } else {
            AudioServicesPlaySystemSound(1004)
        }
    }

    private func playUnplugSound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "chargingSoundEnabled") as? Bool ?? true
        guard soundEnabled else { return }

        // Subtle unplug sound
        if let sound = NSSound(named: "Pop") {
            sound.volume = 0.35
            sound.play()
        } else {
            AudioServicesPlaySystemSound(1057)
        }
    }
}

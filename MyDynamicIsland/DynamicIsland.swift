import AppKit
import AudioToolbox
import Combine
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

// MARK: - Notch State

final class NotchState: ObservableObject {
    @Published var activity: LiveActivity = .none
    @Published var isExpanded: Bool = false
    @Published var isHovered: Bool = false
    @Published var hud: HUDType = .none
    @Published var isScreenLocked: Bool = false
    @Published var showUnlockAnimation: Bool = false

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

    init() {
        setupWindow()
        setupMusicDetection()
        setupMediaKeys()
        setupLockDetection()
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

    private func startNowPlayingMonitor() {
        // Monitor system Now Playing info for browsers
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkNowPlaying()
        }
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
}

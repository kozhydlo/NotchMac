import AppKit
import AudioToolbox
import Combine
import IOKit.ps
import SwiftUI

final class LockScreenWindowManager {
    static let shared: LockScreenWindowManager? = LockScreenWindowManager()

    private enum SpaceLevel: Int32 {
        case `default` = 0, setupAssistant = 100, securityAgent = 200
        case screenLock = 300, notificationCenterAtScreenLock = 400
        case bootProgress = 500, voiceOver = 600
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
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/SkyLight.framework")) else { return nil }

        guard let p1 = CFBundleGetFunctionPointerForName(bundle, "SLSMainConnectionID" as CFString),
              let p2 = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceCreate" as CFString),
              let p3 = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceDestroy" as CFString),
              let p4 = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceSetAbsoluteLevel" as CFString),
              let p5 = CFBundleGetFunctionPointerForName(bundle, "SLSShowSpaces" as CFString),
              let p6 = CFBundleGetFunctionPointerForName(bundle, "SLSHideSpaces" as CFString),
              let p7 = CFBundleGetFunctionPointerForName(bundle, "SLSSpaceAddWindowsAndRemoveFromSpaces" as CFString)
        else { return nil }

        SLSMainConnectionID = unsafeBitCast(p1, to: (@convention(c) () -> Int32).self)
        SLSSpaceCreate = unsafeBitCast(p2, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)
        SLSSpaceDestroy = unsafeBitCast(p3, to: (@convention(c) (Int32, Int32) -> Int32).self)
        SLSSpaceSetAbsoluteLevel = unsafeBitCast(p4, to: (@convention(c) (Int32, Int32, Int32) -> Int32).self)
        SLSShowSpaces = unsafeBitCast(p5, to: (@convention(c) (Int32, CFArray) -> Int32).self)
        SLSHideSpaces = unsafeBitCast(p6, to: (@convention(c) (Int32, CFArray) -> Int32).self)
        SLSSpaceAddWindowsAndRemoveFromSpaces = unsafeBitCast(p7, to: (@convention(c) (Int32, Int32, CFArray, Int32) -> Int32).self)

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

final class NotchPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
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

enum LiveActivity: Equatable {
    case none
    case music(app: String)
    case timer(remaining: TimeInterval, total: TimeInterval)
}

enum HUDType: Equatable {
    case none
    case volume(level: CGFloat, muted: Bool)
    case brightness(level: CGFloat)
}

enum HUDDisplayMode: String, CaseIterable {
    case minimal = "Minimal"
    case progressBar = "Progress Bar"
    case notched = "Notched"
}

struct BatteryInfo: Equatable {
    var level: Int = 100
    var isCharging: Bool = false
    var timeRemaining: Int? = nil
}

final class NotchState: ObservableObject {
    @Published var activity: LiveActivity = .none
    @Published var isExpanded = false
    @Published var isHovered = false
    @Published var hud: HUDType = .none
    @Published var isScreenLocked = false
    @Published var showUnlockAnimation = false
    @Published var battery = BatteryInfo()
    @Published var showChargingAnimation = false
    @Published var showUnplugAnimation = false
    @Published var notchWidth: CGFloat = 200
    @Published var notchHeight: CGFloat = 32
}

final class DynamicIsland {
    private var panel: NSPanel?
    private let state = NotchState()
    private var mediaKeyManager: MediaKeyManager?
    private var observers: [NSObjectProtocol] = []
    private var batteryRunLoopSource: CFRunLoopSource?
    private var lastChargingState = false
    private var nowPlayingTimer: Timer?

    init() {
        setupWindow()
        setupMusicDetection()
        setupMediaKeys()
        setupLockDetection()
        setupBatteryMonitoring()
        setupLifecycleObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        nowPlayingTimer?.invalidate()
    }

    private func setupWindow() {
        guard let screen = NSScreen.main else { return }
        detectNotchSize(screen: screen)

        let panel = NotchPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: true
        )

        panel.contentView = NSHostingView(rootView: NotchContentView(state: state))
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        LockScreenWindowManager.shared?.moveWindowToLockScreen(panel)
        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.handleScreenChange() }
    }

    private func detectNotchSize(screen: NSScreen) {
        state.notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : screen.frame.maxY - screen.visibleFrame.maxY
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
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

    private func setupLifecycleObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.nowPlayingTimer?.invalidate(); self?.nowPlayingTimer = nil })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.startNowPlayingMonitor() })
    }

    private func setupMusicDetection() {
        let center = DistributedNotificationCenter.default()
        let musicApps: [(String, String)] = [
            ("com.apple.Music.playerInfo", "Music"),
            ("com.apple.iTunes.playerInfo", "Music"),
            ("com.spotify.client.PlaybackStateChanged", "Spotify"),
            ("com.tidal.desktop.playbackStateChanged", "TIDAL"),
            ("com.deezer.Deezer.playbackStateChanged", "Deezer"),
            ("com.amazon.music.playbackStateChanged", "Amazon Music")
        ]

        for (notification, app) in musicApps {
            observers.append(center.addObserver(forName: NSNotification.Name(notification), object: nil, queue: .main) { [weak self] notif in
                self?.handleMusicNotification(notif, app: app)
            })
        }
        startNowPlayingMonitor()
    }

    private func handleMusicNotification(_ notif: Notification, app: String) {
        guard let info = notif.userInfo, let playerState = info["Player State"] as? String else { return }
        DispatchQueue.main.async {
            if playerState == "Playing" {
                self.state.activity = .music(app: app)
            } else if case .music(let currentApp) = self.state.activity, currentApp == app {
                self.state.activity = .none
            }
        }
    }

    private func startNowPlayingMonitor() {
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkNowPlaying()
        }
    }

    private func checkNowPlaying() {
        if case .music(let app) = state.activity, ["Spotify", "Music", "TIDAL", "Deezer", "Amazon Music"].contains(app) { return }

        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
              let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else { return }

        typealias Func = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        let getInfo = unsafeBitCast(ptr, to: Func.self)

        getInfo(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let isPlaying = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0

            if isPlaying {
                var appName = "Media"
                if let id = info["kMRMediaRemoteNowPlayingInfoClientPropertiesDeviceIdentifier"] as? String {
                    if id.contains("safari") { appName = "Safari" }
                    else if id.contains("chrome") { appName = "Chrome" }
                    else if id.contains("firefox") { appName = "Firefox" }
                    else if id.contains("arc") { appName = "Arc" }
                }
                if case .none = self.state.activity { self.state.activity = .music(app: appName) }
            } else if case .music(let app) = self.state.activity, ["Safari", "Chrome", "Firefox", "Arc", "Media"].contains(app) {
                self.state.activity = .none
            }
        }
    }

    private func setupMediaKeys() {
        mediaKeyManager = MediaKeyManager(state: state)
        mediaKeyManager?.start()
    }

    private func setupLockDetection() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.state.isScreenLocked = true
            self?.state.showUnlockAnimation = false
        })

        observers.append(center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, UserDefaults.standard.object(forKey: "showLockIndicator") as? Bool ?? true else { return }
            self.state.isScreenLocked = false
            self.state.showUnlockAnimation = true
            self.playSound("Glass", volume: 0.4, fallback: 1057)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.state.showUnlockAnimation = false }
        })
    }

    private func setupBatteryMonitoring() {
        updateBatteryInfo()
        lastChargingState = state.battery.isCharging

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let island = Unmanaged<DynamicIsland>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { island.checkBatteryChanges() }
        }, context)?.takeRetainedValue() {
            batteryRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func checkBatteryChanges() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { return }

        let isCharging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let wasCharging = lastChargingState
        lastChargingState = isCharging

        DispatchQueue.main.async {
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int { self.state.battery.level = capacity }
            self.state.battery.isCharging = isCharging
            if let time = info[kIOPSTimeToEmptyKey] as? Int, time > 0 { self.state.battery.timeRemaining = time }
            else if let time = info[kIOPSTimeToFullChargeKey] as? Int, time > 0 { self.state.battery.timeRemaining = time }
            else { self.state.battery.timeRemaining = nil }

            guard UserDefaults.standard.object(forKey: "showBatteryIndicator") as? Bool ?? true else { return }
            if isCharging && !wasCharging { self.triggerCharging(started: true) }
            else if !isCharging && wasCharging { self.triggerCharging(started: false) }
        }
    }

    private func updateBatteryInfo() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { return }

        let isCharging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        DispatchQueue.main.async {
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int { self.state.battery.level = capacity }
            self.state.battery.isCharging = isCharging
        }
        lastChargingState = isCharging
    }

    private func triggerCharging(started: Bool) {
        if started {
            state.showChargingAnimation = true
            state.isExpanded = true
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            playSound("Blow", volume: 0.4, fallback: 1004)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.state.showChargingAnimation = false
                if !self.state.isHovered { self.state.isExpanded = false }
            }
        } else {
            state.showUnplugAnimation = true
            state.isExpanded = true
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            playSound("Pop", volume: 0.35, fallback: 1057)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.state.showUnplugAnimation = false
                if !self.state.isHovered { self.state.isExpanded = false }
            }
        }
    }

    private func playSound(_ name: String, volume: Float, fallback: UInt32) {
        guard UserDefaults.standard.object(forKey: "chargingSoundEnabled") as? Bool ?? true else { return }
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = volume
            sound.play()
        } else {
            AudioServicesPlaySystemSound(fallback)
        }
    }
}

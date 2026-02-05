import AppKit
import Combine
import SwiftUI

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

    init() {
        setupWindow()
        setupMusicDetection()
        setupMediaKeys()
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
}

import Combine
import ServiceManagement
import SwiftUI

// MARK: - Main Content View (Full Screen)

struct NotchContentView: View {
    @ObservedObject var state: NotchState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()

                NotchView(state: state)
                    .contextMenu {
                        Button("Settings...") {
                            SettingsWindowController.shared.showSettings()
                        }
                        Divider()
                        Button("Quit") {
                            NSApp.terminate(nil)
                        }
                    }

                Spacer()
            }

            Spacer()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Notch View

struct NotchView: View {
    @ObservedObject var state: NotchState

    @State private var hoverTimer: Timer?
    @State private var collapseTimer: Timer?
    @State private var audioLevels: [CGFloat] = [0.3, 0.5, 0.7, 0.4, 0.6]

    private let audioTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    private var notchSize: CGSize {
        CGSize(
            width: state.notchWidth + (state.isExpanded ? 80 : 16),
            height: state.notchHeight + (state.isExpanded ? 60 : 0)
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Background
            NotchShape(topRadius: 8, bottomRadius: state.isExpanded ? 20 : 12)
                .fill(.black)

            // Content
            VStack(spacing: 0) {
                // Collapsed content (in notch area)
                collapsedContent
                    .frame(height: state.notchHeight)

                // Expanded content
                if state.isExpanded {
                    expandedContent
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(width: notchSize.width, height: notchSize.height)
        .scaleEffect(state.isHovered && !state.isExpanded ? 1.05 : 1.0, anchor: .top)
        .shadow(radius: state.isHovered ? 4 : 0)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: state.isExpanded)
        .animation(.easeOut(duration: 0.15), value: state.isHovered)
        .animation(.easeOut(duration: 0.2), value: state.hud)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { handleTap() }
        .onHover { handleHover($0) }
        .onReceive(audioTimer) { _ in
            if case .music = state.activity {
                animateAudioLevels()
            }
        }
        .onChange(of: state.hud) { _, newValue in
            if newValue != .none {
                showHUD()
            }
        }
    }

    // MARK: - Collapsed Content

    @ViewBuilder
    private var collapsedContent: some View {
        HStack(spacing: 0) {
            // Left side - icon
            leftIndicator
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)

            // Center notch space (camera area)
            Color.clear
                .frame(width: state.notchWidth - 16)

            // Right side - visualizer/progress
            rightIndicator
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
        }
    }

    @ViewBuilder
    private var leftIndicator: some View {
        // Only show activity indicators, NOT HUD (HUD shows in expanded view only)
        if case .music(let app) = state.activity {
            Image(systemName: musicIcon(for: app))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
        } else if case .timer = state.activity {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
        }
        // HUD indicators removed - only show in expanded view
    }

    @ViewBuilder
    private var rightIndicator: some View {
        // Only show activity indicators, NOT HUD
        if case .music = state.activity {
            // Audio visualizer
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.green)
                        .frame(width: 2.5, height: 6 + audioLevels[i] * 10)
                }
            }
        } else if case .timer(let remaining, let total) = state.activity {
            HStack(spacing: 6) {
                Text(formatTime(remaining))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .monospacedDigit()

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.orange.opacity(0.3))
                        .frame(width: 28, height: 4)
                    Capsule().fill(Color.orange)
                        .frame(width: 28 * CGFloat(remaining / max(total, 1)), height: 4)
                }
            }
        }
        // HUD mini bars removed - only show full HUD in expanded view
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 8) {
            switch state.hud {
            case .volume(let level, let muted):
                volumeHUD(level: level, muted: muted)

            case .brightness(let level):
                brightnessHUD(level: level)

            case .none:
                switch state.activity {
                case .music(let app):
                    musicExpanded(app: app)

                case .timer(let remaining, _):
                    timerExpanded(remaining: remaining)

                case .none:
                    defaultExpanded
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func volumeHUD(level: CGFloat, muted: Bool) -> some View {
        let displayLevel = muted ? 0 : level

        return HStack(spacing: 12) {
            // Icon with glow effect
            Image(systemName: muted ? "speaker.slash.fill" : volumeIconFor(level))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(0.3), radius: 4)
                .frame(width: 28)

            // Beautiful progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.15))

                    // Filled portion with gradient
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.9), .white],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * displayLevel))
                        .shadow(color: .white.opacity(0.4), radius: 3, x: 0, y: 0)
                }
            }
            .frame(height: 8)

            // Percentage
            Text("\(Int(displayLevel * 100))")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 36)
        .animation(.easeOut(duration: 0.15), value: displayLevel)
    }

    private func brightnessHUD(level: CGFloat) -> some View {
        HStack(spacing: 12) {
            // Icon with warm glow
            Image(systemName: level > 0.5 ? "sun.max.fill" : "sun.min.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.yellow)
                .shadow(color: .yellow.opacity(0.5), radius: 6)
                .frame(width: 28)

            // Beautiful progress bar with warm gradient
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.yellow.opacity(0.15))

                    // Filled portion with gradient
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.orange, .yellow],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * level))
                        .shadow(color: .yellow.opacity(0.5), radius: 4, x: 0, y: 0)
                }
            }
            .frame(height: 8)

            // Percentage
            Text("\(Int(level * 100))")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.yellow)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 36)
        .animation(.easeOut(duration: 0.15), value: level)
    }

    private func musicExpanded(app: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: musicIcon(for: app))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Now Playing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(app)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.green)
                        .frame(width: 3, height: 10 + audioLevels[i] * 16)
                }
            }
        }
    }

    private func timerExpanded(remaining: TimeInterval) -> some View {
        VStack(spacing: 4) {
            Text(formatTimeLarge(remaining))
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .foregroundStyle(.orange)
                .monospacedDigit()

            Text("Timer")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var defaultExpanded: some View {
        VStack(spacing: 4) {
            Text(timeString)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()

            Text(dateString)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Interactions

    private func handleTap() {
        hoverTimer?.invalidate()
        collapseTimer?.invalidate()

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        withAnimation {
            if state.isExpanded {
                state.hud = .none
                state.isExpanded = false
            } else {
                state.isExpanded = true
                scheduleCollapse(delay: 4)
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTimer?.invalidate()

        withAnimation {
            state.isHovered = hovering
        }

        if hovering {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                DispatchQueue.main.async {
                    guard !state.isExpanded else { return }
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    withAnimation {
                        state.isExpanded = true
                    }
                    scheduleCollapse(delay: 4)
                }
            }
        } else {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                DispatchQueue.main.async {
                    guard state.hud == .none else { return }
                    withAnimation {
                        state.isExpanded = false
                    }
                }
            }
        }
    }

    private func showHUD() {
        collapseTimer?.invalidate()

        withAnimation {
            state.isExpanded = true
        }

        scheduleCollapse(delay: 2)
    }

    private func scheduleCollapse(delay: TimeInterval) {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation {
                    state.hud = .none
                    state.isExpanded = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func musicIcon(for app: String) -> String {
        switch app.lowercased() {
        case "spotify": return "music.note"
        case "music": return "music.quarternote.3"
        case "safari": return "safari"
        case "chrome": return "globe"
        case "firefox": return "flame"
        case "arc": return "globe"
        case "tidal": return "waveform"
        case "deezer": return "waveform"
        case "amazon music": return "music.note.list"
        case "podcasts": return "mic"
        default: return "music.note"
        }
    }

    private var volumeIcon: String {
        if case .volume(let level, let muted) = state.hud {
            return volumeIconFor(muted ? 0 : level)
        }
        return "speaker.fill"
    }

    private func volumeIconFor(_ level: CGFloat) -> String {
        if level == 0 { return "speaker.slash.fill" }
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var brightnessIcon: String {
        if case .brightness(let level) = state.hud {
            return level > 0.5 ? "sun.max.fill" : "sun.min.fill"
        }
        return "sun.max.fill"
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatTimeLarge(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: Date())
    }

    private func animateAudioLevels() {
        withAnimation(.easeInOut(duration: 0.1)) {
            audioLevels = audioLevels.map { _ in CGFloat.random(in: 0.15...1.0) }
        }
    }
}

// MARK: - Settings Window

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func showSettings() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Dynamic Island Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 400, height: 300))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

struct SettingsView: View {
    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage("showHapticFeedback") private var showHapticFeedback = true
    @AppStorage("autoCollapseDelay") private var autoCollapseDelay = 4.0
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("hideFromDock") private var hideFromDock = false
    @AppStorage("showVolumeHUD") private var showVolumeHUD = true
    @AppStorage("showBrightnessHUD") private var showBrightnessHUD = true
    @AppStorage("showMusicActivity") private var showMusicActivity = true

    var body: some View {
        TabView {
            // General Tab
            Form {
                Section {
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            LaunchAtLogin.setEnabled(newValue)
                        }

                    Toggle("Hide from Dock", isOn: $hideFromDock)
                        .onChange(of: hideFromDock) { _, newValue in
                            setDockVisibility(hidden: newValue)
                        }
                } header: {
                    Text("System")
                }

                Section {
                    Toggle("Expand on hover", isOn: $expandOnHover)
                    Toggle("Haptic feedback", isOn: $showHapticFeedback)

                    Picker("Auto-collapse", selection: $autoCollapseDelay) {
                        Text("2 seconds").tag(2.0)
                        Text("4 seconds").tag(4.0)
                        Text("6 seconds").tag(6.0)
                        Text("Never").tag(0.0)
                    }
                } header: {
                    Text("Behavior")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            // Features Tab
            Form {
                Section {
                    Toggle("Volume HUD", isOn: $showVolumeHUD)
                    Toggle("Brightness HUD", isOn: $showBrightnessHUD)
                } header: {
                    Text("System Controls")
                } footer: {
                    Text("Replace system volume and brightness overlays")
                }

                Section {
                    Toggle("Music Activity", isOn: $showMusicActivity)
                } header: {
                    Text("Live Activities")
                } footer: {
                    Text("Show now playing info from Spotify, Apple Music, browsers, etc.")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Features", systemImage: "sparkles")
            }

            // About Tab
            Form {
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Developer")
                        Spacer()
                        Text("You")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("App Info")
                }

                Section {
                    Button("Quit Dynamic Island") {
                        NSApp.terminate(nil)
                    }
                    .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
        }
        .frame(width: 420, height: 340)
    }

    private func setDockVisibility(hidden: Bool) {
        if hidden {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
}

// MARK: - Launch at Login Helper

enum LaunchAtLogin {
    static func setEnabled(_ enabled: Bool) {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if enabled {
            // Add to login items using SMAppService (macOS 13+)
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.register()
            }
        } else {
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.unregister()
            }
        }
    }
}

// MARK: - Notch Shape

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Start top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left corner curve
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )

        // Left side down
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))

        // Bottom-left corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))

        // Bottom-right corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )

        // Right side up
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))

        // Top-right corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )

        // Close
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}

import Combine
import IOKit.ps
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
        HStack(spacing: 16) {
            // Left: Time & Date
            VStack(alignment: .leading, spacing: 2) {
                Text(timeString)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                Text(dateString)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Right: Quick Stats
            HStack(spacing: 12) {
                // Battery indicator
                QuickStatView(
                    icon: batteryIcon,
                    value: "\(batteryLevel)%",
                    color: batteryColor
                )

                // WiFi indicator
                QuickStatView(
                    icon: "wifi",
                    value: wifiName,
                    color: .cyan
                )
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Quick Stats Helpers

    private var batteryLevel: Int {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []

        for source in sources {
            if let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                return capacity
            }
        }
        return 100
    }

    private var batteryIcon: String {
        let level = batteryLevel
        if level > 75 { return "battery.100" }
        if level > 50 { return "battery.75" }
        if level > 25 { return "battery.50" }
        if level > 10 { return "battery.25" }
        return "battery.0"
    }

    private var batteryColor: Color {
        let level = batteryLevel
        if level > 20 { return .green }
        if level > 10 { return .orange }
        return .red
    }

    private var wifiName: String {
        // Get current WiFi name
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getairportnetwork", "en0"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let parts = output.components(separatedBy: ": ")
                if parts.count > 1 {
                    return String(parts[1].trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
                }
            }
        } catch {}

        return "Wi-Fi"
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
                    guard !self.state.isExpanded else { return }
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    withAnimation {
                        self.state.isExpanded = true
                    }
                    self.scheduleCollapse(delay: 4)
                }
            }
        } else {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                DispatchQueue.main.async {
                    guard self.state.hud == .none else { return }
                    withAnimation {
                        self.state.isExpanded = false
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
                    self.state.hud = .none
                    self.state.isExpanded = false
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

// MARK: - Quick Stat View

struct QuickStatView: View {
    let icon: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)

            Text(value)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(width: 40)
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
        window.title = "NotchMac Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 450))
        window.minSize = NSSize(width: 550, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

// MARK: - Settings View with Sidebar

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case volume = "Volume"
        case brightness = "Brightness"
        case music = "Music"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .volume: return "speaker.wave.3.fill"
            case .brightness: return "sun.max.fill"
            case .music: return "music.note"
            case .about: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .general: return .gray
            case .volume: return .blue
            case .brightness: return .orange
            case .music: return .green
            case .about: return .purple
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label {
                    Text(tab.rawValue)
                } icon: {
                    Image(systemName: tab.icon)
                        .foregroundStyle(tab.color)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                case .volume:
                    VolumeSettingsView()
                case .brightness:
                    BrightnessSettingsView()
                case .music:
                    MusicSettingsView()
                case .about:
                    AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 450)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage("showHapticFeedback") private var showHapticFeedback = true
    @AppStorage("autoCollapseDelay") private var autoCollapseDelay = 4.0
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("hideFromDock") private var hideFromDock = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                SettingsHeader(title: "General", subtitle: "Basic app settings", icon: "gearshape.fill", color: .gray)

                // System Section
                SettingsSection(title: "System") {
                    SettingsToggleRow(
                        title: "Launch at Login",
                        subtitle: "Start NotchMac when you log in",
                        icon: "power",
                        color: .green,
                        isOn: $launchAtLogin
                    )
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.setEnabled(newValue)
                    }

                    Divider().padding(.horizontal)

                    SettingsToggleRow(
                        title: "Hide from Dock",
                        subtitle: "Only show in menu bar area",
                        icon: "dock.arrow.down.rectangle",
                        color: .blue,
                        isOn: $hideFromDock
                    )
                    .onChange(of: hideFromDock) { _, newValue in
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                    }
                }

                // Behavior Section
                SettingsSection(title: "Behavior") {
                    SettingsToggleRow(
                        title: "Expand on Hover",
                        subtitle: "Open menu when hovering over notch",
                        icon: "cursorarrow.motionlines",
                        color: .orange,
                        isOn: $expandOnHover
                    )

                    Divider().padding(.horizontal)

                    SettingsToggleRow(
                        title: "Haptic Feedback",
                        subtitle: "Vibration on interactions",
                        icon: "hand.tap.fill",
                        color: .purple,
                        isOn: $showHapticFeedback
                    )

                    Divider().padding(.horizontal)

                    SettingsPickerRow(
                        title: "Auto Collapse",
                        subtitle: "Time before menu closes",
                        icon: "timer",
                        color: .cyan,
                        selection: $autoCollapseDelay,
                        options: [
                            (2.0, "2s"),
                            (4.0, "4s"),
                            (6.0, "6s"),
                            (0.0, "Never")
                        ]
                    )
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

// MARK: - Volume Settings

struct VolumeSettingsView: View {
    @AppStorage("showVolumeHUD") private var showVolumeHUD = true
    @AppStorage("volumeHUDStyle") private var volumeHUDStyle = "modern"
    @AppStorage("volumeHUDColor") private var volumeHUDColor = "white"
    @AppStorage("volumeAnimationSpeed") private var volumeAnimationSpeed = 0.15

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "Volume HUD", subtitle: "Customize volume indicator", icon: "speaker.wave.3.fill", color: .blue)

                SettingsSection(title: "General") {
                    SettingsToggleRow(
                        title: "Enable Volume HUD",
                        subtitle: "Replace system volume overlay",
                        icon: "speaker.wave.2.fill",
                        color: .blue,
                        isOn: $showVolumeHUD
                    )
                }

                if showVolumeHUD {
                    SettingsSection(title: "Appearance") {
                        SettingsPickerRow(
                            title: "Style",
                            subtitle: "Visual appearance",
                            icon: "paintbrush.fill",
                            color: .pink,
                            selection: $volumeHUDStyle,
                            options: [
                                ("modern", "Modern"),
                                ("minimal", "Minimal"),
                                ("classic", "Classic")
                            ]
                        )

                        Divider().padding(.horizontal)

                        SettingsPickerRow(
                            title: "Color",
                            subtitle: "Progress bar color",
                            icon: "paintpalette.fill",
                            color: .purple,
                            selection: $volumeHUDColor,
                            options: [
                                ("white", "White"),
                                ("blue", "Blue"),
                                ("green", "Green"),
                                ("rainbow", "Rainbow")
                            ]
                        )
                    }

                    SettingsSection(title: "Animation") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "hare.fill")
                                    .foregroundStyle(.orange)
                                Text("Animation Speed")
                                Spacer()
                                Text(String(format: "%.2fs", volumeAnimationSpeed))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.top, 12)

                            Slider(value: $volumeAnimationSpeed, in: 0.05...0.5, step: 0.05)
                                .padding(.horizontal)
                                .padding(.bottom, 12)
                        }
                    }

                    // Preview
                    SettingsSection(title: "Preview") {
                        VolumePreview(style: volumeHUDStyle, color: volumeHUDColor)
                            .padding()
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

// MARK: - Brightness Settings

struct BrightnessSettingsView: View {
    @AppStorage("showBrightnessHUD") private var showBrightnessHUD = true
    @AppStorage("brightnessHUDStyle") private var brightnessHUDStyle = "modern"
    @AppStorage("brightnessHUDColor") private var brightnessHUDColor = "yellow"
    @AppStorage("brightnessAnimationSpeed") private var brightnessAnimationSpeed = 0.15

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "Brightness HUD", subtitle: "Customize brightness indicator", icon: "sun.max.fill", color: .orange)

                SettingsSection(title: "General") {
                    SettingsToggleRow(
                        title: "Enable Brightness HUD",
                        subtitle: "Replace system brightness overlay",
                        icon: "sun.min.fill",
                        color: .orange,
                        isOn: $showBrightnessHUD
                    )
                }

                if showBrightnessHUD {
                    SettingsSection(title: "Appearance") {
                        SettingsPickerRow(
                            title: "Style",
                            subtitle: "Visual appearance",
                            icon: "paintbrush.fill",
                            color: .pink,
                            selection: $brightnessHUDStyle,
                            options: [
                                ("modern", "Modern"),
                                ("minimal", "Minimal"),
                                ("classic", "Classic")
                            ]
                        )

                        Divider().padding(.horizontal)

                        SettingsPickerRow(
                            title: "Color",
                            subtitle: "Progress bar color",
                            icon: "paintpalette.fill",
                            color: .purple,
                            selection: $brightnessHUDColor,
                            options: [
                                ("yellow", "Yellow"),
                                ("orange", "Orange"),
                                ("white", "White"),
                                ("rainbow", "Rainbow")
                            ]
                        )
                    }

                    SettingsSection(title: "Animation") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "hare.fill")
                                    .foregroundStyle(.orange)
                                Text("Animation Speed")
                                Spacer()
                                Text(String(format: "%.2fs", brightnessAnimationSpeed))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.top, 12)

                            Slider(value: $brightnessAnimationSpeed, in: 0.05...0.5, step: 0.05)
                                .padding(.horizontal)
                                .padding(.bottom, 12)
                        }
                    }

                    // Preview
                    SettingsSection(title: "Preview") {
                        BrightnessPreview(style: brightnessHUDStyle, color: brightnessHUDColor)
                            .padding()
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

// MARK: - Music Settings

struct MusicSettingsView: View {
    @AppStorage("showMusicActivity") private var showMusicActivity = true
    @AppStorage("showMusicVisualizer") private var showMusicVisualizer = true
    @AppStorage("musicVisualizerColor") private var musicVisualizerColor = "green"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "Music Activity", subtitle: "Now playing settings", icon: "music.note", color: .green)

                SettingsSection(title: "General") {
                    SettingsToggleRow(
                        title: "Show Music Activity",
                        subtitle: "Display now playing in notch",
                        icon: "music.note.list",
                        color: .green,
                        isOn: $showMusicActivity
                    )
                }

                if showMusicActivity {
                    SettingsSection(title: "Visualizer") {
                        SettingsToggleRow(
                            title: "Audio Visualizer",
                            subtitle: "Animated bars when playing",
                            icon: "waveform",
                            color: .cyan,
                            isOn: $showMusicVisualizer
                        )

                        Divider().padding(.horizontal)

                        SettingsPickerRow(
                            title: "Visualizer Color",
                            subtitle: "Color of the bars",
                            icon: "paintpalette.fill",
                            color: .purple,
                            selection: $musicVisualizerColor,
                            options: [
                                ("green", "Green"),
                                ("blue", "Blue"),
                                ("pink", "Pink"),
                                ("rainbow", "Rainbow")
                            ]
                        )
                    }

                    SettingsSection(title: "Supported Apps") {
                        VStack(alignment: .leading, spacing: 8) {
                            SupportedAppRow(name: "Apple Music", icon: "music.quarternote.3")
                            SupportedAppRow(name: "Spotify", icon: "music.note")
                            SupportedAppRow(name: "Safari", icon: "safari")
                            SupportedAppRow(name: "Chrome", icon: "globe")
                            SupportedAppRow(name: "Firefox", icon: "flame")
                            SupportedAppRow(name: "TIDAL", icon: "waveform")
                        }
                        .padding()
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

struct SupportedAppRow: View {
    let name: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(name)
                .font(.system(size: 13))
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App Icon & Name
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [.purple, .blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 100, height: 100)

                        Image(systemName: "sparkles")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.white)
                    }

                    Text("NotchMac")
                        .font(.system(size: 28, weight: .bold))

                    Text("Dynamic Island for macOS")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    Text("Version 1.0.0")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(8)
                }
                .padding(.top, 20)

                // Links Section
                SettingsSection(title: "Links") {
                    Link(destination: URL(string: "https://github.com/kozhydlo/NotchMac")!) {
                        HStack {
                            Image(systemName: "link")
                                .foregroundStyle(.blue)
                            Text("GitHub Repository")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.horizontal)

                    Link(destination: URL(string: "https://kozhydlo.vercel.app")!) {
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading) {
                                Text("Developer")
                                Text("Kozhydlo Mark")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .buttonStyle(.plain)
                }

                // Quit Button
                Button(action: { NSApp.terminate(nil) }) {
                    HStack {
                        Image(systemName: "power")
                        Text("Quit NotchMac")
                    }
                    .foregroundStyle(.red)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)

                Text("Made with ❤️ in Ukraine")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(24)
        }
    }
}

// MARK: - Settings Components

struct SettingsHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 8)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.15))
                    .cornerRadius(6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(12)
    }
}

struct SettingsPickerRow<T: Hashable>: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.15))
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
        .padding(12)
    }
}

// MARK: - HUD Previews

struct VolumePreview: View {
    let style: String
    let color: String
    @State private var level: CGFloat = 0.7

    var barColor: Color {
        switch color {
        case "blue": return .blue
        case "green": return .green
        case "rainbow": return .purple
        default: return .white
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 18))
                .foregroundStyle(barColor)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: style == "minimal" ? 2 : 4)
                        .fill(barColor.opacity(0.2))
                    RoundedRectangle(cornerRadius: style == "minimal" ? 2 : 4)
                        .fill(barColor)
                        .frame(width: geo.size.width * level)
                }
            }
            .frame(height: style == "minimal" ? 4 : 8)

            Text("\(Int(level * 100))")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(barColor)
                .frame(width: 30)
        }
        .padding()
        .background(Color.black)
        .cornerRadius(12)
    }
}

struct BrightnessPreview: View {
    let style: String
    let color: String
    @State private var level: CGFloat = 0.65

    var barColor: Color {
        switch color {
        case "orange": return .orange
        case "white": return .white
        case "rainbow": return .pink
        default: return .yellow
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 18))
                .foregroundStyle(barColor)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: style == "minimal" ? 2 : 4)
                        .fill(barColor.opacity(0.2))
                    RoundedRectangle(cornerRadius: style == "minimal" ? 2 : 4)
                        .fill(barColor)
                        .frame(width: geo.size.width * level)
                }
            }
            .frame(height: style == "minimal" ? 4 : 8)

            Text("\(Int(level * 100))")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(barColor)
                .frame(width: 30)
        }
        .padding()
        .background(Color.black)
        .cornerRadius(12)
    }
}

// MARK: - Launch at Login Helper

enum LaunchAtLogin {
    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            if enabled {
                try? SMAppService.mainApp.register()
            } else {
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

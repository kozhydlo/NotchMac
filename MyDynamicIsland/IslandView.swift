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
    @State private var audioTimerCancellable: AnyCancellable?

    // Audio timer only created when music is playing
    private var audioTimerPublisher: AnyPublisher<Date, Never> {
        Timer.publish(every: 0.15, on: .main, in: .common).autoconnect().eraseToAnyPublisher()
    }

    private var hudDisplayMode: String {
        UserDefaults.standard.string(forKey: "hudDisplayMode") ?? "progressBar"
    }

    private var isMinimalMode: Bool {
        hudDisplayMode == "minimal"
    }

    private var notchSize: CGSize {
        // Check if we should use minimal mode (no expansion)
        let shouldExpand = !isMinimalMode || state.hud == .none

        // Base extra width
        var baseExtra: CGFloat = 16
        if state.isExpanded && shouldExpand {
            baseExtra = 100
        } else if state.hud != .none && isMinimalMode {
            baseExtra = 60 // Slightly wider for minimal HUD
        }

        // Extra width for special states (lock, charging)
        var stateExtraWidth: CGFloat = 0
        if state.isScreenLocked {
            stateExtraWidth = 140
        } else if state.battery.isCharging || state.showChargingAnimation {
            stateExtraWidth = 80
        }

        // Taller expanded view (not for minimal mode HUD)
        var expandedHeight: CGFloat = 0
        if state.isExpanded && shouldExpand {
            expandedHeight = 75
        }

        return CGSize(
            width: state.notchWidth + baseExtra + stateExtraWidth,
            height: state.notchHeight + expandedHeight
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
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .top)).combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                            )
                        )
                }
            }
        }
        .frame(width: notchSize.width, height: notchSize.height)
        .scaleEffect(state.isHovered && !state.isExpanded ? 1.08 : 1.0, anchor: .top)
        .shadow(color: .black.opacity(0.3), radius: state.isExpanded ? 20 : (state.isHovered ? 8 : 0), y: state.isExpanded ? 10 : 0)
        .animation(.spring(duration: 0.5, bounce: 0.35, blendDuration: 0.25), value: state.isExpanded)
        .animation(.spring(duration: 0.25, bounce: 0.4), value: state.isHovered)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: state.hud)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { handleTap() }
        .onHover { handleHover($0) }
        .onChange(of: state.activity) { _, newActivity in
            // Start or stop audio animation timer based on music state
            if case .music = newActivity {
                startAudioTimer()
            } else {
                stopAudioTimer()
            }
        }
        .onAppear {
            // Start audio timer if already playing music
            if case .music = state.activity {
                startAudioTimer()
            }
        }
        .onDisappear {
            stopAudioTimer()
        }
        .onChange(of: state.hud) { _, newValue in
            if newValue != .none {
                showHUD()
            }
        }
        .onChange(of: state.showUnlockAnimation) { _, newValue in
            if newValue {
                // Auto expand on unlock
                withAnimation(.spring(duration: 0.5, bounce: 0.35)) {
                    state.isExpanded = true
                }
                // Reset unlock animation state
                unlockScale = 0.5
                unlockOpacity = 0
                // Auto collapse after showing unlock
                scheduleCollapse(delay: 2.0)
            }
        }
        .onChange(of: state.isScreenLocked) { _, isLocked in
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                if isLocked {
                    // Optionally show locked state briefly
                    state.isExpanded = true
                    scheduleCollapse(delay: 1.5)
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: state.isScreenLocked)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: state.showUnlockAnimation)
    }

    // MARK: - Collapsed Content

    @ViewBuilder
    private var collapsedContent: some View {
        HStack(spacing: 0) {
            // Left side - icon or minimal HUD
            HStack(spacing: 6) {
                if isMinimalMode, case .volume(let level, let muted) = state.hud {
                    MinimalVolumeHUD(level: level, muted: muted)
                } else if isMinimalMode, case .brightness(let level) = state.hud {
                    MinimalBrightnessHUD(level: level)
                } else {
                    leftIndicator
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 12)

            // Center notch space (camera area)
            Color.clear
                .frame(width: state.notchWidth - 16)

            // Right side - icon or minimal HUD percentage
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if isMinimalMode, case .volume(let level, let muted) = state.hud {
                    Text(muted ? "Mute" : "\(Int(level * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                } else if isMinimalMode, case .brightness(let level) = state.hud {
                    Text("\(Int(level * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.yellow)
                        .monospacedDigit()
                } else {
                    rightIndicator
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 12)
        }
    }

    private var showLockIndicator: Bool {
        UserDefaults.standard.object(forKey: "showLockIndicator") as? Bool ?? true
    }

    @ViewBuilder
    private var leftIndicator: some View {
        // Lock icon takes priority (if enabled) - ALWAYS show when locked
        if state.isScreenLocked && showLockIndicator {
            LockIconView()
        } else if state.showUnlockAnimation && showLockIndicator {
            // Unlock animation
            Image(systemName: "lock.open.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .shadow(color: .green.opacity(0.8), radius: 6)
                .transition(.scale.combined(with: .opacity))
        } else if case .music(let app) = state.activity {
            Image(systemName: musicIcon(for: app))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        } else if case .timer = state.activity {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var showBatteryIndicator: Bool {
        UserDefaults.standard.object(forKey: "showBatteryIndicator") as? Bool ?? true
    }

    @ViewBuilder
    private var rightIndicator: some View {
        // Lock state indicators (if enabled)
        if state.isScreenLocked && showLockIndicator {
            // Locked indicator - pulsing dot
            LockPulsingDot()
        } else if state.showUnlockAnimation && showLockIndicator {
            // Unlock checkmark animation
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        } else if state.showChargingAnimation && showBatteryIndicator {
            // Charging animation
            ChargingIndicator(level: state.battery.level)
        } else if state.showUnplugAnimation && showBatteryIndicator {
            // Unplug animation
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.gray)
                .transition(.scale.combined(with: .opacity))
        } else if state.battery.isCharging && showBatteryIndicator {
            // Show charging indicator when charging
            ChargingIndicator(level: state.battery.level)
        } else if case .music = state.activity {
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
                // Check for charging/unplug animations first
                if state.showChargingAnimation && showBatteryIndicator {
                    chargingExpanded
                } else if state.showUnplugAnimation && showBatteryIndicator {
                    unplugExpanded
                // Check for unlock animation (if enabled)
                } else if state.showUnlockAnimation && showLockIndicator {
                    unlockExpanded
                } else if state.isScreenLocked && showLockIndicator {
                    lockedExpanded
                } else {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func volumeHUD(level: CGFloat, muted: Bool) -> some View {
        let mode = hudDisplayMode

        switch mode {
        case "notched":
            NotchedVolumeHUD(level: level, muted: muted)
        default: // progressBar
            ProgressBarVolumeHUD(level: level, muted: muted)
        }
    }

    @ViewBuilder
    private func brightnessHUD(level: CGFloat) -> some View {
        let mode = hudDisplayMode

        switch mode {
        case "notched":
            NotchedBrightnessHUD(level: level)
        default: // progressBar
            ProgressBarBrightnessHUD(level: level)
        }
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
        CalendarWidgetView()
    }

    @State private var lockPulse: Bool = false

    private var lockedExpanded: some View {
        HStack(spacing: 12) {
            ZStack {
                // Glow effect
                Circle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .scaleEffect(lockPulse ? 1.2 : 1.0)
                    .opacity(lockPulse ? 0.5 : 0.8)

                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.orange)
                    .shadow(color: .orange.opacity(0.5), radius: 6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Locked")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Touch ID or enter password")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Pulsing indicator
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: .orange, radius: 4)
                .scaleEffect(lockPulse ? 1.3 : 1.0)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                lockPulse = true
            }
        }
        .onDisappear {
            lockPulse = false
        }
    }

    @State private var unlockScale: CGFloat = 0.5
    @State private var unlockOpacity: CGFloat = 0

    private var unlockExpanded: some View {
        HStack(spacing: 14) {
            ZStack {
                // Success circle background
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.green.opacity(0.3), .green.opacity(0.1), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
                    .frame(width: 50, height: 50)
                    .scaleEffect(unlockScale)
                    .opacity(unlockOpacity)

                Image(systemName: "lock.open.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.green)
                    .shadow(color: .green.opacity(0.5), radius: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Unlocked")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text("Welcome back!")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
                .scaleEffect(unlockScale)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.5)) {
                unlockScale = 1.2
                unlockOpacity = 1
            }
            withAnimation(.spring(duration: 0.3, bounce: 0.2).delay(0.3)) {
                unlockScale = 1.0
            }
        }
    }

    // MARK: - Charging Expanded View

    @State private var chargingBoltScale: CGFloat = 0.5
    @State private var chargingGlow: Bool = false

    private var chargingExpanded: some View {
        HStack(spacing: 14) {
            ZStack {
                // Glow effect
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.green.opacity(0.4), .green.opacity(0.1), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 35
                        )
                    )
                    .frame(width: 60, height: 60)
                    .scaleEffect(chargingGlow ? 1.3 : 1.0)
                    .opacity(chargingGlow ? 0.5 : 0.8)

                Image(systemName: "bolt.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.green)
                    .shadow(color: .green.opacity(0.7), radius: 10)
                    .scaleEffect(chargingBoltScale)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Charging")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    Text("\(state.battery.level)%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                        .monospacedDigit()

                    // Battery bar
                    BatteryBarView(level: state.battery.level, isCharging: true)
                }
            }

            Spacer()
        }
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.4)) {
                chargingBoltScale = 1.2
            }
            withAnimation(.spring(duration: 0.3).delay(0.2)) {
                chargingBoltScale = 1.0
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                chargingGlow = true
            }
        }
        .onDisappear {
            chargingBoltScale = 0.5
            chargingGlow = false
        }
    }

    // MARK: - Unplug Expanded View

    @State private var unplugScale: CGFloat = 1.2

    private var unplugExpanded: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 50, height: 50)

                Image(systemName: "powerplug.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.gray)
                    .scaleEffect(unplugScale)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Unplugged")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    Text("\(state.battery.level)%")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(state.battery.level <= 20 ? .red : .white.opacity(0.7))
                        .monospacedDigit()

                    if let time = state.battery.timeRemaining, time > 0 {
                        Text("• \(formatBatteryTime(time)) remaining")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            Spacer()

            BatteryBarView(level: state.battery.level, isCharging: false)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                unplugScale = 1.0
            }
        }
        .onDisappear {
            unplugScale = 1.2
        }
    }

    private func formatBatteryTime(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
    }

    // MARK: - Interactions

    private func handleTap() {
        hoverTimer?.invalidate()
        collapseTimer?.invalidate()

        if hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }

        withAnimation(.spring(duration: 0.5, bounce: 0.35)) {
            if state.isExpanded {
                state.hud = .none
                state.isExpanded = false
            } else {
                state.isExpanded = true
                scheduleCollapse(delay: 4)
            }
        }
    }

    private var hapticEnabled: Bool {
        UserDefaults.standard.object(forKey: "showHapticFeedback") as? Bool ?? true
    }

    private func handleHover(_ hovering: Bool) {
        hoverTimer?.invalidate()

        // Haptic feedback on hover START
        if hovering && hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }

        withAnimation(.spring(duration: 0.25, bounce: 0.4)) {
            state.isHovered = hovering
        }

        if hovering {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                DispatchQueue.main.async {
                    guard !self.state.isExpanded else { return }
                    // Stronger haptic when expanding
                    if self.hapticEnabled {
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    }
                    withAnimation(.spring(duration: 0.5, bounce: 0.35)) {
                        self.state.isExpanded = true
                    }
                    self.scheduleCollapse(delay: 4)
                }
            }
        } else {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                DispatchQueue.main.async {
                    guard self.state.hud == .none else { return }
                    withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                        self.state.isExpanded = false
                    }
                }
            }
        }
    }

    private func showHUD() {
        collapseTimer?.invalidate()

        // In minimal mode, don't expand - just show inline
        if !isMinimalMode {
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                state.isExpanded = true
            }
        }

        scheduleCollapse(delay: isMinimalMode ? 1.5 : 2)
    }

    private func scheduleCollapse(delay: TimeInterval) {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                    self.state.hud = .none
                    if !self.isMinimalMode {
                        self.state.isExpanded = false
                    }
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

    // MARK: - Audio Timer Control (Performance Optimization)

    private func startAudioTimer() {
        guard audioTimerCancellable == nil else { return }
        audioTimerCancellable = audioTimerPublisher
            .sink { [self] _ in
                animateAudioLevels()
            }
    }

    private func stopAudioTimer() {
        audioTimerCancellable?.cancel()
        audioTimerCancellable = nil
    }
}

// MARK: - Minimal HUD Views

struct MinimalVolumeHUD: View {
    let level: CGFloat
    let muted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: muted ? "speaker.slash.fill" : volumeIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(muted ? .gray : .white)

            // Mini progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(2, geo.size.width * (muted ? 0 : level)))
                }
            }
            .frame(width: 30, height: 3)
        }
    }

    private var volumeIcon: String {
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct MinimalBrightnessHUD: View {
    let level: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level > 0.5 ? "sun.max.fill" : "sun.min.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.yellow)

            // Mini progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.yellow.opacity(0.2))
                    Capsule()
                        .fill(Color.yellow)
                        .frame(width: max(2, geo.size.width * level))
                }
            }
            .frame(width: 30, height: 3)
        }
    }
}

// MARK: - Progress Bar Style HUD Views (Default)

struct ProgressBarVolumeHUD: View {
    let level: CGFloat
    let muted: Bool

    private var displayLevel: CGFloat { muted ? 0 : level }

    private var barColor: Color {
        let colorName = UserDefaults.standard.string(forKey: "volumeHUDColor") ?? "white"
        switch colorName {
        case "blue": return .blue
        case "green": return .green
        case "rainbow": return .purple
        default: return .white
        }
    }

    private var showPercent: Bool {
        UserDefaults.standard.object(forKey: "volumeShowPercent") as? Bool ?? true
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: muted ? "speaker.slash.fill" : volumeIcon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(barColor)
                .shadow(color: barColor.opacity(0.4), radius: 4)
                .frame(width: 28)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor.opacity(0.15))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.8), barColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * displayLevel))
                        .shadow(color: barColor.opacity(0.5), radius: 4)
                }
            }
            .frame(height: 8)

            if showPercent {
                Text("\(Int(displayLevel * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(barColor)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .frame(height: 36)
        .animation(.spring(duration: 0.2), value: displayLevel)
    }

    private var volumeIcon: String {
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct ProgressBarBrightnessHUD: View {
    let level: CGFloat

    private var barColor: Color {
        let colorName = UserDefaults.standard.string(forKey: "brightnessHUDColor") ?? "yellow"
        switch colorName {
        case "orange": return .orange
        case "white": return .white
        case "rainbow": return .pink
        default: return .yellow
        }
    }

    private var showPercent: Bool {
        UserDefaults.standard.object(forKey: "brightnessShowPercent") as? Bool ?? true
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: level > 0.5 ? "sun.max.fill" : "sun.min.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(barColor)
                .shadow(color: barColor.opacity(0.5), radius: 6)
                .frame(width: 28)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor.opacity(0.15))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.7), barColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * level))
                        .shadow(color: barColor.opacity(0.5), radius: 4)
                }
            }
            .frame(height: 8)

            if showPercent {
                Text("\(Int(level * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(barColor)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .frame(height: 36)
        .animation(.spring(duration: 0.2), value: level)
    }
}

// MARK: - Notched Style HUD Views

struct NotchedVolumeHUD: View {
    let level: CGFloat
    let muted: Bool
    @State private var animate = false

    private var displayLevel: CGFloat { muted ? 0 : level }

    var body: some View {
        HStack(spacing: 16) {
            // Left notch cutout style icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 44, height: 44)

                Image(systemName: muted ? "speaker.slash.fill" : volumeIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .scaleEffect(animate ? 1.1 : 1.0)
            }

            // Segmented volume bars
            HStack(spacing: 3) {
                ForEach(0..<10, id: \.self) { i in
                    let threshold = CGFloat(i) / 10.0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(displayLevel > threshold ? Color.white : Color.white.opacity(0.15))
                        .frame(width: 6, height: 20 + CGFloat(i) * 1.5)
                }
            }

            Spacer()

            Text("\(Int(displayLevel * 100))%")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2)) {
                animate = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation { animate = false }
            }
        }
    }

    private var volumeIcon: String {
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct NotchedBrightnessHUD: View {
    let level: CGFloat
    @State private var animate = false

    var body: some View {
        HStack(spacing: 16) {
            // Sun icon with glow
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.yellow.opacity(0.3), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 25
                        )
                    )
                    .frame(width: 50, height: 50)
                    .scaleEffect(animate ? 1.2 : 1.0)

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.yellow)
            }

            // Gradient brightness bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background with gradient hint
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [.black, .gray.opacity(0.3)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    // Fill
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [.orange, .yellow, .white],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * level))
                        .shadow(color: .yellow.opacity(0.5), radius: 8)
                }
            }
            .frame(height: 12)

            Text("\(Int(level * 100))%")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.yellow)
                .monospacedDigit()
                .frame(width: 50)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                animate = true
            }
        }
    }
}

// MARK: - Lock Icon View (Pulsing) - Larger for visibility

struct LockIconView: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Glow background
            Circle()
                .fill(Color.orange.opacity(0.25))
                .frame(width: 24, height: 24)
                .scaleEffect(isPulsing ? 1.6 : 1.0)
                .opacity(isPulsing ? 0.0 : 0.7)

            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
                .shadow(color: .orange.opacity(0.9), radius: isPulsing ? 8 : 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Lock Pulsing Dot (Right side) - Larger for visibility

struct LockPulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Outer ring pulse
            Circle()
                .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                .frame(width: 18, height: 18)
                .scaleEffect(isPulsing ? 1.6 : 1.0)
                .opacity(isPulsing ? 0.0 : 0.9)

            // Inner dot
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: .orange, radius: 4)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Charging Indicator (Collapsed)

struct ChargingIndicator: View {
    let level: Int
    @State private var isAnimating = false

    private var batteryColor: Color {
        if level <= 20 { return .red }
        if level <= 50 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 4) {
            // Battery icon with level
            ZStack(alignment: .leading) {
                // Battery outline
                RoundedRectangle(cornerRadius: 2)
                    .stroke(batteryColor, lineWidth: 1)
                    .frame(width: 20, height: 10)

                // Battery fill
                RoundedRectangle(cornerRadius: 1)
                    .fill(batteryColor)
                    .frame(width: max(2, 18 * CGFloat(level) / 100), height: 8)
                    .padding(.leading, 1)

                // Battery tip
                RoundedRectangle(cornerRadius: 1)
                    .fill(batteryColor)
                    .frame(width: 2, height: 5)
                    .offset(x: 20)
            }

            // Bolt icon
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.green)
                .opacity(isAnimating ? 1.0 : 0.4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Battery Percentage View

struct BatteryPercentageView: View {
    let level: Int
    let isCharging: Bool
    @State private var boltAnimation = false

    private var batteryColor: Color {
        if level <= 20 { return .red }
        if level <= 50 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("\(level)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(batteryColor)
                .monospacedDigit()

            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .opacity(boltAnimation ? 1.0 : 0.5)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            boltAnimation = true
                        }
                    }
            }
        }
    }
}

// MARK: - Battery Bar View (for expanded)

struct BatteryBarView: View {
    let level: Int
    let isCharging: Bool
    @State private var animatedLevel: CGFloat = 0
    @State private var pulseAnimation = false

    private var batteryColor: Color {
        if level <= 20 { return .red }
        if level <= 50 { return .orange }
        return .green
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Background
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.1))
                .frame(width: 50, height: 20)

            // Fill
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    LinearGradient(
                        colors: isCharging ? [batteryColor.opacity(0.7), batteryColor] : [batteryColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(4, 48 * animatedLevel / 100), height: 18)
                .padding(.leading, 1)
                .shadow(color: batteryColor.opacity(isCharging ? 0.6 : 0.3), radius: isCharging && pulseAnimation ? 6 : 2)

            // Battery tip
            RoundedRectangle(cornerRadius: 1)
                .fill(batteryColor.opacity(0.6))
                .frame(width: 3, height: 10)
                .offset(x: 51)

            // Charging bolt overlay
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .offset(x: 20)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6)) {
                animatedLevel = CGFloat(level)
            }
            if isCharging {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            }
        }
    }
}

// MARK: - Calendar Widget View

struct CalendarWidgetView: View {
    private let calendar = Calendar.current
    @State private var currentTime = Date()
    @State private var timerCancellable: AnyCancellable?

    // Timer publisher - only subscribed when view is visible
    private var timerPublisher: AnyPublisher<Date, Never> {
        Timer.publish(every: 1, on: .main, in: .common).autoconnect().eraseToAnyPublisher()
    }

    private var currentDay: Int {
        calendar.component(.day, from: currentTime)
    }

    private var currentWeekday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: currentTime).uppercased()
    }

    private var currentMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: currentTime).uppercased()
    }

    private var currentYear: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: currentTime)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: currentTime)
    }

    private var secondsString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ss"
        return formatter.string(from: currentTime)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: Date block with gradient accent
            HStack(spacing: 12) {
                // Day number with accent
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.4, blue: 0.2),
                                    Color(red: 1.0, green: 0.2, blue: 0.4)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Text("\(currentDay)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                // Month and weekday
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentWeekday)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))

                    Text("\(currentMonth) \(currentYear)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            // Center: Minimal week indicator dots
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    let dayOfWeek = calendar.component(.weekday, from: currentTime)
                    let adjustedIndex = (index + 2) % 7 // Start from Monday
                    let isToday = (dayOfWeek - 1) == adjustedIndex || (dayOfWeek == 1 && index == 6)

                    Circle()
                        .fill(isToday ?
                            AnyShapeStyle(LinearGradient(
                                colors: [Color(red: 1.0, green: 0.4, blue: 0.2), Color(red: 1.0, green: 0.2, blue: 0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            )) :
                            AnyShapeStyle(Color.white.opacity(index < dayOfWeek - 1 || (dayOfWeek == 1 && index < 6) ? 0.4 : 0.15))
                        )
                        .frame(width: isToday ? 8 : 5, height: isToday ? 8 : 5)
                        .animation(.spring(response: 0.3), value: isToday)
                }
            }

            Spacer()

            // Right: Live clock
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(timeString)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                Text(secondsString)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .monospacedDigit()
                    .offset(y: -1)
            }
        }
        .padding(.horizontal, 8)
        .onAppear {
            // Start timer when view appears
            currentTime = Date()
            timerCancellable = timerPublisher.sink { time in
                currentTime = time
            }
        }
        .onDisappear {
            // Stop timer when view disappears to save resources
            timerCancellable?.cancel()
            timerCancellable = nil
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
        window.title = "NotchMac Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 750, height: 550))
        window.minSize = NSSize(width: 650, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.titlebarAppearsTransparent = false

        self.window = window
    }
}

// MARK: - Settings View with Sidebar

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case appearance = "Appearance"
        case volume = "Volume"
        case brightness = "Brightness"
        case battery = "Battery"
        case music = "Music"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .appearance: return "paintpalette.fill"
            case .volume: return "speaker.wave.3.fill"
            case .brightness: return "sun.max.fill"
            case .battery: return "battery.100.bolt"
            case .music: return "music.note"
            case .about: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .general: return .gray
            case .appearance: return .indigo
            case .volume: return .blue
            case .brightness: return .orange
            case .battery: return .green
            case .music: return .pink
            case .about: return .purple
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(.purple)
                    Text("NotchMac")
                        .font(.system(size: 16, weight: .bold))
                }
                .padding(.vertical, 16)

                Divider()

                List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(tab.color.opacity(0.15))
                                .frame(width: 32, height: 32)

                            Image(systemName: tab.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(tab.color)
                        }

                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                case .appearance:
                    AppearanceSettingsView()
                case .volume:
                    VolumeSettingsView()
                case .brightness:
                    BrightnessSettingsView()
                case .battery:
                    BatterySettingsView()
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

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @AppStorage("hudDisplayMode") private var hudDisplayMode = "progressBar"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeader(
                    title: "Appearance",
                    subtitle: "Customize how HUDs look",
                    icon: "paintpalette.fill",
                    color: .indigo
                )

                // HUD Display Mode
                SettingsSection(title: "HUD Display Mode") {
                    VStack(spacing: 0) {
                        ForEach(["minimal", "progressBar", "notched"], id: \.self) { mode in
                            HUDModeRow(
                                mode: mode,
                                isSelected: hudDisplayMode == mode,
                                onSelect: { hudDisplayMode = mode }
                            )

                            if mode != "notched" {
                                Divider().padding(.horizontal)
                            }
                        }
                    }
                }

                // Preview
                SettingsSection(title: "Preview") {
                    VStack(spacing: 16) {
                        // Volume Preview
                        HStack {
                            Text("Volume")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        switch hudDisplayMode {
                        case "minimal":
                            HStack {
                                MinimalVolumeHUD(level: 0.65, muted: false)
                                Spacer()
                                Text("65%")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding()
                            .background(Color.black)
                            .cornerRadius(12)

                        case "notched":
                            NotchedVolumeHUD(level: 0.65, muted: false)
                                .padding()
                                .background(Color.black)
                                .cornerRadius(12)

                        default:
                            ProgressBarVolumeHUD(level: 0.65, muted: false)
                                .padding()
                                .background(Color.black)
                                .cornerRadius(12)
                        }
                    }
                    .padding()
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

struct HUDModeRow: View {
    let mode: String
    let isSelected: Bool
    let onSelect: () -> Void

    var title: String {
        switch mode {
        case "minimal": return "Minimal"
        case "progressBar": return "Progress Bar"
        case "notched": return "Notched"
        default: return mode
        }
    }

    var description: String {
        switch mode {
        case "minimal": return "Compact inline display, no expansion"
        case "progressBar": return "Classic style with progress bar"
        case "notched": return "Premium segmented design"
        default: return ""
        }
    }

    var icon: String {
        switch mode {
        case "minimal": return "minus.rectangle"
        case "progressBar": return "slider.horizontal.3"
        case "notched": return "rectangle.split.3x1"
        default: return "square"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isSelected ? .blue : .secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage("showHapticFeedback") private var showHapticFeedback = true
    @AppStorage("autoCollapseDelay") private var autoCollapseDelay = 4.0
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("hideFromDock") private var hideFromDock = false
    @AppStorage("unlockSoundEnabled") private var unlockSoundEnabled = true
    @AppStorage("showLockIndicator") private var showLockIndicator = true

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

                // Lock Screen Section
                SettingsSection(title: "Lock Screen") {
                    SettingsToggleRow(
                        title: "Lock Indicator",
                        subtitle: "Show lock icon when screen is locked",
                        icon: "lock.fill",
                        color: .orange,
                        isOn: $showLockIndicator
                    )

                    Divider().padding(.horizontal)

                    SettingsToggleRow(
                        title: "Unlock Sound",
                        subtitle: "Play sound when screen unlocks",
                        icon: "speaker.wave.2.fill",
                        color: .green,
                        isOn: $unlockSoundEnabled
                    )
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
    @AppStorage("volumeShowPercent") private var volumeShowPercent = true
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

                        Divider().padding(.horizontal)

                        SettingsToggleRow(
                            title: "Show Percentage",
                            subtitle: "Display volume level as %",
                            icon: "percent",
                            color: .cyan,
                            isOn: $volumeShowPercent
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
    @AppStorage("brightnessShowPercent") private var brightnessShowPercent = true
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

                        Divider().padding(.horizontal)

                        SettingsToggleRow(
                            title: "Show Percentage",
                            subtitle: "Display brightness level as %",
                            icon: "percent",
                            color: .cyan,
                            isOn: $brightnessShowPercent
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

// MARK: - Battery Settings

struct BatterySettingsView: View {
    @AppStorage("showBatteryIndicator") private var showBatteryIndicator = true
    @AppStorage("chargingSoundEnabled") private var chargingSoundEnabled = true
    @AppStorage("showChargingAnimation") private var showChargingAnimation = true
    @AppStorage("lowBatteryWarning") private var lowBatteryWarning = true
    @AppStorage("lowBatteryThreshold") private var lowBatteryThreshold = 20.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "Battery & Power", subtitle: "Charging notifications", icon: "battery.100.bolt", color: .green)

                SettingsSection(title: "General") {
                    SettingsToggleRow(
                        title: "Battery Indicator",
                        subtitle: "Show battery status in notch",
                        icon: "battery.75",
                        color: .green,
                        isOn: $showBatteryIndicator
                    )
                }

                if showBatteryIndicator {
                    SettingsSection(title: "Charging") {
                        SettingsToggleRow(
                            title: "Charging Animation",
                            subtitle: "Show animation when plugged in",
                            icon: "bolt.fill",
                            color: .yellow,
                            isOn: $showChargingAnimation
                        )

                        Divider().padding(.horizontal)

                        SettingsToggleRow(
                            title: "Charging Sound",
                            subtitle: "Play sound on plug/unplug",
                            icon: "speaker.wave.2.fill",
                            color: .blue,
                            isOn: $chargingSoundEnabled
                        )
                    }

                    SettingsSection(title: "Low Battery") {
                        SettingsToggleRow(
                            title: "Low Battery Warning",
                            subtitle: "Alert when battery is low",
                            icon: "battery.25",
                            color: .red,
                            isOn: $lowBatteryWarning
                        )

                        if lowBatteryWarning {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "percent")
                                        .foregroundStyle(.orange)
                                    Text("Warning Threshold")
                                    Spacer()
                                    Text("\(Int(lowBatteryThreshold))%")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                                .padding(.top, 12)

                                Slider(value: $lowBatteryThreshold, in: 10...50, step: 5)
                                    .padding(.horizontal)
                                    .padding(.bottom, 12)
                            }
                        }
                    }

                    // Preview
                    SettingsSection(title: "Preview") {
                        BatteryPreview()
                            .padding()
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

struct BatteryPreview: View {
    @State private var previewLevel: CGFloat = 75
    @State private var isCharging = true

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                // Battery icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 50, height: 50)

                    Image(systemName: isCharging ? "bolt.fill" : "battery.75")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isCharging ? "Charging" : "On Battery")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("\(Int(previewLevel))%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }

                Spacer()

                BatteryBarView(level: Int(previewLevel), isCharging: isCharging)
            }
            .padding()
            .background(Color.black)
            .cornerRadius(12)

            // Controls
            HStack {
                Toggle("Charging", isOn: $isCharging)
                    .toggleStyle(.switch)

                Spacer()

                Slider(value: $previewLevel, in: 0...100, step: 5)
                    .frame(width: 120)
            }
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
                SettingsHeader(title: "Music Activity", subtitle: "Now playing settings", icon: "music.note", color: .pink)

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
    @AppStorage("volumeShowPercent") private var showPercent = true
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

            if showPercent {
                Text("\(Int(level * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(barColor)
                    .frame(width: 40)
            }
        }
        .padding()
        .background(Color.black)
        .cornerRadius(12)
    }
}

struct BrightnessPreview: View {
    let style: String
    let color: String
    @AppStorage("brightnessShowPercent") private var showPercent = true
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

            if showPercent {
                Text("\(Int(level * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(barColor)
                    .frame(width: 40)
            }
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

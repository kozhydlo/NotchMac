import Combine
import IOKit.ps
import ServiceManagement
import SwiftUI

struct NotchContentView: View {
    @ObservedObject var state: NotchState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                NotchView(state: state)
                    .contextMenu {
                        Button("Settings...") { SettingsWindowController.shared.showSettings() }
                        Divider()
                        Button("Quit") { NSApp.terminate(nil) }
                    }
                Spacer()
            }
            Spacer()
        }
        .preferredColorScheme(.dark)
    }
}

struct NotchView: View {
    @ObservedObject var state: NotchState

    @State private var hoverTimer: Timer?
    @State private var collapseTimer: Timer?
    @State private var audioLevels: [CGFloat] = [0.3, 0.5, 0.7, 0.4, 0.6]
    @State private var audioTimerCancellable: AnyCancellable?

    @AppStorage("hudDisplayMode") private var hudDisplayMode = "progressBar"
    @AppStorage("showLockIndicator") private var showLockIndicator = true
    @AppStorage("showBatteryIndicator") private var showBatteryIndicator = true
    @AppStorage("showHapticFeedback") private var hapticFeedbackEnabled = true

    private var audioTimerPublisher: AnyPublisher<Date, Never> {
        Timer.publish(every: 0.15, on: .main, in: .common).autoconnect().eraseToAnyPublisher()
    }

    private var isMinimalMode: Bool { hudDisplayMode == "minimal" }

    private var notchSize: CGSize {
        let shouldExpand = !isMinimalMode || state.hud == .none
        var baseExtra: CGFloat = 16
        if state.isExpanded && shouldExpand { baseExtra = 100 }
        else if state.hud != .none && isMinimalMode { baseExtra = 100 }

        var stateExtraWidth: CGFloat = 0
        if state.isScreenLocked { stateExtraWidth = 140 }
        else if state.battery.isCharging || state.showChargingAnimation { stateExtraWidth = 80 }

        var expandedHeight: CGFloat = 0
        if state.isExpanded && shouldExpand { expandedHeight = 75 }

        return CGSize(width: state.notchWidth + baseExtra + stateExtraWidth, height: state.notchHeight + expandedHeight)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: 8, bottomRadius: state.isExpanded ? 20 : 12).fill(.black)

            VStack(spacing: 0) {
                collapsedContent.frame(height: state.notchHeight)

                if state.isExpanded {
                    expandedContent
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .top)).combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                        ))
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
        .onChange(of: state.activity) { newActivity in
            if case .music = newActivity { startAudioTimer() } else { stopAudioTimer() }
        }
        .onAppear { if case .music = state.activity { startAudioTimer() } }
        .onDisappear { stopAudioTimer() }
        .onChange(of: state.hud) { newValue in if newValue != .none { showHUD() } }
        .onChange(of: state.showUnlockAnimation) { newValue in
            if newValue {
                withAnimation(.spring(duration: 0.5, bounce: 0.35)) { state.isExpanded = true }
                unlockScale = 0.5
                unlockOpacity = 0
                scheduleCollapse(delay: 2.0)
            }
        }
        .onChange(of: state.isScreenLocked) { isLocked in
            if isLocked {
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                    state.isExpanded = true
                    scheduleCollapse(delay: 1.5)
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: state.isScreenLocked)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: state.showUnlockAnimation)
    }

    @ViewBuilder
    private var collapsedContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if isMinimalMode, case .volume(let level, let muted) = state.hud {
                    Image(systemName: muted ? "speaker.slash.fill" : volumeIcon(for: level))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(muted ? .gray : .white)
                } else if isMinimalMode, case .brightness(let level) = state.hud {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.yellow)
                } else {
                    leftIndicator
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 14)

            Color.clear.frame(width: state.notchWidth - 16)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if isMinimalMode, case .volume(let level, let muted) = state.hud {
                    Text(muted ? "Mute" : "\(Int(level * 100))%")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(muted ? .gray : .white)
                        .monospacedDigit()
                } else if isMinimalMode, case .brightness(let level) = state.hud {
                    Text("\(Int(level * 100))%")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.yellow)
                        .monospacedDigit()
                } else {
                    rightIndicator
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 14)
        }
    }

    private func volumeIcon(for level: CGFloat) -> String {
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    @ViewBuilder
    private var leftIndicator: some View {
        if state.isScreenLocked && showLockIndicator {
            LockIconView()
        } else if state.showUnlockAnimation && showLockIndicator {
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

    @ViewBuilder
    private var rightIndicator: some View {
        if state.isScreenLocked && showLockIndicator {
            LockPulsingDot()
        } else if state.showUnlockAnimation && showLockIndicator {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        } else if state.showChargingAnimation && showBatteryIndicator {
            ChargingIndicator(level: state.battery.level)
        } else if state.showUnplugAnimation && showBatteryIndicator {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.gray)
                .transition(.scale.combined(with: .opacity))
        } else if state.battery.isCharging && showBatteryIndicator {
            ChargingIndicator(level: state.battery.level)
        } else if case .music = state.activity {
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
                    Capsule().fill(Color.orange.opacity(0.3)).frame(width: 28, height: 4)
                    Capsule().fill(Color.orange).frame(width: 28 * CGFloat(remaining / max(total, 1)), height: 4)
                }
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 8) {
            switch state.hud {
            case .volume(let level, let muted): volumeHUD(level: level, muted: muted)
            case .brightness(let level): brightnessHUD(level: level)
            case .none:
                if state.showChargingAnimation && showBatteryIndicator { chargingExpanded }
                else if state.showUnplugAnimation && showBatteryIndicator { unplugExpanded }
                else if state.showUnlockAnimation && showLockIndicator { unlockExpanded }
                else if state.isScreenLocked && showLockIndicator { lockedExpanded }
                else {
                    switch state.activity {
                    case .music(let app): musicExpanded(app: app)
                    case .timer(let remaining, _): timerExpanded(remaining: remaining)
                    case .none: defaultExpanded
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func volumeHUD(level: CGFloat, muted: Bool) -> some View {
        if hudDisplayMode == "notched" { NotchedVolumeHUD(level: level, muted: muted) }
        else { ProgressBarVolumeHUD(level: level, muted: muted) }
    }

    @ViewBuilder
    private func brightnessHUD(level: CGFloat) -> some View {
        if hudDisplayMode == "notched" { NotchedBrightnessHUD(level: level) }
        else { ProgressBarBrightnessHUD(level: level) }
    }

    @State private var lockPulse = false

    private var lockedExpanded: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.2)).frame(width: 44, height: 44)
                    .scaleEffect(lockPulse ? 1.2 : 1.0).opacity(lockPulse ? 0.5 : 0.8)
                Image(systemName: "lock.fill").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.orange).shadow(color: .orange.opacity(0.5), radius: 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Locked").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Touch ID or enter password").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Circle().fill(Color.orange).frame(width: 8, height: 8).shadow(color: .orange, radius: 4).scaleEffect(lockPulse ? 1.3 : 1.0)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { lockPulse = true } }
        .onDisappear { lockPulse = false }
    }

    @State private var unlockScale: CGFloat = 0.5
    @State private var unlockOpacity: CGFloat = 0

    private var unlockExpanded: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(RadialGradient(colors: [.green.opacity(0.3), .green.opacity(0.1), .clear], center: .center, startRadius: 0, endRadius: 30))
                    .frame(width: 50, height: 50).scaleEffect(unlockScale).opacity(unlockOpacity)
                Image(systemName: "lock.open.fill").font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.green).shadow(color: .green.opacity(0.5), radius: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Unlocked").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                Text("Welcome back!").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green).scaleEffect(unlockScale)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.5)) { unlockScale = 1.2; unlockOpacity = 1 }
            withAnimation(.spring(duration: 0.3, bounce: 0.2).delay(0.3)) { unlockScale = 1.0 }
        }
    }

    @State private var chargingBoltScale: CGFloat = 0.5
    @State private var chargingGlow = false

    private var chargingExpanded: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(RadialGradient(colors: [.green.opacity(0.4), .green.opacity(0.1), .clear], center: .center, startRadius: 0, endRadius: 35))
                    .frame(width: 60, height: 60).scaleEffect(chargingGlow ? 1.3 : 1.0).opacity(chargingGlow ? 0.5 : 0.8)
                Image(systemName: "bolt.fill").font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.green).shadow(color: .green.opacity(0.7), radius: 10).scaleEffect(chargingBoltScale)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Charging").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text("\(state.battery.level)%").font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.green).monospacedDigit()
                    BatteryBarView(level: state.battery.level, isCharging: true)
                }
            }
            Spacer()
        }
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.4)) { chargingBoltScale = 1.2 }
            withAnimation(.spring(duration: 0.3).delay(0.2)) { chargingBoltScale = 1.0 }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { chargingGlow = true }
        }
        .onDisappear { chargingBoltScale = 0.5; chargingGlow = false }
    }

    @State private var unplugScale: CGFloat = 1.2

    private var unplugExpanded: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.gray.opacity(0.2)).frame(width: 50, height: 50)
                Image(systemName: "powerplug.fill").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.gray).scaleEffect(unplugScale)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Unplugged").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text("\(state.battery.level)%").font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(state.battery.level <= 20 ? .red : .white.opacity(0.7)).monospacedDigit()
                    if let time = state.battery.timeRemaining, time > 0 {
                        Text("• \(formatBatteryTime(time)) remaining").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            Spacer()
            BatteryBarView(level: state.battery.level, isCharging: false)
        }
        .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.3)) { unplugScale = 1.0 } }
        .onDisappear { unplugScale = 1.2 }
    }

    private func formatBatteryTime(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
    }

    private func handleTap() {
        hoverTimer?.invalidate()
        collapseTimer?.invalidate()
        if hapticFeedbackEnabled { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        withAnimation(.spring(duration: 0.5, bounce: 0.35)) {
            if state.isExpanded { state.hud = .none; state.isExpanded = false }
            else { state.isExpanded = true; scheduleCollapse(delay: 4) }
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTimer?.invalidate()
        collapseTimer?.invalidate()
        if hovering && hapticFeedbackEnabled { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        withAnimation(.spring(duration: 0.25, bounce: 0.4)) { state.isHovered = hovering }

        if hovering {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                guard UserDefaults.standard.object(forKey: "expandOnHover") as? Bool ?? true else { return }
                withAnimation(.spring(duration: 0.5, bounce: 0.35)) { self.state.isExpanded = true }
                if self.hapticFeedbackEnabled { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            }
        } else {
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                state.isExpanded = false
                state.hud = .none
            }
        }
    }

    private func scheduleCollapse(delay: TimeInterval) {
        collapseTimer?.invalidate()
        let collapseDelay = UserDefaults.standard.object(forKey: "autoCollapseDelay") as? Double ?? 4.0
        guard collapseDelay > 0 else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: collapseDelay, repeats: false) { _ in
            if !self.state.isHovered {
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                    self.state.isExpanded = false
                    self.state.hud = .none
                }
            }
        }
    }

    private func showHUD() {
        collapseTimer?.invalidate()
        if !isMinimalMode {
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) { state.isExpanded = true }
        }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                if !self.state.isHovered && !self.isMinimalMode { self.state.isExpanded = false }
                self.state.hud = .none
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60
        let s = Int(interval) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func musicIcon(for app: String) -> String {
        switch app {
        case "Spotify": return "beats.headphones"
        case "Music": return "music.note"
        case "Safari", "Chrome", "Firefox", "Arc": return "play.circle.fill"
        default: return "music.note"
        }
    }

    private func musicExpanded(app: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.green.opacity(0.2)).frame(width: 44, height: 44)
                Image(systemName: musicIcon(for: app)).font(.system(size: 20, weight: .medium)).foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Now Playing").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(app).font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
            }
            Spacer()
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Color.green)
                        .frame(width: 4, height: 10 + audioLevels[i] * 20)
                }
            }
        }
    }

    private func timerExpanded(remaining: TimeInterval) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.2)).frame(width: 44, height: 44)
                Image(systemName: "timer").font(.system(size: 20, weight: .medium)).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Timer").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(formatTime(remaining)).font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange).monospacedDigit()
            }
            Spacer()
        }
    }

    private var defaultExpanded: some View { CalendarWidgetView() }

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

    private func startAudioTimer() {
        guard audioTimerCancellable == nil else { return }
        audioTimerCancellable = audioTimerPublisher.sink { [self] _ in animateAudioLevels() }
    }

    private func stopAudioTimer() {
        audioTimerCancellable?.cancel()
        audioTimerCancellable = nil
    }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: rect.height - bottomRadius))
        path.addQuadCurve(to: CGPoint(x: bottomRadius, y: rect.height), control: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - bottomRadius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height - bottomRadius), control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.closeSubpath()
        return path
    }
}

struct LockIconView: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle().fill(Color.orange.opacity(0.25)).frame(width: 24, height: 24)
                .scaleEffect(isPulsing ? 1.6 : 1.0).opacity(isPulsing ? 0.0 : 0.7)
            Image(systemName: "lock.fill").font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange).shadow(color: .orange.opacity(0.9), radius: isPulsing ? 8 : 4)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { isPulsing = true } }
    }
}

struct LockPulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.orange.opacity(0.6), lineWidth: 2).frame(width: 18, height: 18)
                .scaleEffect(isPulsing ? 1.6 : 1.0).opacity(isPulsing ? 0.0 : 0.9)
            Circle().fill(Color.orange).frame(width: 8, height: 8).shadow(color: .orange, radius: 4)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) { isPulsing = true } }
    }
}

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
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).stroke(batteryColor, lineWidth: 1).frame(width: 20, height: 10)
                RoundedRectangle(cornerRadius: 1).fill(batteryColor).frame(width: max(2, 16 * CGFloat(level) / 100), height: 6).padding(.leading, 2)
            }
            Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(batteryColor)
                .opacity(isAnimating ? 1 : 0.5).scaleEffect(isAnimating ? 1.1 : 0.9)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { isAnimating = true } }
    }
}

struct BatteryBarView: View {
    let level: Int
    let isCharging: Bool
    @State private var animatedLevel: CGFloat = 0
    @State private var pulseAnimation = false

    private var color: Color {
        if level <= 20 { return .red }
        if level <= 50 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(CGFloat(i) < animatedLevel / 10 ? color : Color.white.opacity(0.15))
                    .frame(width: 4, height: 18)
                    .scaleEffect(y: isCharging && pulseAnimation && CGFloat(i) < animatedLevel / 10 ? 1.1 : 1.0)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6)) { animatedLevel = CGFloat(level) }
            if isCharging { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulseAnimation = true } }
        }
    }
}

struct CalendarWidgetView: View {
    private let calendar = Calendar.current
    private var currentDay: Int { calendar.component(.day, from: Date()) }
    private var currentWeekday: String {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: Date()).uppercased()
    }
    private var currentMonth: String {
        let f = DateFormatter(); f.dateFormat = "MMM"
        return f.string(from: Date()).uppercased()
    }
    private var currentYear: String {
        let f = DateFormatter(); f.dateFormat = "yyyy"
        return f.string(from: Date())
    }
    private var timeString: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.4, blue: 0.2), Color(red: 1.0, green: 0.2, blue: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Text("\(currentDay)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentWeekday).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                    Text("\(currentMonth) \(currentYear)").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .fixedSize()
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    let dayOfWeek = calendar.component(.weekday, from: Date())
                    let adjustedIndex = (index + 2) % 7
                    let isToday = (dayOfWeek - 1) == adjustedIndex || (dayOfWeek == 1 && index == 6)
                    Circle()
                        .fill(isToday ?
                            AnyShapeStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.4, blue: 0.2), Color(red: 1.0, green: 0.2, blue: 0.4)], startPoint: .top, endPoint: .bottom)) :
                            AnyShapeStyle(Color.white.opacity(index < dayOfWeek - 1 || (dayOfWeek == 1 && index < 6) ? 0.4 : 0.15)))
                        .frame(width: isToday ? 8 : 5, height: isToday ? 8 : 5)
                }
            }
            Spacer()
            Text(timeString).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit().fixedSize()
        }
        .padding(.horizontal, 8)
    }
}

struct ProgressBarVolumeHUD: View {
    let level: CGFloat
    let muted: Bool
    @AppStorage("volumeShowPercent") private var showPercent = true

    private var volumeIcon: String {
        if muted { return "speaker.slash.fill" }
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: volumeIcon).font(.system(size: 18, weight: .medium)).foregroundStyle(muted ? .gray : .white).frame(width: 24)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 6)
                    Capsule().fill(muted ? Color.gray : Color.white).frame(width: max(6, geo.size.width * level), height: 6)
                }
            }
            .frame(height: 6)
            if showPercent {
                Text("\(Int(level * 100))%").font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(muted ? .gray : .white).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

struct ProgressBarBrightnessHUD: View {
    let level: CGFloat
    @AppStorage("brightnessShowPercent") private var showPercent = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill").font(.system(size: 18, weight: .medium)).foregroundStyle(.yellow).frame(width: 24)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.yellow.opacity(0.2)).frame(height: 6)
                    Capsule().fill(Color.yellow).frame(width: max(6, geo.size.width * level), height: 6)
                }
            }
            .frame(height: 6)
            if showPercent {
                Text("\(Int(level * 100))%").font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.yellow).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

struct NotchedVolumeHUD: View {
    let level: CGFloat
    let muted: Bool

    private var volumeIcon: String {
        if muted { return "speaker.slash.fill" }
        if level < 0.33 { return "speaker.wave.1.fill" }
        if level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: volumeIcon).font(.system(size: 18, weight: .medium)).foregroundStyle(muted ? .gray : .white).frame(width: 24)
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CGFloat(i) < level * 16 ? (muted ? Color.gray : Color.white) : Color.white.opacity(0.15))
                        .frame(width: 6, height: 16)
                }
            }
            Text("\(Int(level * 100))%").font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(muted ? .gray : .white).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}

struct NotchedBrightnessHUD: View {
    let level: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill").font(.system(size: 18, weight: .medium)).foregroundStyle(.yellow).frame(width: 24)
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CGFloat(i) < level * 16 ? Color.yellow : Color.yellow.opacity(0.15))
                        .frame(width: 6, height: 16)
                }
            }
            Text("\(Int(level * 100))%").font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.yellow).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func showSettings() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "NotchMac Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.minSize = NSSize(width: 600, height: 450)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

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
            case .battery: return "battery.100"
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
                HStack {
                    Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.purple)
                    Text("NotchMac").font(.system(size: 16, weight: .bold))
                }
                .padding(.vertical, 16)
                Divider()
                List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(tab.color.opacity(0.15)).frame(width: 32, height: 32)
                            Image(systemName: tab.icon).font(.system(size: 14, weight: .medium)).foregroundStyle(tab.color)
                        }
                        Text(tab.rawValue).font(.system(size: 14, weight: .medium))
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selectedTab {
                case .general: GeneralSettingsView()
                case .appearance: AppearanceSettingsView()
                case .volume: VolumeSettingsView()
                case .brightness: BrightnessSettingsView()
                case .battery: BatterySettingsView()
                case .music: MusicSettingsView()
                case .about: AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 450)
    }
}

struct SettingsHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.15)).frame(width: 56, height: 56)
                Image(systemName: icon).font(.system(size: 24, weight: .medium)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 8)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) { content }
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
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

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
                SettingsHeader(title: "General", subtitle: "Basic app settings", icon: "gearshape.fill", color: .gray)

                SettingsSection(title: "System") {
                    SettingsToggleRow(title: "Launch at Login", subtitle: "Start NotchMac when you log in", icon: "power", color: .green, isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in LaunchAtLogin.setEnabled(newValue) }
                    Divider().padding(.horizontal)
                    SettingsToggleRow(title: "Hide from Dock", subtitle: "Only show in menu bar area", icon: "dock.arrow.down.rectangle", color: .blue, isOn: $hideFromDock)
                        .onChange(of: hideFromDock) { newValue in NSApp.setActivationPolicy(newValue ? .accessory : .regular) }
                }

                SettingsSection(title: "Lock Screen") {
                    SettingsToggleRow(title: "Lock Indicator", subtitle: "Show lock icon when screen is locked", icon: "lock.fill", color: .orange, isOn: $showLockIndicator)
                    Divider().padding(.horizontal)
                    SettingsToggleRow(title: "Unlock Sound", subtitle: "Play sound when screen unlocks", icon: "speaker.wave.2.fill", color: .green, isOn: $unlockSoundEnabled)
                }

                SettingsSection(title: "Behavior") {
                    SettingsToggleRow(title: "Expand on Hover", subtitle: "Open menu when hovering over notch", icon: "cursorarrow.motionlines", color: .orange, isOn: $expandOnHover)
                    Divider().padding(.horizontal)
                    SettingsToggleRow(title: "Haptic Feedback", subtitle: "Vibration on interactions", icon: "hand.tap.fill", color: .purple, isOn: $showHapticFeedback)
                    Divider().padding(.horizontal)
                    SettingsPickerRow(title: "Auto Collapse", subtitle: "Time before menu closes", icon: "timer", color: .cyan, selection: $autoCollapseDelay, options: [(2.0, "2s"), (4.0, "4s"), (6.0, "6s"), (0.0, "Never")])
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("hudDisplayMode") private var hudDisplayMode = "progressBar"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsHeader(title: "Appearance", subtitle: "Customize how HUDs look", icon: "paintpalette.fill", color: .indigo)

                SettingsSection(title: "HUD Display Mode") {
                    VStack(spacing: 0) {
                        ForEach(["minimal", "progressBar", "notched"], id: \.self) { mode in
                            HUDModeRow(mode: mode, isSelected: hudDisplayMode == mode) { hudDisplayMode = mode }
                            if mode != "notched" { Divider().padding(.horizontal) }
                        }
                    }
                }

                SettingsSection(title: "Preview") {
                    VStack(spacing: 16) {
                        HStack { Text("Volume").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary); Spacer() }
                        Group {
                            if hudDisplayMode == "minimal" {
                                HStack {
                                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    Spacer()
                                    Text("65%").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit()
                                }
                            } else if hudDisplayMode == "notched" { NotchedVolumeHUD(level: 0.65, muted: false) }
                            else { ProgressBarVolumeHUD(level: 0.65, muted: false) }
                        }
                        .padding()
                        .background(Color.black)
                        .cornerRadius(12)
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

    private var title: String {
        switch mode {
        case "minimal": return "Minimal"
        case "progressBar": return "Progress Bar"
        case "notched": return "Notched"
        default: return mode
        }
    }

    private var description: String {
        switch mode {
        case "minimal": return "Compact inline display, no expansion"
        case "progressBar": return "Classic style with progress bar"
        case "notched": return "Premium segmented design"
        default: return ""
        }
    }

    private var icon: String {
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
                    RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1)).frame(width: 44, height: 44)
                    Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(isSelected ? .blue : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                    Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.blue) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VolumeSettingsView: View {
    @AppStorage("showVolumeHUD") private var showVolumeHUD = true
    @AppStorage("volumeShowPercent") private var volumeShowPercent = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "Volume HUD", subtitle: "Customize volume indicator", icon: "speaker.wave.3.fill", color: .blue)
                SettingsSection(title: "General") {
                    SettingsToggleRow(title: "Enable Volume HUD", subtitle: "Replace system volume overlay", icon: "speaker.wave.2.fill", color: .blue, isOn: $showVolumeHUD)
                }
                if showVolumeHUD {
                    SettingsSection(title: "Display") {
                        SettingsToggleRow(title: "Show Percentage", subtitle: "Display volume percentage", icon: "percent", color: .cyan, isOn: $volumeShowPercent)
                    }
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

struct BrightnessSettingsView: View {
    @AppStorage("showBrightnessHUD") private var showBrightnessHUD = true
    @AppStorage("brightnessShowPercent") private var brightnessShowPercent = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "Brightness HUD", subtitle: "Customize brightness indicator", icon: "sun.max.fill", color: .orange)
                SettingsSection(title: "General") {
                    SettingsToggleRow(title: "Enable Brightness HUD", subtitle: "Replace system brightness overlay", icon: "sun.max.fill", color: .orange, isOn: $showBrightnessHUD)
                }
                if showBrightnessHUD {
                    SettingsSection(title: "Display") {
                        SettingsToggleRow(title: "Show Percentage", subtitle: "Display brightness percentage", icon: "percent", color: .yellow, isOn: $brightnessShowPercent)
                    }
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

struct BatterySettingsView: View {
    @AppStorage("showBatteryIndicator") private var showBatteryIndicator = true
    @AppStorage("chargingSoundEnabled") private var chargingSoundEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "Battery", subtitle: "Charging notifications", icon: "battery.100", color: .green)
                SettingsSection(title: "Indicators") {
                    SettingsToggleRow(title: "Charging Indicator", subtitle: "Show when plugged in or unplugged", icon: "bolt.fill", color: .green, isOn: $showBatteryIndicator)
                    Divider().padding(.horizontal)
                    SettingsToggleRow(title: "Charging Sound", subtitle: "Play sound on plug/unplug", icon: "speaker.wave.2.fill", color: .blue, isOn: $chargingSoundEnabled)
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

struct MusicSettingsView: View {
    @AppStorage("showMusicActivity") private var showMusicActivity = true
    @AppStorage("showMusicVisualizer") private var showMusicVisualizer = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "Music", subtitle: "Now Playing indicator", icon: "music.note", color: .pink)
                SettingsSection(title: "Display") {
                    SettingsToggleRow(title: "Show Music Activity", subtitle: "Display when music is playing", icon: "music.note", color: .pink, isOn: $showMusicActivity)
                    Divider().padding(.horizontal)
                    SettingsToggleRow(title: "Audio Visualizer", subtitle: "Animated bars when playing", icon: "waveform", color: .green, isOn: $showMusicVisualizer)
                }
                SettingsSection(title: "Supported Apps") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(["Apple Music", "Spotify", "TIDAL", "Deezer", "Amazon Music", "Safari", "Chrome", "Firefox", "Arc"], id: \.self) { app in
                            HStack {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text(app).font(.system(size: 13))
                                Spacer()
                            }
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

struct AboutSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsHeader(title: "About", subtitle: "NotchMac v1.0", icon: "info.circle.fill", color: .purple)
                SettingsSection(title: "App Info") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Version").foregroundStyle(.secondary); Spacer(); Text("1.0.0") }
                        Divider()
                        HStack { Text("Build").foregroundStyle(.secondary); Spacer(); Text("2026.02.06") }
                        Divider()
                        HStack { Text("Developer").foregroundStyle(.secondary); Spacer(); Text("Mark Kozhydlo") }
                    }
                    .font(.system(size: 13))
                    .padding()
                }
                Spacer()
            }
            .padding(24)
        }
    }
}

enum LaunchAtLogin {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {}
    }
}

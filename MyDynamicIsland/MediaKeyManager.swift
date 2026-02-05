import AppKit
import AudioToolbox
import CoreAudio

final class MediaKeyManager {
    private let state: NotchState
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let volumeStep: Float32 = 1.0 / 16.0
    private let brightnessStep: Float = 1.0 / 16.0

    init(state: NotchState) {
        self.state = state
    }

    func start() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            NSLog("[MediaKeyManager] Accessibility permission required")
        }

        let eventMask: CGEventMask = 1 << 14
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: mediaKeyCallback,
            userInfo: userInfo
        ) else { return }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    enum KeyAction { case swallow, passThrough }

    func handleMediaKey(event: CGEvent) -> KeyAction {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else { return .passThrough }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyDown = (data1 & 0x0100) != 0

        let showVolumeHUD = UserDefaults.standard.object(forKey: "showVolumeHUD") as? Bool ?? true
        let showBrightnessHUD = UserDefaults.standard.object(forKey: "showBrightnessHUD") as? Bool ?? true

        switch keyCode {
        case 0: // Volume Up
            if showVolumeHUD {
                if keyDown { adjustVolume(delta: volumeStep) }
                return .swallow
            }
            return .passThrough
        case 1: // Volume Down
            if showVolumeHUD {
                if keyDown { adjustVolume(delta: -volumeStep) }
                return .swallow
            }
            return .passThrough
        case 7: // Mute
            if showVolumeHUD {
                if keyDown { toggleMute() }
                return .swallow
            }
            return .passThrough
        case 2: // Brightness Up
            if showBrightnessHUD {
                if keyDown { adjustBrightness(delta: brightnessStep) }
                return .swallow
            }
            return .passThrough
        case 3: // Brightness Down
            if showBrightnessHUD {
                if keyDown { adjustBrightness(delta: -brightnessStep) }
                return .swallow
            }
            return .passThrough
        default:
            return .passThrough
        }
    }

    // MARK: - Volume

    private func adjustVolume(delta: Float32) {
        let deviceID = defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }

        var volume = getVolume(device: deviceID)
        volume = max(0, min(1, volume + delta))
        setVolume(device: deviceID, value: volume)

        if delta != 0 { setMute(device: deviceID, muted: false) }

        DispatchQueue.main.async {
            self.state.hud = .volume(level: CGFloat(volume), muted: false)
        }
    }

    private func toggleMute() {
        let deviceID = defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }

        let muted = getMute(device: deviceID)
        setMute(device: deviceID, muted: !muted)
        let volume = getVolume(device: deviceID)

        DispatchQueue.main.async {
            self.state.hud = .volume(level: CGFloat(volume), muted: !muted)
        }
    }

    private func defaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func getVolume(device: AudioDeviceID) -> Float32 {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return volume
    }

    private func setVolume(device: AudioDeviceID, value: Float32) {
        var volume = value
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
    }

    private func getMute(device: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return muted != 0
    }

    private func setMute(device: AudioDeviceID, muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: - Brightness

    private func adjustBrightness(delta: Float) {
        let current = BrightnessHelper.read()
        let newValue = max(0, min(1, current + delta))
        _ = BrightnessHelper.set(newValue)

        DispatchQueue.main.async {
            self.state.hud = .brightness(level: CGFloat(newValue))
        }
    }
}

// MARK: - Brightness Helper

private enum BrightnessHelper {
    private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    )
    private static let getFunc: DSGet? = loadSym(handle, "DisplayServicesGetBrightness")
    private static let setFunc: DSSet? = loadSym(handle, "DisplayServicesSetBrightness")
    private static let display = CGMainDisplayID()

    static func read() -> Float {
        if let get = getFunc {
            var val: Float = -1
            if get(display, &val) == 0 && val >= 0 { return val }
        }
        return 0.5
    }

    static func set(_ value: Float) -> Bool {
        if let set = setFunc {
            return set(display, max(0, min(1, value))) == 0
        }
        return false
    }

    private static func loadSym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let h = handle, let sym = dlsym(h, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}

// MARK: - Event Tap Callback

private func mediaKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<MediaKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type.rawValue == 14, let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<MediaKeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    switch manager.handleMediaKey(event: event) {
    case .swallow: return nil
    case .passThrough: return Unmanaged.passUnretained(event)
    }
}

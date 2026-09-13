import Combine
import CoreAudio
import SwiftUI

/// 使用 CoreAudio 读写默认输出设备，不执行 AppleScript。
final class VolumeModule: ObservableObject, NotchModule {
    let id = "volume"
    let title = "音量"
    let systemImage = "speaker.wave.2.fill"

    @Published private(set) var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var canMute = false

    private let queue = DispatchQueue(label: "com.notchdeck.volume", qos: .utility)
    private var pollTimer: Timer?
    private var pendingWrite: DispatchWorkItem?
    private var revision = 0
    private var polling = false
    private var editing = false

    deinit { pollTimer?.invalidate() }

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        revision += 1
        pollTimer?.invalidate()
        pollTimer = nil
        pendingWrite?.cancel()
        pendingWrite = nil
        editing = false
    }

    func content() -> some View { VolumeView(module: self) }

    func setEditing(_ editing: Bool) {
        self.editing = editing
        if !editing { setVolume(volume, immediate: true) }
    }

    func setVolume(_ value: Double, immediate: Bool) {
        guard canSetVolume, value.isFinite, pollTimer != nil else { return }
        volume = min(100, max(0, value))
        revision += 1
        pendingWrite?.cancel()
        let desired = Float32(volume / 100)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                AudioOutput.setVolume(desired)
                DispatchQueue.main.async { self.poll() }
            }
        }
        pendingWrite = item
        if immediate { item.perform() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item) }
    }

    func toggleMute() {
        guard canMute, pollTimer != nil else { return }
        muted.toggle()
        revision += 1
        let desired = muted
        queue.async { [weak self] in
            AudioOutput.setMuted(desired)
            DispatchQueue.main.async { self?.poll() }
        }
    }

    private func poll() {
        guard pollTimer != nil, !polling else { return }
        polling = true
        let version = revision
        queue.async { [weak self] in
            let snapshot = AudioOutput.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                guard self.pollTimer != nil, self.revision == version, !self.editing else { return }
                self.volume = snapshot.volume
                self.muted = snapshot.muted
                self.canSetVolume = snapshot.canSetVolume
                self.canMute = snapshot.canMute
            }
        }
    }
}

private enum AudioOutput {
    struct Snapshot {
        var volume: Double = 0
        var muted = false
        var canSetVolume = false
        var canMute = false
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func device() -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func writable(_ device: AudioDeviceID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var result = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &property, &result) == noErr && result.boolValue
    }

    private static func volumeChannels(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        // 优先主音量；部分 USB/内置设备只有左右声道音量。
        for channels: [AudioObjectPropertyElement] in [[kAudioObjectPropertyElementMain], [1, 2]] {
            let available = channels.filter {
                var property = address(kAudioDevicePropertyVolumeScalar, element: $0)
                return AudioObjectHasProperty(device, &property)
            }
            if !available.isEmpty { return available }
        }
        return []
    }

    static func snapshot() -> Snapshot {
        guard let device = device() else { return Snapshot() }
        var snapshot = Snapshot()
        let channels = volumeChannels(device)
        var values: [Double] = []
        for channel in channels {
            var property = address(kAudioDevicePropertyVolumeScalar, element: channel)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr, value.isFinite {
                values.append(Double(value))
            }
        }
        if !values.isEmpty { snapshot.volume = min(100, max(0, values.reduce(0, +) / Double(values.count) * 100)) }
        snapshot.canSetVolume = !values.isEmpty && channels.allSatisfy {
            writable(device, address(kAudioDevicePropertyVolumeScalar, element: $0))
        }
        var property = address(kAudioDevicePropertyMute)
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &property, 0, nil, &size, &mute) == noErr {
            snapshot.muted = mute != 0
            snapshot.canMute = writable(device, property)
        }
        return snapshot
    }

    static func setVolume(_ value: Float32) {
        guard let device = device() else { return }
        for channel in volumeChannels(device) {
            var property = address(kAudioDevicePropertyVolumeScalar, element: channel)
            var value = value
            guard writable(device, property) else { continue }
            _ = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    static func setMuted(_ muted: Bool) {
        guard let device = device() else { return }
        var property = address(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        guard writable(device, property) else { return }
        _ = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

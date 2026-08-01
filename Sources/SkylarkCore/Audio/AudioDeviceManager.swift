import CoreAudio
import Foundation
import os

/// One input-capable audio device (phase-4 spec §4).
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    /// CoreAudio device UID — stable across reboots/replug, so it's what we
    /// persist. Serves as `Identifiable.id`.
    public let uid: String
    public let name: String
    public let transportType: UInt32
    public let deviceID: AudioDeviceID

    public var id: String { uid }

    /// HFP-mode Bluetooth mics degrade recognition quality — flagged in the UI.
    public var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    public init(uid: String, name: String, transportType: UInt32, deviceID: AudioDeviceID) {
        self.uid = uid
        self.name = name
        self.transportType = transportType
        self.deviceID = deviceID
    }
}

/// Enumerates input-capable CoreAudio devices and watches the device list for
/// hot-plug changes. `@MainActor` so its `@Observable`-style callback drives the
/// settings picker; the underlying CoreAudio reads are cheap and synchronous.
@MainActor
public final class AudioDeviceManager {
    /// Current input devices (built-in first, then the rest by name).
    public private(set) var devices: [AudioInputDevice] = []

    /// Invoked on the main actor whenever the device list changes.
    public var onChange: (() -> Void)?

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "audio-devices")
    private var listenerInstalled = false

    // Boxed callback so the C listener block (Sendable) can hop to the main actor.
    private final class ChangeBox: @unchecked Sendable {
        var handler: () -> Void = {}
    }
    private let changeBox = ChangeBox()

    public init() {
        changeBox.handler = { [weak self] in
            Task { @MainActor in self?.handleDeviceListChanged() }
        }
    }

    /// Enumerate now and begin watching for device-list changes.
    public func start() {
        refresh()
        installListener()
    }

    /// Re-read the input device list OFF the main actor: HAL property reads
    /// block indefinitely when coreaudiod is wedged, and enumeration must
    /// never take the app's main actor (menu bar, HUD, Settings) down with
    /// it. `onChange` fires on the main actor once the list lands.
    public func refresh() {
        // `Task` (not `Task.detached`) inherits this method's main-actor
        // isolation, so `self` never crosses an isolation boundary — a detached
        // task capturing `self` and hopping back via `MainActor.run` is a
        // "sending 'self' risks causing data races" error under Swift 6.2's
        // strict concurrency, which is the toolchain CLAUDE.md pins. The
        // blocking HAL reads still happen off the main actor, inside
        // `enumerateOffMainActor()`.
        Task { [weak self] in
            let found = await Self.enumerateOffMainActor()
            guard let self else { return }
            self.devices = found
            self.onChange?()
        }
    }

    /// Runs the synchronous CoreAudio enumeration on a background executor and
    /// returns its `Sendable` result. Split out so the caller can stay
    /// main-actor-isolated while the blocking part does not.
    private nonisolated static func enumerateOffMainActor() async -> [AudioInputDevice] {
        await Task.detached(priority: .userInitiated) { Self.inputDevices() }.value
    }

    private func handleDeviceListChanged() {
        refresh() // onChange fires when the async enumeration completes
    }

    private func installListener() {
        guard !listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let box = changeBox
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { _, _ in
            box.handler()
        }
        if status == noErr {
            listenerInstalled = true
        } else {
            logger.notice("failed to install device-list listener (osstatus \(status, privacy: .public))")
        }
    }

    // MARK: - Enumeration (static, usable off the main actor)

    /// All input-capable devices, ordered built-in-first then alphabetical.
    public nonisolated static func inputDevices() -> [AudioInputDevice] {
        var devices: [AudioInputDevice] = []
        for id in allDeviceIDs() {
            guard hasInputStreams(id) else { continue }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { continue }
            let transport = transportType(id)
            devices.append(AudioInputDevice(uid: uid, name: name, transportType: transport, deviceID: id))
        }
        return devices.sorted { lhs, rhs in
            let lBuiltIn = lhs.transportType == kAudioDeviceTransportTypeBuiltIn
            let rBuiltIn = rhs.transportType == kAudioDeviceTransportTypeBuiltIn
            if lBuiltIn != rBuiltIn { return lBuiltIn }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Resolve a persisted UID to a live device ID, or nil if it's gone.
    public nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in allDeviceIDs() where stringProperty(id, kAudioDevicePropertyDeviceUID) == uid {
            return id
        }
        return nil
    }

    // MARK: - CoreAudio helpers

    private nonisolated static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, buffer.baseAddress!
            )
        }
        return status == noErr ? ids : []
    }

    private nonisolated static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }
        let listPtr = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        for buffer in listPtr where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private nonisolated static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &transport)
        return transport
    }

    private nonisolated static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(dataSize)) { raw in
                AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, raw)
            }
        }
        guard status == noErr, let cfString else { return nil }
        return cfString as String
    }
}

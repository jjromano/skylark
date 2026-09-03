import CoreAudio
import Testing

import SkylarkCore

/// D1: a mic that disappears must say so once, come back on its own, and never
/// nag on the device-list churn in between.
@Suite("SelectedDeviceReconciler")
struct SelectedDeviceReconcilerTests {
    private static func device(_ uid: String, _ name: String, id: AudioDeviceID = 1) -> AudioInputDevice {
        AudioInputDevice(uid: uid, name: name, transportType: kAudioDeviceTransportTypeUSB, deviceID: id)
    }

    private static let mic = device("uid-mic", "Yeti")
    private static let builtIn = device("uid-builtin", "MacBook Air Microphone", id: 2)

    @Test("Present at launch: adopt silently")
    func presentAtLaunch() {
        let action = SelectedDeviceReconciler.reconcile(
            previouslyAvailable: nil,
            selectedUID: "uid-mic",
            devices: [Self.builtIn, Self.mic]
        )
        #expect(action == .adopted(name: "Yeti"))
    }

    @Test("Absent at launch: one fallback note")
    func absentAtLaunch() {
        let action = SelectedDeviceReconciler.reconcile(
            previouslyAvailable: nil,
            selectedUID: "uid-mic",
            devices: [Self.builtIn]
        )
        #expect(action == .fellBackToDefault)
    }

    @Test("Present then absent: fall back and say so")
    func presentThenAbsent() {
        let action = SelectedDeviceReconciler.reconcile(
            previouslyAvailable: true,
            selectedUID: "uid-mic",
            devices: [Self.builtIn]
        )
        #expect(action == .fellBackToDefault)
    }

    @Test("Absent then present: re-adopt and say so")
    func absentThenPresent() {
        let action = SelectedDeviceReconciler.reconcile(
            previouslyAvailable: false,
            selectedUID: "uid-mic",
            devices: [Self.builtIn, Self.mic]
        )
        #expect(action == .readopted(name: "Yeti"))
    }

    @Test("Re-adoption keys on UID, not the AudioDeviceID a replug changes")
    func replugChangesDeviceID() {
        let replugged = Self.device("uid-mic", "Yeti", id: 77)
        let action = SelectedDeviceReconciler.reconcile(
            previouslyAvailable: false,
            selectedUID: "uid-mic",
            devices: [replugged]
        )
        #expect(action == .readopted(name: "Yeti"))
    }

    @Test("Repeated absent list changes never repeat the note")
    func repeatedAbsence() {
        var previous: Bool?
        var notes = 0
        for _ in 0..<5 {
            let action = SelectedDeviceReconciler.reconcile(
                previouslyAvailable: previous,
                selectedUID: "uid-mic",
                devices: [Self.builtIn]
            )
            if action == .fellBackToDefault { notes += 1 }
            previous = false
        }
        #expect(notes == 1)
    }

    @Test("Steady presence never notes")
    func repeatedPresence() {
        var previous: Bool?
        for _ in 0..<5 {
            let action = SelectedDeviceReconciler.reconcile(
                previouslyAvailable: previous,
                selectedUID: "uid-mic",
                devices: [Self.builtIn, Self.mic]
            )
            #expect(action == .adopted(name: "Yeti"))
            previous = true
        }
    }

    @Test("Nil or empty selection never notes, whatever the list does")
    func nilSelection() {
        for previous: Bool? in [nil, true, false] {
            #expect(SelectedDeviceReconciler.reconcile(
                previouslyAvailable: previous, selectedUID: nil, devices: []
            ) == .noSelection)
            #expect(SelectedDeviceReconciler.reconcile(
                previouslyAvailable: previous, selectedUID: "", devices: [Self.builtIn]
            ) == .noSelection)
        }
    }

    @Test("Unplug/replug cycle: exactly one note each way")
    func fullCycle() {
        var previous: Bool?
        var notes: [String] = []
        let lists: [[AudioInputDevice]] = [
            [Self.builtIn, Self.mic],   // launch: present
            [Self.builtIn],             // unplugged
            [Self.builtIn],             // churn
            [Self.builtIn, Self.mic],   // back
            [Self.builtIn, Self.mic],   // churn
        ]
        for devices in lists {
            let action = SelectedDeviceReconciler.reconcile(
                previouslyAvailable: previous,
                selectedUID: "uid-mic",
                devices: devices
            )
            switch action {
            case .fellBackToDefault:
                notes.append(SelectedDeviceReconciler.unavailableNote)
                previous = false
            case let .readopted(name):
                notes.append(SelectedDeviceReconciler.readoptedNote(name: name))
                previous = true
            case .adopted:
                previous = true
            case .stillAbsent:
                previous = false
            case .noSelection:
                previous = nil
            }
        }
        #expect(notes == [
            "Selected mic unavailable — using the system default",
            "Selected mic is back — using Yeti",
        ])
    }
}

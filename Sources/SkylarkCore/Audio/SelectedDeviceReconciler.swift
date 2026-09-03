import Foundation

/// Decides what to do when the CoreAudio input-device list changes while the
/// user has a specific microphone selected.
///
/// The device-list listener fires often (every plug, unplug, sample-rate change
/// and aggregate-device edit), so the reconcile has to be a pure function of
/// "what did we believe last time" + "what is here now". Notes are emitted only
/// on a TRANSITION; a mic that has been missing for an hour must not re-nag on
/// every list churn.
///
/// Pure and hardware-free so the transition table is unit-testable on a machine
/// with no input devices at all.
public enum SelectedDeviceReconciler {
    /// What the caller should do with the current list.
    public enum Action: Equatable, Sendable {
        /// No device is selected (system default) — nothing to apply, nothing to say.
        case noSelection
        /// Selected device is present and was already present (or this is the
        /// first look at the list). Apply it; stay silent.
        case adopted(name: String)
        /// Selected device just went missing (or was missing at launch). Fall
        /// back to the system default and tell the user once.
        case fellBackToDefault
        /// Selected device came back. Re-apply it and tell the user once.
        case readopted(name: String)
        /// Selected device is still missing and we already said so. Keep the
        /// fallback; stay silent.
        case stillAbsent
    }

    /// Shown when the chosen microphone is not in the device list.
    public static let unavailableNote = "Selected mic unavailable — using the system default"

    /// Shown when the chosen microphone reappears.
    public static func readoptedNote(name: String) -> String {
        "Selected mic is back — using \(name)"
    }

    /// - Parameters:
    ///   - previouslyAvailable: what the last reconcile concluded — `nil` when
    ///     this is the first list we have seen (launch), or when the selection
    ///     just changed.
    ///   - selectedUID: the persisted device UID (nil/empty = system default).
    ///   - devices: the current input-device list.
    public static func reconcile(
        previouslyAvailable: Bool?,
        selectedUID: String?,
        devices: [AudioInputDevice]
    ) -> Action {
        guard let uid = selectedUID, !uid.isEmpty else { return .noSelection }
        if let device = devices.first(where: { $0.uid == uid }) {
            return previouslyAvailable == false
                ? .readopted(name: device.name)
                : .adopted(name: device.name)
        }
        // Absent. Only the first sighting of the absence is worth a note.
        return previouslyAvailable == false ? .stillAbsent : .fellBackToDefault
    }
}

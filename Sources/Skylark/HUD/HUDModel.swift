import Foundation
import SkylarkCore
import SwiftUI

/// Observable snapshot the HUD SwiftUI view renders from.
@MainActor
@Observable
final class HUDModel {
    var state: HUDState = .idle
    var isHovering = false

    var isRecording: Bool {
        if case .listening = state { return true }
        return false
    }
}

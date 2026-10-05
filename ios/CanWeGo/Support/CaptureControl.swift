import AppIntents
import Foundation

/// Control Center, the Lock Screen and the Action button: Can We Go opens
/// on a new save. The widget extension declares the same intent so its
/// control can name it; opening the app, it always runs here.
struct AddSaveControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Can We Go"
    static let description = IntentDescription("Opens Can We Go ready to add something.")
    static let supportedModes: IntentModes = .foreground

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureGate.pendingOpen = true
        NotificationCenter.default.post(name: .cwgCaptureImage, object: nil)
        return .result()
    }
}

import AppIntents
import SwiftUI
import WidgetKit

/// "Add to Can We Go" in Control Center, on the Lock Screen and on the
/// Action button: opens the app on a new save.
struct AddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.cansaglam.CanWeGo.add") {
            ControlWidgetButton(action: AddSaveControlIntent()) {
                // Controls take symbols only, never a full-colour image, so
                // this is the app icon's "GO?" as a custom symbol.
                Label("Add to Can We Go", image: "GoMark")
            }
        }
        .displayName("Add to Can We Go")
        .description("Opens Can We Go ready to add something.")
    }
}

/// Mirror of the app's `AddSaveControlIntent`, by name: the control needs the
/// type, and since it opens the app the system runs the app's copy.
struct AddSaveControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Can We Go"
    static let description = IntentDescription("Opens Can We Go ready to add something.")
    static let supportedModes: IntentModes = .foreground

    init() {}

    func perform() async throws -> some IntentResult {
        .result()
    }
}

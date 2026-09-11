import SwiftUI
import UIKit

/// Principal class of the share extension: hosts the SwiftUI sheet.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // Follow the app theme, not the device: cream is light, everything
        // else stays dark so glass and secondary text stay readable.
        let style: UIUserInterfaceStyle = ThemeStore.shared.current.isLight ? .light : .dark
        overrideUserInterfaceStyle = style

        let host = UIHostingController(
            rootView: ShareView(
                extensionContext: extensionContext,
                complete: { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                },
                cancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(
                        withError: NSError(domain: "CanWeGo", code: 0)
                    )
                }
            )
        )
        host.overrideUserInterfaceStyle = style
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        host.didMove(toParent: self)
    }
}

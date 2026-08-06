import SwiftUI
import UIKit

/// Principal class of the share extension: hosts the SwiftUI sheet.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // The extension inherits the device's appearance; our UI lives on
        // deep blue, so materials and .secondary text must resolve dark or
        // the whole sheet goes illegible in light mode.
        overrideUserInterfaceStyle = .dark

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
        host.overrideUserInterfaceStyle = .dark
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        host.didMove(toParent: self)
    }
}

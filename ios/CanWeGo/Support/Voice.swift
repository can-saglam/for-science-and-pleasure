import Foundation

/// Who the app is talking to. With two or more in the group the copy is
/// plural ("Where are we going?", "We did go!"); alone, it's singular
/// ("Where are you going?", "I did go!"). Read inside a view body so the
/// wording follows the group card as it changes.
@MainActor
enum Voice {
    /// More than one member on the card: the library is shared.
    static var plural: Bool { (GroupStore.shared.card?.members.count ?? 1) > 1 }

    /// The capture sheet's title.
    static var whereGoing: String { plural ? "Where are we going?" : "Where are you going?" }

    /// The verb of the journal, as a sentence start: "We did go" / "I did go".
    static var didGo: String { plural ? "We did go" : "I did go" }
    /// The action label: "We did go!" / "I did go!".
    static var didGoBang: String { didGo + "!" }
    /// The section and archive name, in title case.
    static var didGoSection: String { plural ? "We Did Go" : "I Did Go" }
    /// For a card that was marked missed first.
    static var didGoAfterAll: String { didGo + " after all" }
    /// The undo toast after marking something done.
    static func didGoTo(_ title: String) -> String {
        "\(didGo) to \u{201c}\(title)\u{201d}!"
    }
}

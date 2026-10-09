import SwiftUI

/// "Joyce saved this yesterday · Open": the quiet word, under the card's
/// title, that something is already in the library. Good news more than a
/// warning, so no warning colours, and it never blocks: the card's own
/// Save becomes "Save anyway".
struct DuplicateStrip: View {
    let line: String
    /// The saver's swatch; without one the strip shows the library icon.
    var initial: String? = nil
    var colour: String? = nil
    /// Nil when there's no original to open (the share sheet without an id).
    var open: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            badge
            Text(line)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppBackground.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let open {
                Button("Open") {
                    Haptics.tap()
                    open()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppBackground.ink)
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(6)
        .padding(.trailing, open == nil ? 8 : 0)
        .background(AppBackground.wash(0.06), in: .rect(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var badge: some View {
        Group {
            if let initial {
                Text(initial)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AvatarColour.initial(colour))
                    .frame(width: 28, height: 28)
                    .background(AvatarColour.color(colour), in: .circle)
            } else {
                Image(systemName: "books.vertical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppBackground.secondaryInk)
                    .frame(width: 28, height: 28)
                    .background(AppBackground.wash(0.08), in: .circle)
            }
        }
        .accessibilityHidden(true)
    }
}

extension DuplicateStrip {
    /// The strip for a save in the library: who saved it, with their swatch.
    @MainActor
    init(twin: Item, open: (() -> Void)?) {
        let member = GroupStore.shared.card?.member(twin.createdBy)
        let name = member?.displayName ?? MembersStore.shared.saverName(for: twin)
        self.init(
            line: DuplicateFinder.describe(twin),
            initial: name.flatMap { $0.first }.map { String($0).uppercased() },
            colour: member?.avatarColour,
            open: open
        )
    }
}

import SwiftUI

/// iPhone Duo's bar APIs, for an app that still runs on iOS 26: there they
/// do nothing, which is also what they do on any other iPhone.

extension EnvironmentValues {
    /// The save open in the side pane, so its card in the list can show it.
    @Entry var openSaveID: UUID?
    /// The side bar's Add button, in global coordinates, for a save's
    /// floating buttons beside it to match in height and line up with.
    @Entry var floatingRowMatch: CGRect?
    /// Where that row's container ends, in global coordinates: the bottom
    /// of the safe area. Measured by the page, not the row, so moving the
    /// row can't move it.
    @Entry var floatingRowFloor: CGFloat?
    /// The row's trailing inset when it runs on into the side bar's column
    /// (a drawer on iPhone Duo's outer display): in line with the bar's
    /// buttons above it.
    @Entry var floatingRowTrailing: CGFloat?
}

enum Foldable {
    /// iPhone Duo's two displays are both close to square (about 1.45:1);
    /// every other iPhone is 1.78:1 or taller, and an iPhone app on an iPad
    /// or a Mac runs in an iPhone-shaped window. Only the Duo rotates: it
    /// has to, to support every pose; other iPhones stay portrait.
    static func rotates(_ window: UIWindow?) -> Bool {
        window.map { rotates($0.bounds.size) } ?? false
    }

    static func rotates(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return max(size.width, size.height) / min(size.width, size.height) < 1.6
    }

    /// iPhone Duo open and held sideways: room for two columns, with the
    /// bars down the side.
    static func opensWide(_ size: CGSize) -> Bool {
        rotates(size) && size.width >= 760
    }

    /// The app's size before anything has laid out, for views that would
    /// otherwise spend their first frame finding out. Zero in the share
    /// extension.
    @MainActor static var launchSize: CGSize {
        #if APP_EXTENSION
        .zero
        #else
        UIApplication.shared.connectedScenes.lazy
            .compactMap { $0 as? UIWindowScene }.first?.coordinateSpace.bounds.size ?? .zero
        #endif
    }
}

/// Where the app's bars run, as the library last saw them, for views that
/// can't read it themselves: sheets, whose own bars stay horizontal.
@Observable
final class SideBars {
    static let shared = SideBars()
    var edge: HorizontalEdge?
}

enum BarPriority { case high, low }

extension ToolbarContent {
    /// Which toolbar items stay out of the overflow menu longest when the
    /// bars run down the side of a short display.
    @ToolbarContentBuilder
    func keptVisible(_ priority: BarPriority) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(priority == .high ? .high : .low)
        } else {
            self
        }
    }
}

extension View {
    /// The edge the bars run down on iPhone Duo, or nil while they're at
    /// the top and bottom as usual. Read inside a navigation stack.
    func onBarsEdgeChange(_ action: @escaping (HorizontalEdge?) -> Void) -> some View {
        modifier(BarsEdgeReader(action: action))
    }
}

/// A sideways row fading out just past the cards' edge, short of the side
/// bars. Off, nothing is applied, so other iPhones keep the plain clip.
struct TrailingFade: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 40)
                }
                .padding(.vertical, -64)
                .padding(.leading, -64)
                .padding(.trailing, 12)
            }
        } else {
            content
        }
    }
}

private struct BarsEdgeReader: ViewModifier {
    let action: (HorizontalEdge?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Reader(action: action))
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private struct Reader: ViewModifier {
        @Environment(\.toolbarVerticalEdge) private var edge
        let action: (HorizontalEdge?) -> Void

        func body(content: Content) -> some View {
            content.onChange(of: edge, initial: true) { _, edge in action(edge) }
        }
    }
}

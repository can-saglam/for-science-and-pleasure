import SwiftUI

/// The theme picker as a row of coloured discs — one tap, live preview,
/// the name of the current one at the trailing end. The same row on the
/// first-run's "There it is." page and in Settings, so the two agree.
struct ThemeSwatchRow: View {
    var title = "Make it yours"
    /// Runs on a pick of a *different* theme; the caller decides how to
    /// commit (the first run previews and commits, Settings also flips
    /// the home-screen icon).
    let onPick: (AppTheme) -> Void

    @State private var themes = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(themes.current.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: themes.current)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases) { option in
                        swatch(option)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func swatch(_ option: AppTheme) -> some View {
        let on = themes.current == option
        return Button {
            guard !on else { return }
            Haptics.selection()
            onPick(option)
        } label: {
            // Just the base colour: the disc is the theme.
            Circle()
                .fill(option.base)
                .frame(width: 38, height: 38)
                .overlay(
                    Circle().strokeBorder(
                        on ? AppBackground.ink : AppBackground.ink.opacity(0.2),
                        lineWidth: on ? 2.5 : 1
                    )
                )
                .scaleEffect(on ? 1.08 : 1)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: on)
                .padding(3)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

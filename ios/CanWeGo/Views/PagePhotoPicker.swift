import SwiftUI
import UIKit

/// The pictures on a save's page, to pick its photo by hand when the
/// parser chose badly or found none. Only the page's own images — never
/// a maps photo.
struct PagePhotoPicker: View {
    let page: URL
    var current: String?
    /// The chosen picture, and the colour the save takes from it.
    let pick: (URL, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [URL]?
    /// Ones that loaded too small to be a photo, or not at all.
    @State private var dropped: Set<URL> = []

    private var shown: [URL] { (candidates ?? []).filter { !dropped.contains($0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if candidates == nil {
                    HStack(spacing: 8) {
                        SmallRing()
                        Text("Looking through the page…")
                    }
                    .font(.subheadline)
                    .foregroundStyle(AppBackground.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                } else if shown.isEmpty {
                    Text("No photos on this page. Your save keeps its colour instead.")
                        .font(.subheadline)
                        .foregroundStyle(AppBackground.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(shown, id: \.self) { url in
                            PagePhotoCell(url: url, selected: url.absoluteString == current) {
                                dropped.insert(url)
                            } choose: { colour in
                                Haptics.success()
                                pick(url, colour)
                                dismiss()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .appBackground(AppBackground.sheet)
            .sheetTitle("Pick a photo") { dismiss() }
        }
        .foregroundStyle(AppBackground.ink)
        .appColorScheme()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { candidates = await PagePhotos.candidates(at: page) }
    }
}

private struct PagePhotoCell: View {
    let url: URL
    let selected: Bool
    let unusable: () -> Void
    let choose: (String?) -> Void
    @State private var image: UIImage?
    @State private var colour: String?

    var body: some View {
        Button { choose(colour) } label: {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        AppBackground.wash(0.06)
                    }
                }
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppBackground.accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, AppBackground.accent)
                            .padding(8)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .accessibilityLabel(selected ? "Current photo" : "Photo from the page")
        .task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data),
                  min(loaded.size.width * loaded.scale, loaded.size.height * loaded.scale) >= 300
            else { unusable(); return }
            colour = PagePhotos.colour(of: loaded)
            image = loaded.preparingThumbnail(of: CGSize(width: 600, height: 600 * loaded.size.height / max(loaded.size.width, 1))) ?? loaded
        }
    }
}

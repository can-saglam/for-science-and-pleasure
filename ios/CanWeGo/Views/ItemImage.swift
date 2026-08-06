import SwiftUI

/// Thumbnail pulled from the source page (og:image) — shown on the share
/// preview, the capture preview, and the detail sheet. Collapses to nothing
/// if the image can't be loaded, so layouts never show a broken frame.
struct ItemImage: View {
    let url: URL
    var height: CGFloat = 170

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )
            case .failure:
                EmptyView()
            default:
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .frame(height: height)
                    .overlay(ProgressView().tint(.white.opacity(0.5)))
            }
        }
    }
}

import SwiftUI
import UIKit

/// A postcard of one save for the share sheet — the photo, the title in the
/// app's own hand, where and when, and the wordmark. Rendered off-screen at
/// 4:5 so it drops into a story or a chat looking like the app, not like a
/// screenshot of a list.
struct ShareCard: View {
    let item: Item
    let image: UIImage?

    private static let size = CGSize(width: 540, height: 675)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            base

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.size.width, height: Self.size.height * 0.62, alignment: .top)
                    .clipped()
                    .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.45),
                                .init(color: .clear, location: 0.62),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                if AppBackground.theme.isLight {
                    // Ink on paper needs the photo to be gone where the
                    // type starts, so cream adds a paper veil over the fade.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.36),
                            .init(color: AppBackground.base.opacity(0.85), location: 0.6),
                            .init(color: AppBackground.base.opacity(0.85), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if let category = item.category?.trimmingCharacters(in: .whitespaces), !category.isEmpty {
                    Text(category.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(item.accentColor.mix(with: typeColor, by: 0.55))
                }
                Text(item.title)
                    .font(.post(40, relativeTo: .largeTitle))
                    .foregroundStyle(typeColor)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                if !whereLine.isEmpty {
                    Text(whereLine)
                        .font(.title3)
                        .foregroundStyle(typeColor.opacity(0.75))
                        .lineLimit(2)
                }
                if let when = item.timeLabel {
                    Text(when)
                        .font(.headline)
                        .foregroundStyle(typeColor.opacity(0.6))
                }
                HStack {
                    Spacer()
                    LogoTitle(height: 22)
                        .opacity(0.9)
                }
                .padding(.top, 18)
            }
            .padding(32)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(.rect(cornerRadius: 36, style: .continuous))
    }

    private var base: some View {
        LinearGradient(
            colors: [
                AppBackground.base.mix(with: item.accentColor, by: 0.35),
                AppBackground.base.mix(with: item.accentColor, by: 0.12),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Dark themes print white on the photo's fade-out; cream prints in ink,
    /// since the fade lands on light paper where white would vanish.
    private var typeColor: Color {
        image != nil && !AppBackground.theme.isLight ? .white : AppBackground.ink
    }

    private var whereLine: String {
        [item.venue, item.area]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The finished picture, wrapped so a sheet can be driven by it.
    struct Rendered: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    /// Fetches the full-size photo (never the card thumbnail — it would
    /// look soft at share size) and renders at 2× for a 1080 × 1350 result.
    @MainActor
    static func render(_ item: Item) async -> Rendered? {
        var photo: UIImage?
        if let url = item.imageUrl.flatMap(URL.init(string:)) {
            photo = await ImageStore.fetch(url, variant: .hero)
        }
        let renderer = ImageRenderer(content: ShareCard(item: item, image: photo))
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.uiImage.map(Rendered.init)
    }
}

/// `UIActivityViewController` in a sheet — `ShareLink` wants its payload at
/// build time, and the postcard is rendered on demand.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

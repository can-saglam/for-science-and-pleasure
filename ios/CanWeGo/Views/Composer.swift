import PhotosUI
import SwiftUI

/// The one way anything gets typed into the app: the field on top,
/// an attached picture in the middle, and a tool row along the bottom
/// (gallery, camera and — where offered — a blank card on the left, the
/// round send button on the right).
/// Shared by the capture sheet and the first-run's save page so they
/// are the same thing, not two things that look alike.
///
/// While the field is empty a ticker of ideas stands in for the
/// placeholder, one line at a time, until they start typing.
struct Composer: View {
    @Binding var text: String
    @Binding var imageJPEG: Data?
    /// The parent is reading what was sent; the tool row shows the
    /// parsing phrases and the send button spins.
    var busy = false
    /// Optional third tool after the camera: start a blank card by hand,
    /// skipping the parser. Nil hides it (the first-run page has no
    /// manual path).
    var onManual: (() -> Void)? = nil
    var onSend: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var cameraOpen = false
    @State private var tickerIndex = 0

    /// What the empty field suggests. Kept under ~30 characters so each
    /// fits on one line.
    static let prompts = [
        "An exhibition, a restaurant, a link…",
        "The gig you want to go to this year",
        "A restaurant off Instagram",
        "An exhibition closing soon",
        "A Dice, RA or Songkick page",
        "The bakery from that TikTok",
        "A play, a talk, a market",
        "Somewhere from Google Maps",
        "A film's last screening",
        "That bar a friend swears by",
    ]

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageJPEG != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $text, axis: .vertical)
                .foregroundStyle(AppBackground.ink)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityLabel("Link or name")
                .background(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.prompts[tickerIndex % Self.prompts.count])
                            .foregroundStyle(AppBackground.ink.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .id(tickerIndex)
                            // Rolls upward: the old line leaves at the top
                            // as the new one rises from below.
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .offset(y: 14).combined(with: .opacity),
                                removal: .offset(y: -14).combined(with: .opacity)
                            ))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .clipped()
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2.6))
                        guard text.isEmpty else { continue }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
                            tickerIndex += 1
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if let image = imageJPEG.flatMap(UIImage.init(data:)) {
                attachedThumbnail(image)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            HStack(spacing: 8) {
                if busy {
                    // The send button is already spinning; the copy alone
                    // says what's happening.
                    ParsingPhrases(text: text, hasImage: imageJPEG != nil)
                        .padding(.leading, 6)
                } else {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        toolIcon("photo")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach a photo")

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            Haptics.tap()
                            cameraOpen = true
                        } label: {
                            toolIcon("camera")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Take a photo")
                    }

                    if let onManual {
                        Button {
                            Haptics.tap()
                            onManual()
                        } label: {
                            // Worded, unlike its neighbours: the glyph
                            // alone doesn't say "skip the parser".
                            Label("Add manually", systemImage: "rectangle.and.pencil.and.ellipsis")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppBackground.ink.opacity(0.85))
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(AppBackground.wash(0.10), in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    Haptics.tap()
                    onSend()
                } label: {
                    Group {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AppBackground.onProminent)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .frame(width: 34, height: 34)
                    // Lit (white pill, dark glyph) whenever there's something
                    // to send — including while it's being sent, so the
                    // spinner stays dark-on-white in every theme.
                    .foregroundStyle(
                        canSend
                            ? AnyShapeStyle(AppBackground.onProminent)
                            : AnyShapeStyle(AppBackground.ink.opacity(0.45))
                    )
                    .background(
                        Circle().fill(canSend
                            ? Color.white.opacity(0.92)
                            : AppBackground.wash(0.16))
                    )
                    // On cream the lit white disc sits on a near-white
                    // field; a hairline gives it an edge.
                    .overlay(
                        Circle().strokeBorder(
                            AppBackground.ink.opacity(
                                canSend && AppBackground.theme.isLight ? 0.22 : 0),
                            lineWidth: 1)
                    )
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(busy || !canSend)
                .accessibilityLabel("Add something")
            }
            .padding(10)
            .animation(.snappy, value: busy)
        }
        .background(AppBackground.wash(0.08), in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    AppBackground.ink.opacity(focused ? 0.22 : 0.10),
                    lineWidth: 1
                )
        )
        // Anywhere on the composer counts as the field. No auto-focus on
        // appear: in the sheet the keyboard would shove it to full height,
        // and the half-open drawer is the point.
        .contentShape(.rect(cornerRadius: 24, style: .continuous))
        .onTapGesture { focused = true }
        .animation(.snappy, value: focused)
        // Sending puts the keyboard away so the result has the room.
        .onChange(of: busy) { _, now in if now { focused = false } }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraPicker { image in
                withAnimation(.snappy) {
                    imageJPEG = image.compressedForUpload()
                }
            }
            .ignoresSafeArea()
        }
    }

    /// Small round tool button in the bottom row.
    private func toolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppBackground.ink.opacity(0.85))
            .frame(width: 34, height: 34)
            .background(AppBackground.wash(0.10), in: .circle)
            .contentShape(.circle)
    }

    /// Just the picture with a small × on its corner — the way AI composers
    /// show attachments. It speaks for itself; no caption needed.
    private func attachedThumbnail(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppBackground.ink.opacity(0.2), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.snappy) {
                        imageJPEG = nil
                        photoItem = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.55), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove photo")
                .offset(x: 6, y: -6)
            }
            // Keep the × tappable where it pokes past the picture's corner.
            .padding(.top, 6)
            .padding(.trailing, 6)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = data.compressedImageForUpload()
        else { return }
        withAnimation(.snappy) {
            imageJPEG = jpeg
        }
    }
}

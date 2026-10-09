import PhotosUI
import SwiftUI

/// The one way anything gets typed into the app, as a Messages-style bar:
/// + on the left for a photo, the camera or (where offered) a blank card,
/// then the field with the round send button inside it. An attached
/// picture sits in the field above the text.
/// Shared by the add page, where it's docked on the keyboard, and the
/// first-run's save page, so they are the same thing, not two things
/// that look alike.
///
/// While the field is empty a ticker of ideas stands in for the
/// placeholder, one line at a time, until they start typing.
struct Composer: View {
    @Binding var text: String
    @Binding var imageJPEG: Data?
    /// The parent is reading what was sent; the send button spins.
    var busy = false
    /// No connection: the send button becomes Save, which keeps the input
    /// to be finished later instead of reading it now.
    var offline = false
    /// Optional last item in the + menu: start a blank card by hand,
    /// skipping the parser. Nil hides it (the first-run page has no
    /// manual path).
    var onManual: (() -> Void)? = nil
    var onSend: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var photoItem: PhotosPickerItem?
    @State private var photoOpen = false
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

    private static let control: CGFloat = 40

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageJPEG != nil
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            moreMenu
            field
        }
        .animation(.snappy, value: busy)
        .animation(.snappy, value: offline)
        // Sending puts the keyboard away so the result has the room.
        .onChange(of: busy) { _, now in if now { focused = false } }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .photosPicker(isPresented: $photoOpen, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraPicker { image in
                withAnimation(.snappy) {
                    imageJPEG = image.compressedForUpload()
                }
            }
            .ignoresSafeArea()
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                photoOpen = true
            } label: {
                Label("Photo library", systemImage: "photo")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    cameraOpen = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            if let onManual {
                Button(action: onManual) {
                    Label("Fill it in yourself", systemImage: "rectangle.and.pencil.and.ellipsis")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppBackground.ink)
                .frame(width: Self.control, height: Self.control)
                .contentShape(.circle)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(busy)
        .accessibilityLabel("More ways to add")
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = imageJPEG.flatMap(UIImage.init(data:)) {
                attachedThumbnail(image)
                    .padding(.top, 10)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("", text: $text, axis: .vertical)
                    .foregroundStyle(AppBackground.ink)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityLabel("Link or name")
                    .background(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(Self.prompts[tickerIndex % Self.prompts.count])
                                .foregroundStyle(AppBackground.ink.opacity(0.6))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
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
                    .padding(.vertical, 10)

                sendButton
                    .padding(.bottom, 5)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 5)
        .frame(minHeight: Self.control)
        .background(AppBackground.wash(0.10), in: .rect(cornerRadius: Self.control / 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.control / 2, style: .continuous)
                .strokeBorder(AppBackground.ink.opacity(focused ? 0.24 : 0.12), lineWidth: 1)
        )
        // Anywhere on the bar counts as the field. No auto-focus on
        // appear: the keyboard would cover what the page offers.
        .contentShape(.rect(cornerRadius: Self.control / 2, style: .continuous))
        .onTapGesture { focused = true }
        .animation(.snappy, value: focused)
    }

    private var sendButton: some View {
        Button {
            Haptics.tap()
            onSend()
        } label: {
            Group {
                if offline {
                    // The spinner sits over the hidden label, so the pill
                    // keeps its width while the draft is made.
                    Text("Save")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .opacity(busy ? 0 : 1)
                        .overlay { if busy { sendSpinner } }
                } else if busy {
                    sendSpinner.frame(width: 30)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 30)
                }
            }
            .frame(height: 30)
            // Lit (white, dark glyph) whenever there's something to send,
            // including while it's being sent, so the spinner stays
            // dark-on-white in every theme.
            .foregroundStyle(
                canSend
                    ? AnyShapeStyle(AppBackground.onProminent)
                    : AnyShapeStyle(AppBackground.ink.opacity(0.45))
            )
            .background(
                Capsule().fill(canSend
                    ? Color.white.opacity(0.92)
                    : AppBackground.wash(0.16))
            )
            // On cream the lit white disc sits on a near-white field; a
            // hairline gives it an edge.
            .overlay(
                Capsule().strokeBorder(
                    AppBackground.ink.opacity(
                        canSend && AppBackground.theme.isLight ? 0.22 : 0),
                    lineWidth: 1)
            )
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(busy || !canSend)
        .accessibilityLabel(offline ? "Save for later" : "Add something")
    }

    private var sendSpinner: some View {
        ProgressView()
            .controlSize(.small)
            .tint(AppBackground.onProminent)
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
                        // A 44pt target around the small ×, same spot.
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove photo")
                .offset(x: 18, y: -18)
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

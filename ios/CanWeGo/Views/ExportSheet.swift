import SwiftData
import SwiftUI

/// What the export is before it happens: the three files and where each
/// one goes, then one button that hands them to the share sheet.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var items: [Item]
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var files: [URL]?
    @State private var detent: PresentationDetent = .medium

    private var count: Int {
        items.filter { !$0.isDeleted && $0.deletedAt == nil }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Everything you\u{2019}ve saved, as files any app can open. Yours to keep.")
                        .font(.subheadline)
                        .foregroundStyle(AppBackground.ink.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 16) {
                        fileRow("tablecells", "Spreadsheet",
                                "Every detail, for Numbers, Excel or Google Sheets. Google My Maps can pin your places from it.")
                        fileRow("calendar", "Calendar",
                                "Your dated events. Save to Files, tap it, then Add All.")
                        fileRow("doc.plaintext", "Readable list",
                                "A tidy list for Notes or any text app.")
                    }
                }
                .padding(20)
            }
            // Pinned, so the button is on screen at half height and at big
            // text sizes alike.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    Haptics.tap()
                    files = LibraryExport.write(items)
                } label: {
                    Label(count == 1 ? "Export 1 save" : "Export \(count) saves", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .prominentGlass()
                .controlSize(.large)
                .disabled(count == 0)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .background {
                    LinearGradient(
                        stops: [.init(color: AppBackground.sheet.opacity(0), location: 0),
                                .init(color: AppBackground.sheet, location: 0.35)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
            }
            .appBackground(AppBackground.sheet)
            .sheetTitle("Export your library") {
                dismiss()
            }
        }
        .foregroundStyle(AppBackground.ink)
        .appColorScheme()
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear { if typeSize.isAccessibilitySize { detent = .large } }
        // Once the files have gone wherever they're going, so has this.
        .sheet(isPresented: Binding(
            get: { files != nil },
            set: { if !$0 { files = nil } }
        ), onDismiss: { dismiss() }) {
            ActivitySheet(
                items: LibraryExport.shareItems(files ?? []),
                excluded: LibraryExport.excludedTargets
            )
            .presentationDetents([.medium, .large])
        }
        // CWG_SETTINGS=export-share is only set by automated test runs.
        .task {
            if ProcessInfo.processInfo.environment["CWG_SETTINGS"] == "export-share" {
                try? await Task.sleep(for: .seconds(1))
                files = LibraryExport.write(items)
            }
        }
    }

    /// The Settings row badge, so the files read as part of that list.
    private func fileRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppBackground.badgeGlyph)
                .frame(width: 28, height: 28)
                .background(AppBackground.badge.gradient, in: .rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppBackground.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

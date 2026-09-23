import SwiftUI

enum LegalPage: String, Identifiable {
    case privacy
    case terms
    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: "Privacy"
        case .terms: "Terms"
        }
    }

    var bodyText: String {
        let name = self == .privacy ? "PRIVACY" : "TERMS"
        if let url = Bundle.main.url(forResource: name, withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return self == .privacy
            ? "Can We Go? stores the cards you save and who is in your group. We do not sell that or run ads."
            : "You are responsible for what you save and who you invite."
    }
}

struct LegalSheet: View {
    let page: LegalPage
    @Environment(\.dismiss) private var dismiss

    /// The same Markdown file the website publishes, laid out block by
    /// block: SwiftUI's own Markdown is inline-only, so headings and
    /// bullets would otherwise show their `#` and `-`.
    private enum Block: Hashable {
        case title(String), heading(String), bullet(String), paragraph(String)
    }

    private var blocks: [Block] {
        page.bodyText.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .title(let s):
            Text(inline(s)).font(.displaySmall(28, relativeTo: .title))
        case .heading(let s):
            Text(inline(s)).font(.headline).padding(.top, 8)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(s))
            }
        case .paragraph(let s):
            Text(inline(s))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .appBackground(AppBackground.sheet)
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
    }
}

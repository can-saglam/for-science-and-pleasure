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

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: page.bodyText, options: options))
            ?? AttributedString(page.bodyText)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(rendered)
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

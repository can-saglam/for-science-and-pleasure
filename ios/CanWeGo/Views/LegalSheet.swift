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
        switch self {
        case .privacy:
            Bundle.main.url(forResource: "PRIVACY", withExtension: "md")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                ?? """
                Can We Go? stores the cards you save and who is in your group.
                We do not sell that. Publish the full policy and this screen
                will show it. Draft: docs/PRIVACY.md in the repo.
                """
        case .terms:
            Bundle.main.url(forResource: "TERMS", withExtension: "md")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                ?? """
                You are responsible for what you save and who you invite.
                Draft: docs/TERMS.md in the repo.
                """
        }
    }
}

struct LegalSheet: View {
    let page: LegalPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(page.bodyText)
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

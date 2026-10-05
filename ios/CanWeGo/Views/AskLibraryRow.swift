import SwiftUI

/// Atop a search that reads like a question ("anything free on
/// Saturday?"): tapped, or the search submitted, Apple's on-device model
/// answers it from the saves. The plain search results stay below.
@available(iOS 27.0, *)
struct AskLibraryRow: View {
    let question: String
    @Binding var asked: String?
    let open: (UUID) -> Void

    var body: some View {
        Group {
            if asked == question {
                AskLibraryAnswer(question: question, open: open)
            } else {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { asked = question }
                } label: {
                    prompt
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask your saves: \(question)")
            }
        }
        .foregroundStyle(AppBackground.ink)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.top, 4)
    }

    private var prompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppBackground.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask your saves")
                    .font(.subheadline.weight(.semibold))
                Text("“\(question)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(AppBackground.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    /// Searches that are questions rather than words to find: a question
    /// mark, a question's first word, or a sentence's length.
    static func isQuestion(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return false }
        if text.hasSuffix("?") || words.count >= 4 { return true }
        return starters.contains(words[0].lowercased())
    }

    private static let starters: Set<String> = [
        "what", "what's", "whats", "where", "which", "when", "who", "how", "is", "are",
        "any", "anything", "something", "somewhere", "do", "did", "have", "has", "can",
        "should", "show", "find", "suggest", "recommend",
    ]
}

@available(iOS 27.0, *)
private struct AskLibraryAnswer: View {
    let question: String
    let open: (UUID) -> Void

    private enum Phase {
        case thinking
        case answered(String, [SiriCardRow])
        case failed(String)
    }

    @State private var phase = Phase.thinking

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Ask your saves", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                switch phase {
                case .thinking:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking through your saves…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                case .answered(let text, _):
                    Text(text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed(let text):
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, rows.isEmpty ? 16 : 0)
            .accessibilityElement(children: .combine)

            if !rows.isEmpty {
                SiriSavesCard(rows: rows, total: rows.count)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let id = UUID(uuidString: url.lastPathComponent) else { return .systemAction }
                        open(id)
                        return .handled
                    })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: rows.map(\.id))
        .task(id: question) { await run() }
    }

    private var rows: [SiriCardRow] {
        if case .answered(_, let rows) = phase { rows } else { [] }
    }

    private func run() async {
        phase = .thinking
        do {
            let answer = try await LibraryAsk.ask(question)
            let rows = await SiriCards.dressed(answer.items)
            guard !Task.isCancelled else { return }
            Haptics.tap()
            withAnimation(.snappy) { phase = .answered(answer.text, rows) }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { phase = .failed("Couldn't answer that one. Try asking another way.") }
        }
    }
}

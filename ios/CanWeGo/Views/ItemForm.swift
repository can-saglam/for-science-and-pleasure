import SwiftUI

/// Field-by-field editor for an item — used for parsed drafts in Capture
/// and for editing saved items from the detail sheet.
struct ItemForm: View {
    @Bindable var item: Item

    var body: some View {
        VStack(spacing: 12) {
            field("Title", text: $item.title)

            Picker("Kind", selection: $item.kind) {
                Text("Event").tag(Item.Kind.event)
                Text("Place").tag(Item.Kind.place)
            }
            .pickerStyle(.segmented)

            field("Category", text: optional($item.category))
            field("Venue", text: optional($item.venue))
            field("Area", text: optional($item.area))
            field("Price", text: optional($item.price))

            OptionalDateRow(label: "Opens", value: $item.startsOn)
            OptionalDateRow(label: "Closes", value: $item.endsOn)

            TextField("Notes", text: optional($item.notes), axis: .vertical)
                .lineLimit(2...5)
                .padding(12)
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .padding(14)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .padding(12)
            .background(.white.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

/// "Add date" → date picker + clear, for the optional yyyy-MM-dd fields.
private struct OptionalDateRow: View {
    let label: String
    @Binding var value: String?

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(value == nil ? .tertiary : .secondary)
            Spacer()
            if let value, let date = DayString.date(value) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { date },
                        set: { self.value = DayString.formatter.string(from: $0) }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                Button {
                    Haptics.tap()
                    self.value = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Haptics.tap()
                    value = DayString.today()
                } label: {
                    Label("Add date", systemImage: "calendar.badge.plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        // Same filled row as the text fields, so nothing floats loose.
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

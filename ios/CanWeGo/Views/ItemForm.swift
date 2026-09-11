import SwiftUI

/// Field-by-field editor for an item — used for parsed drafts in Capture
/// and for editing saved items from the detail sheet. Fields carry quiet
/// leading icons and gather under small section headers, so eight rows
/// read as four little thoughts instead of a wall.
struct ItemForm: View {
    @Bindable var item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("The basics") {
                field("Title", icon: "pencil.line", text: $item.title)

                Picker("Kind", selection: $item.kind) {
                    Text("Event").tag(Item.Kind.event)
                    Text("Place").tag(Item.Kind.place)
                }
                .pickerStyle(.segmented)

                field("Category", icon: "tag", text: optional($item.category))
            }

            section("Where") {
                field("Venue", icon: "building.2", text: optional($item.venue))
                field("Area", icon: "mappin.and.ellipse", text: optional($item.area))
            }

            section("When") {
                OptionalDateRow(label: "Opens", icon: "calendar", value: $item.startsOn)
                OptionalDateRow(label: "Closes", icon: "calendar.badge.checkmark", value: $item.endsOn)
                RemindRow(item: item)
            }

            section("Extras") {
                field("Price", icon: "banknote", text: optional($item.price))

                HStack(alignment: .top, spacing: 10) {
                    fieldIcon("note.text")
                        .padding(.top, 3)
                    TextField("Notes", text: optional($item.notes), axis: .vertical)
                        .lineLimit(2...5)
                }
                .padding(12)
                .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func field(_ label: String, icon: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            fieldIcon(icon)
            TextField(label, text: text)
        }
        .padding(12)
        .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Dimmed leading symbol, fixed-width so every field's text starts on the
/// same vertical line.
private func fieldIcon(_ name: String) -> some View {
    Image(systemName: name)
        .font(.subheadline)
        .foregroundStyle(AppBackground.ink.opacity(0.35))
        .frame(width: 22)
}

/// "Add date" → date picker + clear, for the optional yyyy-MM-dd fields.
private struct OptionalDateRow: View {
    let label: String
    let icon: String
    @Binding var value: String?

    var body: some View {
        HStack(spacing: 10) {
            fieldIcon(icon)
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
                .accessibilityLabel("Clear date")
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
        .background(AppBackground.wash(0.07), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

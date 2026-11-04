import SwiftUI

/// Bottom sheet for adding a to-buy item — name, category, quantity and
/// notes all in one place, instead of adding by name alone and then having
/// to go find the row again to set quantity/notes.
struct ToBuyItemSheet: View {
    @Environment(\.dismiss) private var dismiss

    var categories: [String]
    var title: String = "Add to buy"
    var prompt: String = "What do you need?"
    var saveTitle: String = "Save"
    var showsCategoryAndQty = true
    var onSave: (_ text: String, _ category: String?, _ qty: String, _ notes: String) -> Void

    @State private var text = ""
    @State private var category: String?
    @State private var qty = ""
    @State private var notes = ""

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.neutral300)
                .frame(width: 44, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title)
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.ink)

                    TextField(prompt, text: $text)
                        .font(Theme.body(14.5))
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(Theme.surface)
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        .clipShape(Capsule())

                    if showsCategoryAndQty {
                        field(kicker: L("Category")) {
                            FlowLayout(spacing: 7) {
                                compactChip(L("Auto"), selected: category == nil) {
                                    category = nil
                                }
                                ForEach(categories, id: \.self) { option in
                                    compactChip(option, selected: category?.caseInsensitiveCompare(option) == .orderedSame) {
                                        category = option
                                    }
                                }
                            }
                        }

                        field(kicker: L("Quantity")) {
                            TextField("e.g. 2 cups", text: $qty)
                                .font(Theme.body(14))
                                .padding(.horizontal, 16)
                                .frame(height: 46)
                                .background(Theme.surface)
                                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                                .clipShape(Capsule())
                        }
                    }

                    field(kicker: L("Notes")) {
                        TextField("Optional", text: $notes, axis: .vertical)
                            .font(Theme.body(14))
                            .lineLimit(3...10)
                            .padding(12)
                            .frame(minHeight: 70, alignment: .topLeading)
                            .background(Theme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Theme.divider, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }

                    Button(action: save) {
                        Text(saveTitle)
                            .font(Theme.display(15))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(AccentFillButtonStyle(
                        fill: canSave ? Theme.accent : Theme.neutral400,
                        pressedFill: canSave ? Theme.accent600 : Theme.neutral400
                    ))
                    .disabled(!canSave)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .padding(.horizontal, 22)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func field<Content: View>(kicker: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(kicker.uppercased(with: Locale(identifier: "en")))
                .font(Theme.body(10.5, weight: .semibold))
                .tracking(1.26)
                .foregroundStyle(Theme.neutral600)
            content()
        }
    }

    private func compactChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(12.5, weight: .semibold))
                .foregroundStyle(selected ? .white : Theme.neutral800)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.surface)
                .overlay {
                    if !selected {
                        Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                    }
                }
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(
            trimmed,
            showsCategoryAndQty ? category : nil,
            showsCategoryAndQty ? qty.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}

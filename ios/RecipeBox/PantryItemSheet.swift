import SwiftUI

/// Bottom sheet for adding or editing a cupboard inventory row.
struct PantryItemSheet: View {
    @Environment(\.dismiss) private var dismiss

    let item: PantryItem?
    var categories: [String]
    var onSave: (PantryItem) -> Void

    @State private var name: String
    @State private var category: String
    @State private var amountText: String
    @State private var unit: PantryUnit
    @State private var status: PantryItemStatus
    @State private var hasExpiry: Bool
    @State private var expiryDate: Date
    @State private var notes: String

    init(item: PantryItem?, categories: [String], onSave: @escaping (PantryItem) -> Void) {
        let names = categories.isEmpty ? defaultPantryCategories : categories
        self.item = item
        self.onSave = onSave
        if let current = item?.pantryCategory,
           !names.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            self.categories = names + [current]
        } else {
            self.categories = names
        }
        _name = State(initialValue: item?.name ?? "")
        _category = State(initialValue: item?.pantryCategory ?? (names.first ?? "Other"))
        if let amount = item?.amount {
            _amountText = State(initialValue: amount.rounded() == amount
                ? String(Int(amount.rounded()))
                : String(format: "%g", amount))
        } else {
            _amountText = State(initialValue: "1")
        }
        _unit = State(initialValue: item?.unit ?? .pcs)
        _status = State(initialValue: item?.status ?? .unopened)
        if let expiry = item?.expiry, let date = PantryItem.parseExpiry(expiry) {
            _hasExpiry = State(initialValue: true)
            _expiryDate = State(initialValue: date)
        } else {
            _hasExpiry = State(initialValue: false)
            _expiryDate = State(initialValue: Calendar.current.startOfDay(for: Date()))
        }
        _notes = State(initialValue: item?.notes ?? "")
    }

    private var isEditing: Bool { item != nil }
    private var title: String { isEditing ? L("Edit cupboard item") : L("Add cupboard item") }
    private var saveLabel: String { isEditing ? L("Save changes") : L("Add to cupboard") }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

                    TextField("What is it?", text: $name)
                        .font(Theme.body(14.5))
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(Theme.surface)
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        .clipShape(Capsule())

                    field(kicker: L("Category")) {
                        FlowLayout(spacing: 7) {
                            ForEach(categories, id: \.self) { option in
                                compactChip(option, selected: category.caseInsensitiveCompare(option) == .orderedSame) {
                                    category = option
                                }
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 10) {
                        field(kicker: L("Amount")) {
                            TextField("e.g. 200", text: $amountText)
                                .keyboardType(.decimalPad)
                                .font(Theme.body(14))
                                .padding(.horizontal, 16)
                                .frame(height: 46)
                                .background(Theme.surface)
                                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                                .clipShape(Capsule())
                        }

                        field(kicker: L("Unit")) {
                            HStack(spacing: 6) {
                                ForEach(PantryUnit.allCases) { option in
                                    Button {
                                        unit = option
                                    } label: {
                                        Text(option.localizedName)
                                            .font(Theme.body(12.5, weight: .semibold))
                                            .foregroundStyle(unit == option ? .white : Theme.neutral800)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 46)
                                            .background(unit == option ? Theme.accent : Theme.surface)
                                            .overlay {
                                                if unit != option {
                                                    Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                                                }
                                            }
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    field(kicker: L("Status")) {
                        HStack(spacing: 7) {
                            ForEach(PantryItemStatus.allCases) { option in
                                Button {
                                    status = option
                                } label: {
                                    Text(option.label)
                                        .font(Theme.body(13, weight: .semibold))
                                        .foregroundStyle(status == option ? .white : Theme.neutral800)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(status == option ? Theme.accent : Theme.surface)
                                        .overlay {
                                            if status != option {
                                                Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                                            }
                                        }
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    field(kicker: L("Expiry date (optional)")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $hasExpiry) {
                                Text(hasExpiry ? L("Date set") : L("No expiry"))
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.neutral700)
                            }
                            .tint(Theme.accent)

                            if hasExpiry {
                                DatePicker(
                                    "Expiry",
                                    selection: $expiryDate,
                                    displayedComponents: .date
                                )
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 46)
                                .background(Theme.surface)
                                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                                .clipShape(Capsule())
                            }
                        }
                    }

                    field(kicker: L("Notes")) {
                        TextField("Optional", text: $notes, axis: .vertical)
                            .font(Theme.body(14))
                            .lineLimit(3...6)
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
                        Text(saveLabel)
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let amount = Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 1
        let saved = PantryItem(
            id: item?.id ?? UUID().uuidString,
            name: trimmed,
            category: category,
            amount: amount > 0 ? amount : 1,
            unit: unit,
            status: status,
            expiry: hasExpiry ? PantryItem.formatExpiry(expiryDate) : nil,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        onSave(saved)
        dismiss()
    }
}

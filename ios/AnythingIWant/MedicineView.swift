import SwiftUI

/// Medicines list — lives under Cupboard as a sub-category. Standalone
/// header is kept for reuse; Cupboard embeds this without a nested scroll.
struct MedicineView: View {
    @Environment(MedicineStore.self) private var medicines

    var embedded = false
    @Binding var externalAdd: Bool

    @State private var presentedSheet: MedicinePresentedSheet?
    @State private var query = ""

    init(embedded: Bool = false, externalAdd: Binding<Bool> = .constant(false)) {
        self.embedded = embedded
        self._externalAdd = externalAdd
    }

    private enum MedicinePresentedSheet: Identifiable {
        case addItem
        case editItem(MedicineItem)

        var id: String {
            switch self {
            case .addItem: "addItem"
            case .editItem(let item): "edit-\(item.id)"
            }
        }
    }

    var body: some View {
        Group {
            if embedded {
                VStack(alignment: .leading, spacing: 0) {
                    searchField
                        .padding(.bottom, 12)
                    content
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        searchField
                            .padding(.horizontal, Theme.screenPadding)
                            .padding(.bottom, 12)
                        content
                            .padding(.horizontal, Theme.screenPadding)
                            .padding(.bottom, 16)
                    }
                }
                .background(Theme.bg.ignoresSafeArea())
                .scrollIndicators(.hidden)
                .toolbar(.hidden, for: .navigationBar)
                .refreshable { await medicines.refresh() }
            }
        }
        .onChange(of: externalAdd) { _, requested in
            guard requested else { return }
            presentedSheet = .addItem
            externalAdd = false
        }
        .sheet(item: $presentedSheet) { sheet in
            sheetContent(for: sheet)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { medicines.actionError != nil },
                set: { shown in if !shown { medicines.actionError = nil } }
            ),
            presenting: medicines.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: MedicinePresentedSheet) -> some View {
        switch sheet {
        case .addItem:
            MedicineItemSheet(item: nil, categories: medicines.categories) { medicines.upsertItem($0) }
        case .editItem(let item):
            MedicineItemSheet(item: item, categories: medicines.categories) { medicines.upsertItem($0) }
        }
    }

    // MARK: - Header

    /// Same slot Cupboard's categories gear sits in — the "+" here instead,
    /// since there's no per-item toolbar row (no match-mode toggle to share
    /// it with, unlike Cupboard's Items segment).
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Medicines")
                    .font(Theme.display(36))
                    .foregroundStyle(Theme.ink)
                Text(L("\(medicines.itemCount) items"))
                    .font(Theme.body(10.5, weight: .semibold))
                    .tracking(1.47)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.accent700)
            }
            Spacer()
            Button {
                presentedSheet = .addItem
            } label: {
                LucideIcon(.plus, size: 19)
                    .foregroundStyle(Theme.bg)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Add medicine"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 66)
        .padding(.horizontal, Theme.screenPadding)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            LucideIcon(.search, size: 17)
                .foregroundStyle(Theme.neutral600)
            TextField(L("Search your medicines"), text: $query)
                .font(Theme.body(14.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Theme.surface)
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        .clipShape(Capsule())
    }

    private var filterActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredGroupedItems: [(category: String, items: [MedicineItem])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return medicines.groupedItems }
        return medicines.groupedItems.compactMap { group in
            let rows = group.items.filter {
                $0.name.lowercased().contains(q)
                    || $0.purpose.lowercased().contains(q)
                    || group.category.lowercased().contains(q)
            }
            guard !rows.isEmpty else { return nil }
            return (group.category, rows)
        }
    }

    @ViewBuilder
    private var content: some View {
        if medicines.items.isEmpty {
            Text("No medicines added yet.")
                .font(Theme.body(14))
                .foregroundStyle(Theme.neutral600)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else if filteredGroupedItems.isEmpty {
            Text(filterActive ? L("Nothing matches that yet.") : L("No medicines added yet."))
                .font(Theme.body(14))
                .foregroundStyle(Theme.neutral600)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else {
            ForEach(filteredGroupedItems, id: \.category) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.category.uppercased(with: Locale(identifier: "en")))
                        .font(Theme.body(10.5, weight: .semibold))
                        .tracking(1.26)
                        .foregroundStyle(Theme.neutral600)

                    ForEach(group.items) { item in
                        medicineRow(item)
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }

    private func medicineRow(_ item: MedicineItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(Theme.body(14.5, weight: .semibold))
                    .foregroundStyle(Theme.neutral900)
                    .multilineTextAlignment(.leading)

                if !item.purpose.isEmpty {
                    Text(item.purpose)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.neutral600)
                }
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.neutral600)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        amountAndStatusChips(item)
                        if let expiry = item.expiryBadge {
                            expiryChip(expiry)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            amountAndStatusChips(item)
                        }
                        if let expiry = item.expiryBadge {
                            expiryChip(expiry)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LucideTrashButton(accessibilityLabel: L("Remove \(item.name)")) {
                medicines.deleteItem(id: item.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .cardBackground(radius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            presentedSheet = .editItem(item)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.name)
    }

    @ViewBuilder
    private func amountAndStatusChips(_ item: MedicineItem) -> some View {
        metaChip(item.amountLabel, fill: Theme.neutral100, foreground: Theme.neutral700)
        metaChip(
            item.status.label,
            fill: item.status == .open ? Theme.sage100 : Theme.neutral100,
            foreground: item.status == .open ? Theme.sage800 : Theme.neutral700
        )
    }

    private func expiryChip(_ expiry: MedicineItem.ExpiryBadge) -> some View {
        metaChip(
            expiry.label,
            fill: expiry.fill,
            foreground: expiry.foreground,
            border: expiry.border
        )
    }

    private func metaChip(
        _ text: String,
        fill: Color,
        foreground: Color,
        border: Color? = nil
    ) -> some View {
        Text(text)
            .font(Theme.body(10.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(fill)
            .overlay {
                if let border {
                    Capsule().strokeBorder(border, lineWidth: 1)
                }
            }
            .clipShape(Capsule())
    }
}

// MARK: - Expiry / amount helpers

extension MedicineItem {
    var amountLabel: String {
        let formatted: String
        if amount.rounded() == amount {
            formatted = String(Int(amount.rounded()))
        } else {
            formatted = String(format: "%g", amount)
        }
        return "\(formatted) \(unit.localizedName)"
    }

    struct ExpiryBadge {
        let label: String
        let fill: Color
        let foreground: Color
        let border: Color?
    }

    /// Cream text used on solid expiry badges (Organic `#fff8ec`).
    private static let expiryCream = Color(hex: 0xfff8ec)

    var expiryBadge: ExpiryBadge? {
        guard let expiry, let date = parseExpiryDate(expiry) else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let day = Calendar.current.startOfDay(for: date)
        let diff = Calendar.current.dateComponents([.day], from: today, to: day).day ?? 0
        if diff < 0 {
            return ExpiryBadge(label: L("Expired"), fill: Theme.accent800, foreground: Self.expiryCream, border: nil)
        }
        if diff <= 3 {
            let label = diff == 0 ? L("Expires today") : L("Expires in \(diff) days")
            return ExpiryBadge(label: label, fill: Theme.accent500, foreground: Self.expiryCream, border: nil)
        }
        if diff <= 7 {
            return ExpiryBadge(
                label: L("Expires in \(diff) days"),
                fill: Theme.sage200,
                foreground: Theme.sage800,
                border: nil
            )
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return ExpiryBadge(
            label: formatter.string(from: date),
            fill: .clear,
            foreground: Theme.neutral600,
            border: Theme.divider
        )
    }
}

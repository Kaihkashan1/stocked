import SwiftUI

/// Shop (groceries / medicines to buy) and Pack (take to India / bring to Germany).
struct ShopView: View {
    enum Mode {
        case shop
        case pack
    }

    var mode: Mode = .shop

    @Environment(PantryStore.self) private var pantry
    @Environment(MedicineStore.self) private var medicines

    @State private var query = ""
    @State private var showAdd = false
    @State private var segment: ShopSegment

    init(mode: Mode = .shop) {
        self.mode = mode
        _segment = State(initialValue: mode == .shop ? .groceries : .takeToIndia)
    }

    private enum ShopSegment: String, CaseIterable, Identifiable {
        case groceries = "Groceries"
        case medicines = "Medicines"
        case takeToIndia = "Take to India"
        case bringToGermany = "Bring to Germany"
        var id: String { rawValue }
        var localizedName: String { L(String.LocalizationValue(rawValue)) }
        var flag: String? {
            switch self {
            case .takeToIndia: "🇮🇳"
            case .bringToGermany: "🇩🇪"
            default: nil
            }
        }
        var listKey: String {
            switch self {
            case .groceries: "shop"
            case .medicines: "shop_medicines"
            case .takeToIndia: "take_to_india"
            case .bringToGermany: "bring_to_germany"
            }
        }
    }

    private var visibleSegments: [ShopSegment] {
        mode == .shop ? [.groceries, .medicines] : [.takeToIndia, .bringToGermany]
    }

    private var shopCategories: [String] {
        let names: [String]
        switch segment {
        case .groceries: names = pantry.categories
        case .medicines: names = medicines.categories
        case .takeToIndia, .bringToGermany: names = pantry.categories + medicines.categories
        }
        var order: [String] = []
        var seen = Set<String>()
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            order.append(trimmed)
        }
        return order
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                segmentRow
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.bottom, 12)
                searchField
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.bottom, 14)
                content
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.bottom, 16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await pantry.refresh() }
        .sheet(isPresented: $showAdd) {
            ToBuyItemSheet(
                categories: shopCategories,
                title: addTitle,
                prompt: addPrompt,
                saveTitle: L("Save"),
                showsCategoryAndQty: mode == .shop
            ) { text, category, qty, notes in
                pantry.addToBuy(text, qty: qty, category: category, notes: notes, list: segment.listKey)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(34)
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { pantry.actionError != nil },
                set: { shown in if !shown { pantry.actionError = nil } }
            ),
            presenting: pantry.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == .shop ? L("Shop") : L("Pack"))
                    .font(Theme.display(36))
                    .foregroundStyle(Theme.ink)
                Text(shopKicker)
                    .font(Theme.body(10.5, weight: .semibold))
                    .tracking(1.47)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.accent700)
            }
            Spacer()
            Button {
                showAdd = true
            } label: {
                LucideIcon(.plus, size: 19)
                    .foregroundStyle(Theme.bg)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(addTitle)
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
            TextField(searchPlaceholder, text: $query)
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

    private var shopKicker: String {
        if mode == .pack {
            let india = pantry.toBuyCount(in: "take_to_india")
            let germany = pantry.toBuyCount(in: "bring_to_germany")
            return "\(india) 🇮🇳 · \(germany) 🇩🇪"
        }
        let groceries = L("\(pantry.toBuyCount(in: "shop")) groceries")
        let meds = L("\(pantry.toBuyCount(in: "shop_medicines")) medicines")
        return "\(groceries) · \(meds)"
    }

    private var addTitle: String {
        switch segment {
        case .groceries: L("Add to buy")
        case .medicines: L("Add medicine to buy")
        case .takeToIndia: L("Add for India")
        case .bringToGermany: L("Add for Germany")
        }
    }

    private var addPrompt: String {
        switch segment {
        case .groceries: L("What do you need?")
        case .medicines: L("Which medicine?")
        case .takeToIndia: L("What should go to India?")
        case .bringToGermany: L("What should come to Germany?")
        }
    }

    private var searchPlaceholder: String {
        switch segment {
        case .groceries: L("Search groceries to buy")
        case .medicines: L("Search medicines to buy")
        case .takeToIndia: L("Search items for India")
        case .bringToGermany: L("Search items for Germany")
        }
    }

    private var emptyCopy: String {
        switch segment {
        case .groceries: L("Your shop list is empty.")
        case .medicines: L("Nothing to buy for medicines yet.")
        case .takeToIndia: L("Nothing to take to India yet.")
        case .bringToGermany: L("Nothing to bring to Germany yet.")
        }
    }

    private var currentItems: [ToBuyItem] {
        pantry.toBuyItems(in: segment.listKey)
    }

    private var filterActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var segmentRow: some View {
        HStack(spacing: 7) {
            ForEach(visibleSegments) { option in
                Button {
                    segment = option
                    query = ""
                } label: {
                    Text(option.flag ?? option.localizedName)
                        .font(option.flag == nil ? Theme.body(13, weight: .semibold) : Theme.body(22, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.75)
                        .lineLimit(2)
                        .foregroundStyle(segment == option ? .white : Theme.neutral800)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .background(segment == option ? Theme.accent : Theme.surface)
                        .overlay {
                            if segment != option {
                                Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                            }
                        }
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.localizedName)
            }
        }
    }

    private var filteredToBuy: [ToBuyItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = q.isEmpty
            ? currentItems
            : currentItems.filter {
                $0.text.lowercased().contains(q)
                    || $0.notes.lowercased().contains(q)
                    || $0.category.lowercased().contains(q)
            }
        return rows
    }

    private var groupedToBuy: [(category: String, items: [ToBuyItem])] {
        var order: [String] = []
        var seen = Set<String>()
        for name in shopCategories + filteredToBuy.map(\.category) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            order.append(trimmed)
        }
        return order.compactMap { name in
            let rows = filteredToBuy.filter {
                $0.category.caseInsensitiveCompare(name) == .orderedSame
            }
            .sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
            guard !rows.isEmpty else { return nil }
            return (name, rows)
        }
    }

    @ViewBuilder
    private var content: some View {
        if currentItems.isEmpty {
            Text(emptyCopy)
                .font(Theme.body(14))
                .foregroundStyle(Theme.neutral600)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else if filteredToBuy.isEmpty {
            Text(filterActive ? L("Nothing matches that yet.") : emptyCopy)
                .font(Theme.body(14))
                .foregroundStyle(Theme.neutral600)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else if mode == .pack {
            ForEach(filteredToBuy.sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }) { item in
                toBuyRow(item)
            }
        } else {
            ForEach(groupedToBuy, id: \.category) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.category.uppercased(with: Locale(identifier: "en")))
                        .font(Theme.body(10.5, weight: .semibold))
                        .tracking(1.26)
                        .foregroundStyle(Theme.neutral600)
                    ForEach(group.items) { item in
                        toBuyRow(item)
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }

    private func toBuyRow(_ item: ToBuyItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    pantry.toggleChecked(id: item.id)
                } label: {
                    Circle()
                        .strokeBorder(item.checked ? Theme.sage500 : Theme.neutral400, lineWidth: 2)
                        .background(Circle().fill(item.checked ? Theme.sage500 : .clear))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.checked ? L("Uncheck \(item.text)") : L("Check \(item.text)"))

                Text(item.text)
                    .font(Theme.body(14.5, weight: .semibold))
                    .strikethrough(item.checked)
                    .foregroundStyle(item.checked ? Theme.neutral500 : Theme.neutral900)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if item.recipeSourceCount > 1 {
                    Text(L("\(item.recipeSourceCount) recipes"))
                        .font(Theme.body(10.5, weight: .semibold))
                        .foregroundStyle(Theme.neutral500)
                        .fixedSize()
                }

                LucideTrashButton(accessibilityLabel: L("Remove \(item.text)")) {
                    pantry.removeToBuy(id: item.id)
                }
            }

            HStack(spacing: 8) {
                if mode == .shop {
                    TextField("qty", text: Binding(
                        get: { pantry.toBuy.first(where: { $0.id == item.id })?.qty ?? "" },
                        set: { pantry.setToBuyQty(id: item.id, qty: $0) }
                    ))
                    .font(Theme.body(12.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .frame(width: 76, height: 34)
                    .background(Theme.bg)
                    .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                    .clipShape(Capsule())
                    .accessibilityLabel(L("Quantity for \(item.text)"))
                }

                TextField(
                    L("Notes"),
                    text: Binding(
                        get: { pantry.toBuy.first(where: { $0.id == item.id })?.notes ?? "" },
                        set: { pantry.setToBuyNotes(id: item.id, notes: $0) }
                    )
                )
                .font(Theme.body(12.5, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Theme.bg)
                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                .clipShape(Capsule())
                .accessibilityLabel(L("Notes for \(item.text)"))
            }
            .padding(.leading, 34)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardBackground(radius: 22)
    }
}

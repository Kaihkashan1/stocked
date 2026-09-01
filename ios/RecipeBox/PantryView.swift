import SwiftUI

/// Cupboard tab — inventory (Items) and shopping checklist (To buy), plus
/// match-mode recipe suggestions. Stock lives in PantryStore; recipe fit %
/// on the list screen stays on RecipeStore.have.
struct PantryView: View {
    @Environment(PantryStore.self) private var pantry
    @Environment(RecipeStore.self) private var recipes

    var onOpenRecipe: (Int) -> Void = { _ in }

    @State private var segment: PantrySegment = .items
    @State private var matchMode = false
    @State private var matchSelectedIDs: Set<String> = []
    @State private var editingItem: PantryItem?
    @State private var showAddSheet = false
    @State private var newToBuyText = ""
    /// Independent of each other and of the Cookbook search; switching
    /// Items ↔ To buy keeps both queries (handoff §11).
    @State private var stockQuery = ""
    @State private var buyQuery = ""

    private enum PantrySegment: String, CaseIterable, Identifiable {
        case items = "Items"
        case toBuy = "To buy"
        var id: String { rawValue }
        var localizedName: String {
            L(String.LocalizationValue(rawValue))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                segmentRow
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.bottom, 12)

                if segment == .items {
                    stockSearchField
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.bottom, 10)
                    itemsToolbar
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.bottom, 12)
                    itemsContent
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.bottom, 16)
                } else {
                    buySearchField
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.bottom, 10)
                    toBuyToolbar
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.bottom, 12)
                    toBuyContent
                        .padding(.horizontal, Theme.screenPadding)
                        .padding(.bottom, 16)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await pantry.refresh() }
        .sheet(isPresented: $showAddSheet) {
            PantryItemSheet(item: nil) { pantry.upsertItem($0) }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
        }
        .sheet(item: $editingItem) { item in
            PantryItemSheet(item: item) { pantry.upsertItem($0) }
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
        .onChange(of: matchMode) { _, enabled in
            if !enabled { matchSelectedIDs = [] }
        }
    }

    // MARK: - Header / segments

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cupboard")
                .font(Theme.display(36))
                .foregroundStyle(Theme.ink)
            Text(pantry.kickerLine)
                .font(Theme.body(10.5, weight: .semibold))
                .tracking(1.47)
                .textCase(.uppercase)
                .foregroundStyle(Theme.accent700)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 66)
        .padding(.horizontal, Theme.screenPadding)
        .padding(.bottom, 16)
    }

    private var stockSearchField: some View {
        cupboardSearchField(placeholder: L("Search what's in stock"), text: $stockQuery)
    }

    private var buySearchField: some View {
        cupboardSearchField(placeholder: L("Search items to buy"), text: $buyQuery)
    }

    private func cupboardSearchField(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.neutral600)
            TextField(placeholder, text: text)
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

    private var filteredGroupedItems: [(category: PantryCategory, items: [PantryItem])] {
        let q = stockQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return pantry.groupedItems }
        return pantry.groupedItems.compactMap { group in
            let rows = group.items.filter {
                $0.name.lowercased().contains(q)
                    || group.category.rawValue.lowercased().contains(q)
            }
            guard !rows.isEmpty else { return nil }
            return (group.category, rows)
        }
    }

    private var filteredToBuy: [ToBuyItem] {
        let q = buyQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return pantry.toBuy }
        return pantry.toBuy.filter { $0.text.lowercased().contains(q) }
    }

    private var stockFilterActive: Bool {
        !stockQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var buyFilterActive: Bool {
        !buyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var segmentRow: some View {
        HStack(spacing: 7) {
            ForEach(PantrySegment.allCases) { option in
                Button {
                    segment = option
                } label: {
                    Text(option.localizedName)
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(segment == option ? .white : Theme.neutral800)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(segment == option ? Theme.accent : Theme.surface)
                        .overlay {
                            if segment != option {
                                Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                            }
                        }
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Items

    private var itemsToolbar: some View {
        HStack(spacing: 8) {
            Button {
                matchMode.toggle()
            } label: {
                Text(matchMode ? L("Done matching") : L("Select items to match"))
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(matchMode ? .white : Theme.neutral800)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(matchMode ? Theme.accent : Theme.surface)
                    .overlay {
                        if !matchMode {
                            Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                        }
                    }
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Add cupboard item"))
        }
    }

    @ViewBuilder
    private var itemsContent: some View {
        if !matchSelectedIDs.isEmpty {
            matchResultsCard
                .padding(.bottom, 16)
        }

        if pantry.items.isEmpty {
            Text("Nothing in your cupboard yet.")
                .font(Theme.body(14))
                .foregroundStyle(Theme.neutral600)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else if filteredGroupedItems.isEmpty {
            Text(stockFilterActive ? L("Nothing matches that yet.") : L("Nothing in your cupboard yet."))
                .font(Theme.body(14))
                .foregroundStyle(Theme.neutral600)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else {
            ForEach(filteredGroupedItems, id: \.category) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.category.localizedName.uppercased(with: LanguageStore.shared.language.locale))
                        .font(Theme.body(10.5, weight: .semibold))
                        .tracking(1.26)
                        .foregroundStyle(Theme.neutral600)

                    ForEach(group.items) { item in
                        pantryRow(item)
                    }
                }
                .padding(.bottom, 18)
            }
        }
    }

    private func pantryRow(_ item: PantryItem) -> some View {
        let selected = matchSelectedIDs.contains(item.id)
        return HStack(alignment: .center, spacing: 12) {
            if matchMode {
                Circle()
                    .strokeBorder(selected ? Theme.accent : Theme.neutral400, lineWidth: 2)
                    .background(Circle().fill(selected ? Theme.accent : .clear))
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(Theme.body(14.5, weight: .semibold))
                    .foregroundStyle(Theme.neutral900)
                    .multilineTextAlignment(.leading)
                FlowLayout(spacing: 6) {
                    metaChip(item.amountLabel, fill: Theme.neutral100, foreground: Theme.neutral700)
                    metaChip(
                        item.status.label,
                        fill: item.status == .open ? Theme.sage100 : Theme.neutral100,
                        foreground: item.status == .open ? Theme.sage800 : Theme.neutral700
                    )
                    if let expiry = item.expiryBadge {
                        metaChip(
                            expiry.label,
                            fill: expiry.fill,
                            foreground: expiry.foreground,
                            border: expiry.border
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !matchMode {
                Button {
                    pantry.deleteItem(id: item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.neutral500)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Remove \(item.name)"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .cardBackground(radius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            if matchMode {
                if selected {
                    matchSelectedIDs.remove(item.id)
                } else {
                    matchSelectedIDs.insert(item.id)
                }
            } else {
                editingItem = item
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.name)
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

    private var matchResultsCard: some View {
        let names = pantry.items
            .filter { matchSelectedIDs.contains($0.id) }
            .map(\.name)
        let results = matchingRecipes(from: recipes.recipes, selectedNames: names)

        return VStack(alignment: .leading, spacing: 10) {
            Text(L("\(names.count) selected · matching recipes"))
                .font(Theme.body(10.5, weight: .semibold))
                .tracking(1.26)
                .textCase(.uppercase)
                .foregroundStyle(Theme.sage800)

            if results.isEmpty {
                Text("No recipes use those ingredients yet.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.sage800.opacity(0.85))
            } else {
                ForEach(results) { match in
                    Button {
                        onOpenRecipe(match.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(match.title)
                                .font(Theme.display(14.5))
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text(match.line)
                                .font(Theme.body(11.5, weight: .semibold))
                                .foregroundStyle(Theme.sage800)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Theme.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sage100)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: - To buy

    private var toBuyToolbar: some View {
        HStack(spacing: 9) {
            TextField("Add something to buy…", text: $newToBuyText)
                .font(Theme.body(14))
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(Theme.surface)
                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                .clipShape(Capsule())
                .onSubmit(addToBuyFromField)

            Button(action: addToBuyFromField) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .frame(width: 46, height: 46)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Add to buy"))
        }
    }

    private func addToBuyFromField() {
        pantry.addToBuy(newToBuyText)
        newToBuyText = ""
    }

    @ViewBuilder
    private var toBuyContent: some View {
        if pantry.toBuy.isEmpty {
            Text("Your to-buy list is empty.")
                .font(Theme.body(14))
                .foregroundStyle(Theme.neutral600)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else if filteredToBuy.isEmpty {
            Text(buyFilterActive ? L("Nothing matches that yet.") : L("Your to-buy list is empty."))
                .font(Theme.body(14))
                .foregroundStyle(Theme.neutral600)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
        } else {
            ForEach(filteredToBuy) { item in
                HStack(spacing: 12) {
                    Button {
                        pantry.toggleChecked(id: item.id)
                    } label: {
                        Circle()
                            .strokeBorder(item.checked ? Theme.sage500 : Theme.neutral400, lineWidth: 2)
                            .background(Circle().fill(item.checked ? Theme.sage500 : .clear))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.checked ? L("Uncheck \(item.text)") : L("Check \(item.text)"))

                    Text(item.text)
                        .font(Theme.body(14.5))
                        .strikethrough(item.checked)
                        .foregroundStyle(item.checked ? Theme.neutral500 : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextField("qty", text: Binding(
                        get: { pantry.toBuy.first(where: { $0.id == item.id })?.qty ?? "" },
                        set: { pantry.setToBuyQty(id: item.id, qty: $0) }
                    ))
                    .font(Theme.body(12.5))
                    .multilineTextAlignment(.center)
                    .frame(width: 64, height: 34)
                    .background(Theme.bg)
                    .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                    .clipShape(Capsule())
                    .accessibilityLabel(L("Quantity for \(item.text)"))

                    Button {
                        pantry.removeToBuy(id: item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.neutral500)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Remove \(item.text)"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.bottom, 9)
            }
        }
    }
}

// MARK: - Expiry / amount helpers

extension PantryItem {
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
        guard let expiry, let date = Self.parseExpiry(expiry) else { return nil }
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
        formatter.locale = LanguageStore.shared.language.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return ExpiryBadge(
            label: formatter.string(from: date),
            fill: .clear,
            foreground: Theme.neutral600,
            border: Theme.divider
        )
    }

    static func parseExpiry(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    static func formatExpiry(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Match mode ranking

struct PantryRecipeMatch: Identifiable {
    let id: Int
    let title: String
    let hits: Int
    let total: Int

    var line: String { L("\(hits) of \(total) ingredients") }
}

/// Partial, best-effort match of selected pantry names against recipe
/// ingredient lines (stemmed words), independent of list-screen fit %.
func matchingRecipes(from recipes: [Recipe], selectedNames: [String], limit: Int = 4) -> [PantryRecipeMatch] {
    guard !selectedNames.isEmpty else { return [] }
    let selectedWordSets = selectedNames.map { matchWordSet(in: $0) }
    return recipes.compactMap { recipe -> PantryRecipeMatch? in
        let total = recipe.ingredients.count
        guard total > 0 else { return nil }
        let hits = recipe.ingredients.filter { line in
            let words = matchWordSet(in: line)
            if selectedWordSets.contains(where: { !$0.isDisjoint(with: words) }) {
                return true
            }
            return selectedNames.contains { namesMatch(collapsePantryName($0), collapsePantryName(line)) }
                || selectedNames.contains { name in recipe.pantry.contains { namesMatch($0, collapsePantryName(name)) } }
        }.count
        guard hits > 0 else { return nil }
        return PantryRecipeMatch(id: recipe.id, title: recipe.title, hits: hits, total: total)
    }
    .sorted { lhs, rhs in
        if lhs.hits != rhs.hits { return lhs.hits > rhs.hits }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
    .prefix(limit)
    .map { $0 }
}

private func matchWordSet(in text: String) -> Set<String> {
    let lowered = text.lowercased()
    var words: Set<String> = []
    var current = ""
    for scalar in lowered.unicodeScalars {
        if CharacterSet.letters.contains(scalar) {
            current.append(Character(scalar))
        } else if !current.isEmpty {
            if current.count >= 4 {
                words.insert(stem(current))
            }
            current = ""
        }
    }
    if current.count >= 4 {
        words.insert(stem(current))
    }
    return words
}

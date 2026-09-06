import SwiftUI
import UIKit

/// Deliberately split into one child view per section — header, search,
/// course filters, pantry banner, results — rather than one body assembled
/// from computed properties. SwiftUI tracks @Observable reads per view body,
/// so a section only re-renders when a property *it* reads changes: a
/// keystroke re-runs the search block and the results, but not the header or
/// the filter row. Built as computed properties on a single view, every read
/// would land in the same body and every keystroke would re-run all of it.
struct RecipeListView: View {
    @Environment(RecipeStore.self) private var store
    @State private var showFilters = false

    var onAdd: () -> Void = {}
    var onSettings: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ListHeader(onAdd: onAdd, onSettings: onSettings)
                SearchBlock(showFilters: $showFilters)
                CourseFilterRow()
                PantryBanner()
                ClearFiltersRow()
                ResultsSection(onAdd: onAdd)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showFilters) {
            FiltersSheet()
                .environment(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(Theme.radiusContainer)
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { store.actionError != nil },
                set: { shown in if !shown { store.actionError = nil } }
            ),
            presenting: store.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

// MARK: - Results

private struct ResultsSection: View {
    @Environment(RecipeStore.self) private var store

    let onAdd: () -> Void

    var body: some View {
        if store.isLoading, store.recipes.isEmpty {
            LoadingState()
        } else if let message = store.errorMessage, store.recipes.isEmpty {
            ErrorState(message: message)
        } else if store.recipes.isEmpty {
            EmptyState(onAdd: onAdd)
        } else if store.visibleRecipes.isEmpty {
            NoResultsState()
        } else if store.viewMode == .grid {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.cardGap), GridItem(.flexible())], spacing: Theme.cardGap) {
                ForEach(store.visibleRecipes) { recipe in
                    NavigationLink(value: recipe.id) {
                        RecipeCard(recipe: recipe, match: store.matchesByID[recipe.id], viewMode: .grid) {
                            Task { await store.toggleFavorite(recipe) }
                        }
                        .equatable()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 18)
            .padding(.bottom, 40)
        } else {
            LazyVStack(spacing: Theme.cardGap) {
                ForEach(store.visibleRecipes) { recipe in
                    NavigationLink(value: recipe.id) {
                        RecipeCard(recipe: recipe, match: store.matchesByID[recipe.id], viewMode: .list) {
                            Task { await store.toggleFavorite(recipe) }
                        }
                        .equatable()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Header

private struct ListHeader: View {
    @Environment(RecipeStore.self) private var store

    let onAdd: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Kicker(text: "\(L("\(store.recipes.count) recipes")) · \(L("\(favoriteCount) favorites"))")
                Text("Stocked")
                    .font(Theme.display(36))
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            HStack(spacing: 8) {
                CircleIconButton(lucide: .gear, action: onSettings)
                    .accessibilityLabel(L("Settings"))
                CircleIconButton(
                    lucide: .plus,
                    background: Theme.accent,
                    foreground: .white,
                    bordered: false,
                    action: onAdd
                )
                .themeShadow(Theme.shadowSM)
                .accessibilityLabel(L("Add recipe"))
            }
        }
        .padding(.top, 66)
        .padding(.horizontal, Theme.screenPadding)
        .background(alignment: .topTrailing) {
            DecorativeCircle(diameter: 210)
                .offset(x: 60, y: -70)
        }
        .clipShape(Rectangle())
    }

    private var favoriteCount: Int {
        store.recipes.filter(\.favorite).count
    }
}

// MARK: - Search

private struct SearchBlock: View {
    @Environment(RecipeStore.self) private var store

    @Binding var showFilters: Bool

    /// Ingredients aren't counted: they get their own visible row below, so
    /// counting them here would show a badge for something already on screen.
    private var activeFilterCount: Int {
        [
            !store.tagFilters.isEmpty, store.favoritesOnly,
            store.courseFilter != nil, !store.sourceFilters.isEmpty,
        ]
        .filter { $0 }.count
    }

    var body: some View {
        // @Bindable is what turns the environment's @Observable store back
        // into something that can hand out a Binding ($store.query below).
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    LucideIcon(.search, size: 17)
                        .foregroundStyle(Theme.neutral600)
                    DebouncedTextField(placeholder: L("Search recipes"), text: $store.query)
                        .font(Theme.body(14.5))
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .background(Theme.surface)
                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                .clipShape(Capsule())

                Button {
                    showFilters = true
                } label: {
                    LucideIcon(.sliders, size: 19)
                        .foregroundStyle(activeFilterCount > 0 ? .white : Theme.neutral800)
                        .frame(width: 46, height: 46)
                        .background(activeFilterCount > 0 ? Theme.accent : Theme.surface)
                        .overlay {
                            if activeFilterCount == 0 {
                                Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                            }
                        }
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Filters"))

                Button {
                    store.viewMode = store.viewMode == .grid ? .list : .grid
                } label: {
                    // Shows the glyph for the *other* mode — a grid icon
                    // while in list view (to switch to grid), a list icon
                    // while in grid view (to switch back).
                    LucideIcon(store.viewMode == .grid ? .list : .grid, size: 18)
                        .foregroundStyle(Theme.neutral800)
                        .frame(width: 46, height: 46)
                        .background(Theme.surface)
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Toggle grid or list view"))
            }

            let trimmed = store.query.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !store.visiblePantryGroups.isEmpty || store.canAddTypedPantryItem(trimmed) {
                pantrySuggestionRow(trimmed)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, Theme.screenPadding)
    }

    private func pantrySuggestionRow(_ trimmed: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: L("Filter by ingredient"), size: 10, color: Theme.neutral600)
            FlowLayout(spacing: 8) {
                ForEach(store.visiblePantryGroups.flatMap(\.items), id: \.self) { item in
                    Button {
                        store.toggleIngredient(item)
                    } label: {
                        Text("+ \(item)")
                            .font(Theme.body(12.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.sage100)
                            .foregroundStyle(Theme.sage800)
                            .overlay(
                                Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .foregroundStyle(Theme.sage400)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if store.canAddTypedPantryItem(trimmed) {
                    Button {
                        store.addHaveItem(trimmed)
                    } label: {
                        Text(L("+ Add “\(trimmed)”"))
                            .font(Theme.body(12.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.accent100)
                            .foregroundStyle(Theme.accent700)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Course filter

private struct CourseFilterRow: View {
    @Environment(RecipeStore.self) private var store

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(Course.allCases) { course in
                ChipButton(title: course.localizedName, selected: store.courseFilter == course) {
                    store.courseFilter = (store.courseFilter == course) ? nil : course
                }
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 14)
    }
}

// MARK: - Pantry banner

private struct PantryBanner: View {
    @Environment(RecipeStore.self) private var store

    /// The empty check lives here rather than in an `if` at the call site so
    /// that marking a pantry item re-renders this banner and the results,
    /// not the whole screen.
    var body: some View {
        if !store.have.isEmpty {
            banner
        }
    }

    /// Handoff-style sage pill: active ingredient filters + Clear.
    private var banner: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.sage500).frame(width: 8, height: 8)
            Text(L("Filtered by \(store.have.joined(separator: ", "))"))
                .font(Theme.body(12.5, weight: .semibold))
                .foregroundStyle(Theme.sage800)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Clear") { store.setHave([]) }
                .font(Theme.body(12.5, weight: .semibold))
                .foregroundStyle(Theme.sage800)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.sage100)
        .clipShape(Capsule())
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 14)
    }
}

// MARK: - Clear filters

/// One tap back to the full list from search, course, tags, favorites and
/// ingredients. Lives on the list because search and course are applied here,
/// not only inside the Filters sheet.
private struct ClearFiltersRow: View {
    @Environment(RecipeStore.self) private var store

    var body: some View {
        if store.hasActiveFilters {
            Button {
                store.clearFilters()
            } label: {
                HStack(spacing: 6) {
                    LucideIcon(.xmark, size: 10, stroke: 2.75)
                    Text("Clear all filters")
                        .font(Theme.body(12.5, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.accent100)
                .foregroundStyle(Theme.accent700)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 14)
        }
    }
}

// MARK: - Result states

private struct LoadingState: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text("Loading your recipes…")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.neutral700)
            }
            LazyVStack(spacing: Theme.cardGap) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonCard()
                }
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 28)
    }
}

private struct ErrorState: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Can't load recipes")
                .font(Theme.display(19))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(Theme.body(13.5))
                .foregroundStyle(Theme.neutral700)
            Text("Pull to retry. If it keeps failing, open Settings and confirm the server address.")
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.neutral600)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .cardBackground()
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 24)
    }
}

private struct NoResultsState: View {
    var body: some View {
        Text("No recipes match those filters yet.")
            .font(Theme.body(14))
            .foregroundStyle(Theme.neutral700)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 32)
    }
}

private struct EmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        ZStack {
            DecorativeCircle(color: Theme.accent200, diameter: 240, opacity: 0.6)
                .position(x: 340, y: 40)
            DecorativeCircle(color: Theme.sage300, diameter: 200, opacity: 0.6)
                .position(x: 10, y: 340)

            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 78, height: 78)
                    LucideIcon(.plus, size: 28)
                        .foregroundStyle(.white)
                }
                Text("Add your first recipe")
                    .font(Theme.display(34))
                    .foregroundStyle(Theme.ink)
                Text("Share a reel from Instagram, paste a link, snap a cookbook page, or write one down yourself.")
                    .font(Theme.body(14.5))
                    .foregroundStyle(Theme.neutral700)
                Button(action: onAdd) {
                    Text("Get started")
                        .font(Theme.display(16))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                        .themeShadow(Theme.shadowSM)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.screenPadding)
        }
        .padding(.top, 50)
        .frame(height: 420)
        .clipped()
    }
}

// MARK: - Recipe card

struct RecipeCard: View, Equatable {
    let recipe: Recipe
    var match: RecipeMatch?
    var viewMode: ViewMode = .list
    var onToggleFavorite: () -> Void = {}

    static func == (lhs: RecipeCard, rhs: RecipeCard) -> Bool {
        lhs.recipe.id == rhs.recipe.id
            && lhs.recipe.title == rhs.recipe.title
            && lhs.recipe.favorite == rhs.recipe.favorite
            && lhs.match?.label == rhs.match?.label
            && lhs.viewMode == rhs.viewMode
    }

    private var isGrid: Bool { viewMode == .grid }

    /// No time, no servings, no tags anywhere on the card (in either
    /// layout) — deliberately removed; tags still show on the detail
    /// screen. Grid mode additionally drops the source label, keeping the
    /// fit pill and favorite star.
    var body: some View {
        VStack(alignment: .leading, spacing: isGrid ? 8 : 10) {
            HStack(spacing: 8) {
                if !isGrid {
                    Text(recipe.sourceLabel.uppercased(with: Locale(identifier: "en")))
                        .font(Theme.body(10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.neutral600)
                }
                if let match {
                    let fit = match.score.formatted(
                        .percent.precision(.fractionLength(0)).locale(Locale(identifier: "en"))
                    )
                    Text("\(fit) \(L("FIT"))")
                        .font(Theme.body(10, weight: .semibold))
                        .tracking(0.4)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.sage500)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                Spacer()
                Button(action: onToggleFavorite) {
                    LucideIcon(.star, size: 18, stroke: 2.4, filled: recipe.favorite)
                        .foregroundStyle(recipe.favorite ? Theme.accent : Theme.neutral400)
                }
                .buttonStyle(.plain)
            }

            Text(recipe.title)
                .font(Theme.display(isGrid ? 16 : 21))
                .lineSpacing(3)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
        }
        .padding(
            isGrid
                ? EdgeInsets(top: 15, leading: 16, bottom: 14, trailing: 16)
                : EdgeInsets(top: 18, leading: 20, bottom: 17, trailing: 20)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: isGrid ? Theme.radiusCardGrid : Theme.radiusCard)
    }
}

struct SkeletonCard: View {
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 10) {
                bar(geo.size.width * 0.34)
                bar(geo.size.width * 0.7)
                bar(geo.size.width * 0.52)
            }
            .padding(18)
        }
        .frame(height: 96)
        .cardBackground()
        .opacity(pulse ? 0.85 : 0.45)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func bar(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.neutral300)
            .frame(width: max(width, 24), height: 14)
    }
}

// MARK: - Filters sheet

struct FiltersSheet: View {
    @Environment(RecipeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Reset") { store.clearFilters() }
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .disabled(!store.hasActiveFilters)
                    .opacity(store.hasActiveFilters ? 1 : 0.4)
                    .buttonStyle(.plain)

                Spacer()

                Button("Done") { dismiss() }
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.accent700)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    Text("Filters")
                        .font(Theme.display(30))
                        .foregroundStyle(Theme.ink)

                    if !store.have.isEmpty {
                        whatIHaveCard
                    }

                    Button {
                        store.favoritesOnly.toggle()
                    } label: {
                        HStack {
                            LucideIcon(.star, size: 16, stroke: 2.4, filled: store.favoritesOnly)
                            Text("Favorites only")
                            Spacer()
                        }
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(store.favoritesOnly ? Theme.accent : Theme.neutral800)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 10) {
                        Kicker(text: L("Sort"), color: Theme.neutral600)
                        HStack(spacing: 7) {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                ChipButton(title: option.localizedName, selected: store.sortOption == option, fillsWidth: true) {
                                    store.sortOption = option
                                }
                            }
                        }
                        if !store.have.isEmpty {
                            Text("Ignored while ingredient filters are active — closest fit comes first then.")
                                .font(Theme.body(11.5))
                                .foregroundStyle(Theme.neutral600)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Kicker(text: L("Source"), color: Theme.neutral600)
                        FlowLayout(spacing: 8) {
                            ForEach(SourceCategory.allCases) { category in
                                ChipButton(title: category.localizedName, selected: store.sourceFilters.contains(category)) {
                                    if store.sourceFilters.contains(category) {
                                        store.sourceFilters.remove(category)
                                    } else {
                                        store.sourceFilters.insert(category)
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }

                    if !store.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Kicker(text: L("Tags"), color: Theme.neutral600)
                            FlowLayout(spacing: 8) {
                                ForEach(store.tags, id: \.self) { tag in
                                    ChipButton(title: localizedRecipeTag(tag), selected: store.tagFilters.contains(tag)) {
                                        if store.tagFilters.contains(tag) {
                                            store.tagFilters.remove(tag)
                                        } else {
                                            store.tagFilters.insert(tag)
                                        }
                                    }
                                    .fixedSize()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 32)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var whatIHaveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(text: L("Ingredients"), color: Theme.sage800)
            if store.selectedPantryGroups.isEmpty {
                Text("No ingredients selected.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.sage800)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(store.selectedPantryGroups.flatMap(\.items), id: \.self) { item in
                        Button {
                            store.toggleIngredient(item)
                        } label: {
                            Text("\(item) ×")
                                .font(Theme.body(12.5, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.sage500)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Shows recipes that use all of these, ranked by fit. Type an ingredient in search to add one.")
                .font(Theme.body(11.5))
                .foregroundStyle(Theme.sage800.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.sage100)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }
}

// MARK: - Add options sheet

/// Bottom sheet presented from the header's + button.
struct AddOptionsSheet: View {
    var onLink: () -> Void
    var onPhoto: () -> Void
    var onLibrary: () -> Void
    var onTyped: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(Theme.neutral400)
                .frame(width: 44, height: 5)
                .padding(.top, 10)

            Text("Add a recipe")
                .font(Theme.display(24))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                row(icon: "link", title: L("Paste a link"), subtitle: L("Reel, video, or recipe page"), action: onLink)
                if CameraPicker.isAvailable {
                    row(icon: "camera", title: L("Take a photo"), subtitle: L("Cookbook page or recipe card"), action: onPhoto)
                }
                row(icon: "photo.on.rectangle", title: L("Choose from library"), subtitle: L("A screenshot you already saved"), action: onLibrary)
                row(icon: "keyboard", title: L("Type it in"), subtitle: L("Write it down yourself"), action: onTyped)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 22, bottom: 40, trailing: 22))
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .clipShape(.rect(topLeadingRadius: 34, topTrailingRadius: 34))
    }

    private func row(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.accent200).frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent800)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.display(16))
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.neutral700)
                }
                Spacer()
            }
            .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared controls

struct DebouncedTextField: View {
    let placeholder: String
    @Binding var text: String
    var delay: Duration = .milliseconds(160)

    @State private var draft = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        TextField(placeholder, text: $draft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onAppear { draft = text }
            .onChange(of: text) { _, new in
                if new != draft { draft = new }
            }
            .onChange(of: draft) { _, new in
                task?.cancel()
                task = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    if text != new {
                        text = new
                    }
                }
            }
    }
}

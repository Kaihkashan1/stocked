import PhotosUI
import SwiftUI

/// Everything presentable from the Recipes screen, as one item so there's
/// exactly one `.sheet()` modifier on RootView. Chaining several separate
/// `.sheet(isPresented:)` modifiers on the same view is unreliable in
/// SwiftUI — a later one can render without ever accepting touches while an
/// earlier one is still torn down — and that's exactly what happened here
/// during testing. `.sheet(item:)` switching between non-nil cases doesn't
/// have that problem; only handing off to a *different* presentation kind
/// (the camera's fullScreenCover, PhotosPicker's own sheet) still needs the
/// dismiss-then-onDismiss handoff below.
private enum ActiveSheet: Identifiable, Equatable {
    case addOptions
    case settings
    case addRecipe
    case pasteLink

    var id: Int {
        switch self {
        case .addOptions: 0
        case .settings: 1
        case .addRecipe: 2
        case .pasteLink: 3
        }
    }
}

private enum PendingAddAction {
    case photo, library
}

private enum AppTab: Hashable {
    case recipes
    case pantry
}

struct RootView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(PantryStore.self) private var pantryStore
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .recipes
    @State private var activeSheet: ActiveSheet?
    @State private var addRecipePrefill: RecipeExtraction?
    /// What to do once `activeSheet` has actually finished dismissing —
    /// only needed for handoffs to a different presentation kind (camera,
    /// photo library) than the ones `.sheet(item:)` covers. See the
    /// ActiveSheet doc comment above.
    @State private var pendingAddAction: PendingAddAction?
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var extracting = false
    @State private var photoOverlayDismissed = false
    @State private var photoJobID: UUID?
    @State private var extractError: String?
    @State private var recipesPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            recipesTab
                .tabItem {
                    Label("Cookbook", systemImage: "book")
                }
                .tag(AppTab.recipes)

            pantryTab
                .tabItem {
                    Label("Cupboard", systemImage: "cabinet")
                }
                .tag(AppTab.pantry)
        }
        .tint(Theme.accent)
        .toolbarBackground(Theme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if connectivity.isOffline {
                    OfflineBanner()
                }
                if let job = importBannerJob {
                    importBanner(job)
                }
            }
        }
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Theme.surface)
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
            UITabBar.appearance().unselectedItemTintColor = UIColor(Theme.neutral500)
            handle(store.pendingRoute)
        }
        .sheet(item: $activeSheet, onDismiss: performPendingAddAction) { sheet in
            // Presentation modifiers (detents etc.) are applied ONCE, here,
            // uniformly on the composed content — not per-branch inside the
            // switch. Per-branch presentationDetents (a different value in
            // each case of the switch) left every one of these sheets
            // visually correct but completely untappable during testing;
            // applying them outside the switch is what actually fixed it.
            sheetContent(for: sheet)
                .presentationDetents(detents(for: sheet))
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(sheet == .addOptions ? 34 : nil)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                extractPhoto(image)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    extractPhoto(image)
                }
                photoPickerItem = nil
            }
        }
        .overlay {
            if extracting && !photoOverlayDismissed {
                ZStack {
                    Theme.neutral900.opacity(0.42).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("Reading the recipe…")
                            .font(Theme.body(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("You can close this. Import continues in the background.")
                            .font(Theme.body(12.5))
                            .foregroundStyle(Theme.neutral700)
                            .multilineTextAlignment(.center)
                        Button("Close") {
                            photoOverlayDismissed = true
                            extracting = false
                        }
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(Theme.accent700)
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Close"))
                    }
                    .padding(24)
                    .frame(maxWidth: 320)
                    .cardBackground(radius: 20)
                }
            }
        }
        .alert(
            "Couldn't read that photo",
            isPresented: Binding(
                get: { extractError != nil },
                set: { shown in if !shown { extractError = nil } }
            ),
            presenting: extractError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .task {
            await refreshCatalog(force: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Always hit the server when coming back — a Shortcut or web
            // save while this app was in the background is otherwise easy
            // to miss. In-flight work is coalesced in RecipeStore.refresh
            // (so this does not double the launch `.task`).
            Task { await refreshCatalog(force: true) }
        }
        .onChange(of: connectivity.isOnline) { wasOnline, isOnline in
            guard isOnline, !wasOnline else { return }
            Task { await refreshCatalog(force: true) }
        }
        .onChange(of: store.pendingRoute) { _, route in
            handle(route)
        }
        .onChange(of: photoImportStatus) { _, _ in
            handlePhotoImportUpdate()
        }
    }

    private var photoImportStatus: BackgroundImportJob.Status? {
        guard let photoJobID else { return nil }
        return store.importJobs.first(where: { $0.id == photoJobID })?.status
    }

    private var importBannerJob: BackgroundImportJob? {
        store.importJobs.last { job in
            if store.dismissedImportBannerIDs.contains(job.id) { return false }
            switch job.kind {
            case .link:
                if activeSheet == .pasteLink { return false }
            case .photo:
                if extracting && !photoOverlayDismissed { return false }
                if activeSheet == .addRecipe, case .photoReady = job.status { return false }
            }
            return true
        }
    }

    private func importBanner(_ job: BackgroundImportJob) -> some View {
        HStack(alignment: .center, spacing: 10) {
            bannerIcon(for: job.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle(for: job))
                    .font(Theme.body(12.5, weight: .semibold))
                if let detail = bannerDetail(for: job) {
                    Text(detail)
                        .font(Theme.body(11.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.dismissImportBanner(id: job.id)
            } label: {
                LucideIcon(.xmark, size: 11)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Close"))
        }
        .foregroundStyle(isFailedImport(job) ? Theme.accent800 : Theme.sage800)
        .padding(.vertical, 10)
        .padding(.horizontal, Theme.screenPadding)
        .background(isFailedImport(job) ? Theme.accent100 : Theme.sage100)
        .contentShape(Rectangle())
        .onTapGesture { handleBannerTap(job) }
    }

    private func isFailedImport(_ job: BackgroundImportJob) -> Bool {
        if case .failed = job.status { return true }
        return false
    }

    @ViewBuilder
    private func bannerIcon(for status: BackgroundImportJob.Status) -> some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(Theme.sage800)
        case .saved, .photoReady:
            LucideIcon(.check, size: 12)
        case .failed:
            LucideIcon(.xmark, size: 12)
        }
    }

    private func bannerTitle(for job: BackgroundImportJob) -> String {
        switch job.status {
        case .running:
            L("Importing in the background…")
        case .saved(_, let title):
            title.isEmpty ? L("Saved to your box") : title
        case .photoReady:
            L("Recipe ready to review")
        case .failed:
            L("Couldn't import that recipe")
        }
    }

    private func bannerDetail(for job: BackgroundImportJob) -> String? {
        switch job.status {
        case .running:
            L("You can keep using the app.")
        case .saved:
            L("Saved to your box")
        case .photoReady:
            L("Tap to check it over before it goes in the box.")
        case .failed(let message):
            message
        }
    }

    private func handleBannerTap(_ job: BackgroundImportJob) {
        switch job.status {
        case .running:
            break
        case .saved(let recipeID, _):
            store.consumeImportJob(id: job.id)
            selectedTab = .recipes
            recipesPath = NavigationPath()
            recipesPath.append(recipeID)
        case .photoReady(let extraction):
            store.consumeImportJob(id: job.id)
            addRecipePrefill = extraction
            activeSheet = .addRecipe
        case .failed:
            store.dismissImportBanner(id: job.id)
        }
    }

    private func handlePhotoImportUpdate() {
        guard let photoJobID, let job = store.importJobs.first(where: { $0.id == photoJobID }) else { return }
        switch job.status {
        case .running:
            break
        case .photoReady(let extraction):
            extracting = false
            guard !photoOverlayDismissed else { return }
            addRecipePrefill = extraction
            activeSheet = .addRecipe
            store.consumeImportJob(id: job.id)
        case .failed(let message):
            extracting = false
            guard !photoOverlayDismissed else { return }
            extractError = message
            store.consumeImportJob(id: job.id)
        case .saved:
            extracting = false
        }
    }

    /// First paint, returning from the background, and coming back online
    /// all fetch. `refresh` coalesces overlapping calls so launch `.task`
    /// plus the first `.active` ping share one request.
    private func refreshCatalog(force: Bool) async {
        async let recipes = store.refresh(force: force)
        async let pantry = pantryStore.refresh(force: force)
        _ = await (recipes, pantry)
    }

    private var recipesTab: some View {
        NavigationStack(path: $recipesPath) {
            RecipeListView(
                onAdd: { activeSheet = .addOptions },
                onSettings: { activeSheet = .settings }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Int.self) { id in
                RecipeDetailView(id: id)
            }
        }
    }

    private var pantryTab: some View {
        NavigationStack {
            PantryView(onOpenRecipe: { id in
                selectedTab = .recipes
                recipesPath = NavigationPath()
                recipesPath.append(id)
            })
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .addOptions:
            AddOptionsSheet(
                onLink: { activeSheet = .pasteLink },
                onPhoto: { pendingAddAction = .photo; activeSheet = nil },
                onLibrary: { pendingAddAction = .library; activeSheet = nil },
                onTyped: {
                    addRecipePrefill = nil
                    activeSheet = .addRecipe
                }
            )
        case .settings:
            SettingsView()
                .environment(store)
                .environment(pantryStore)
        case .addRecipe:
            AddRecipeView(prefill: addRecipePrefill)
                .environment(store)
        case .pasteLink:
            PasteALinkView(onOpenRecipe: { id in
                activeSheet = nil
                selectedTab = .recipes
                recipesPath = NavigationPath()
                recipesPath.append(id)
            })
            .environment(store)
        }
    }

    private func detents(for sheet: ActiveSheet) -> Set<PresentationDetent> {
        switch sheet {
        case .addOptions: [.height(CameraPicker.isAvailable ? 428 : 360)]
        case .settings, .addRecipe, .pasteLink: [.large]
        }
    }

    private func performPendingAddAction() {
        guard let action = pendingAddAction else { return }
        pendingAddAction = nil
        switch action {
        case .photo:
            showCamera = true
        case .library:
            photoPickerItem = nil
            showPhotoPicker = true
        }
    }

    private func extractPhoto(_ image: UIImage) {
        // Show the spinner immediately — the resize + JPEG encode below used
        // to run synchronously on the main thread before this state change
        // ever got a chance to render, so tapping camera/library visibly
        // hung for a beat with no feedback at all.
        extracting = true
        photoOverlayDismissed = false
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                image.recipePhotoJPEGData()
            }.value
            guard let data else {
                extracting = false
                extractError = L("Could not process that photo.")
                return
            }
            photoJobID = store.startPhotoImport(data)
        }
    }

    private func handle(_ route: DeepLinkRoute?) {
        guard let route else { return }
        switch route {
        case .pantry:
            selectedTab = .pantry
            recipesPath = NavigationPath()
        case .have(let items):
            selectedTab = .recipes
            recipesPath = NavigationPath()
            store.setHave(items)
        case .surprise:
            selectedTab = .recipes
            if let recipe = store.recipes.randomElement() {
                recipesPath = NavigationPath()
                recipesPath.append(recipe.id)
            }
        }
        store.pendingRoute = nil
    }
}

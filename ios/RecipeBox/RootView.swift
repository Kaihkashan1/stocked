import PhotosUI
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: RecipeStore
    @State private var showSettings = false
    @State private var showAddRecipe = false
    @State private var addRecipePrefill: RecipeExtraction?
    @State private var showAddOptions = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var extracting = false
    @State private var extractError: String?
    @State private var selectedTab = 0
    @State private var recipesPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $recipesPath) {
                RecipeListView()
                    .navigationTitle("Recipe Box")
                    .toolbar { addButton }
                    .toolbar { settingsButton }
            }
            .tabItem { Label("Recipes", systemImage: "book.closed") }
            .tag(0)

            NavigationStack {
                PantryView()
                    .navigationTitle("Pantry")
                    .toolbar { settingsButton }
            }
            .tabItem { Label("Pantry", systemImage: "basket") }
            .badge(store.have.isEmpty ? nil : "\(store.have.count)")
            .tag(1)
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showAddRecipe) {
            AddRecipeView(prefill: addRecipePrefill)
                .environmentObject(store)
        }
        .confirmationDialog("Add Recipe", isPresented: $showAddOptions, titleVisibility: .hidden) {
            Button("Type it in") {
                addRecipePrefill = nil
                showAddRecipe = true
            }
            if CameraPicker.isAvailable {
                Button("Take Photo") { showCamera = true }
            }
            Button("Choose from Library") {
                photoPickerItem = nil
                showPhotoPicker = true
            }
            Button("Cancel", role: .cancel) {}
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
            if extracting {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Reading the recipe…")
                            .font(Theme.mono(13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .task { await store.refresh() }
        .onChange(of: store.pendingRoute) { _, route in
            handle(route)
        }
    }

    private var addButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAddOptions = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add recipe")
        }
    }

    private func extractPhoto(_ image: UIImage) {
        guard let data = image.recipePhotoJPEGData() else {
            extractError = "Could not process that photo."
            return
        }
        extracting = true
        Task {
            let (extraction, error) = await store.extractRecipePhoto(data)
            extracting = false
            if let extraction {
                addRecipePrefill = extraction
                showAddRecipe = true
            } else {
                extractError = error ?? "Something went wrong."
            }
        }
    }

    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Server settings")
        }
    }

    private func handle(_ route: DeepLinkRoute?) {
        guard let route else { return }
        switch route {
        case .pantry:
            selectedTab = 1
        case .have(let items):
            selectedTab = 0
            recipesPath = NavigationPath()
            store.setHave(items)
        case .surprise:
            selectedTab = 0
            if let recipe = store.recipes.randomElement() {
                recipesPath = NavigationPath()
                recipesPath.append(recipe.id)
            }
        }
        store.pendingRoute = nil
    }
}

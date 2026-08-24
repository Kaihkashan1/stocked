import SwiftUI

/// Full-screen form for typing a recipe in by hand — no Instagram link, no
/// Gemini extraction, just title/ingredients/steps like EditRecipeView, plus
/// the categorization fields Gemini would normally fill in (meal, time,
/// tags) since nothing else will set them for a manual entry. Cuisine isn't
/// shown here — it's not used anywhere in the app anymore — but a photo
/// extraction's own guess still rides along silently if there is one.
struct AddRecipeView: View {
    @EnvironmentObject private var store: RecipeStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var servings: String
    @State private var ingredientsText: String
    @State private var stepsText: String
    @State private var cuisine: String
    @State private var meal: String
    @State private var time: String
    @State private var selectedTags: Set<String>
    @State private var newTag = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var errorMessage: String?

    private static let meals = [
        ("breakfast", "Breakfast"),
        ("lunch", "Lunch"),
        ("dinner", "Dinner"),
        ("snack", "Snack"),
        ("dessert", "Dessert"),
        ("drink", "Drink"),
        ("other", "Other"),
    ]

    /// `prefill` comes from a photo extraction (POST /api/extract-photo) —
    /// nothing is saved until Save is tapped, same as typing it in by hand.
    init(prefill: RecipeExtraction? = nil) {
        _title = State(initialValue: prefill?.title ?? "")
        _servings = State(initialValue: prefill?.servings ?? "")
        _ingredientsText = State(initialValue: (prefill?.ingredients ?? []).joined(separator: "\n"))
        _stepsText = State(initialValue: (prefill?.steps ?? []).joined(separator: "\n"))
        _cuisine = State(initialValue: prefill?.cuisine ?? "")
        _meal = State(initialValue: prefill?.meal ?? "other")
        _time = State(initialValue: prefill?.time ?? "")
        _selectedTags = State(initialValue: Set(prefill?.tags ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("Servings") {
                    TextField("e.g. 4", text: $servings)
                }
                Section {
                    TextEditor(text: $ingredientsText)
                        .frame(minHeight: 160)
                        .font(.callout)
                } header: {
                    Text("Ingredients")
                } footer: {
                    Text("One ingredient per line.")
                }
                Section {
                    TextEditor(text: $stepsText)
                        .frame(minHeight: 200)
                        .font(.callout)
                } header: {
                    Text("Steps")
                } footer: {
                    Text("One step per line, in order.")
                }
                Section("Meal") {
                    Picker("Meal", selection: $meal) {
                        ForEach(Self.meals, id: \.0) { key, label in
                            Text(label).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("Time") {
                    TextField("e.g. 20 min", text: $time)
                }
                Section {
                    FilterWrap(items: recipeTags, selected: selectedTags) { tag in
                        toggleTag(tag)
                    }
                    let custom = selectedTags.subtracting(recipeTags).sorted()
                    if !custom.isEmpty {
                        FilterWrap(items: custom, selected: selectedTags) { tag in
                            toggleTag(tag)
                        }
                    }
                    HStack {
                        TextField("Add a custom tag", text: $newTag)
                            .textInputAutocapitalization(.never)
                            .onSubmit(addCustomTag)
                        Button("Add", action: addCustomTag)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Tap a preset above, or type your own.")
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                        .font(.callout)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        saving = true
        errorMessage = nil
        defer { saving = false }

        let trimmedServings = servings.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTime = time.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = RecipeCreate(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            servings: trimmedServings.isEmpty ? nil : trimmedServings,
            ingredients: lines(from: ingredientsText),
            steps: lines(from: stepsText),
            cuisine: cuisine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Uncategorized" : cuisine.trimmingCharacters(in: .whitespacesAndNewlines),
            meal: meal,
            time: trimmedTime.isEmpty ? nil : trimmedTime,
            tags: Array(selectedTags),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let failure = await store.addRecipe(draft) {
            errorMessage = failure
        } else {
            dismiss()
        }
    }

    private func lines(from text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    private func addCustomTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        selectedTags.insert(trimmed)
        newTag = ""
    }
}

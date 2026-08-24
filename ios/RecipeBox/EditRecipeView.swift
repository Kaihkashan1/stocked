import SwiftUI

/// Full-screen edit form for a saved recipe. Ingredients/steps are edited as
/// plain multi-line text (one item per line) — the server re-parses lines the
/// same way it formats them on save, so the round trip is lossless.
struct EditRecipeView: View {
    @EnvironmentObject private var store: RecipeStore
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    @State private var title: String
    @State private var servings: String
    @State private var ingredientsText: String
    @State private var stepsText: String
    @State private var notes: String
    @State private var tagsText: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(recipe: Recipe) {
        self.recipe = recipe
        _title = State(initialValue: recipe.title)
        _servings = State(initialValue: recipe.servings ?? "")
        _ingredientsText = State(initialValue: recipe.ingredients.joined(separator: "\n"))
        _stepsText = State(initialValue: recipe.steps.joined(separator: "\n"))
        _notes = State(initialValue: recipe.notes)
        _tagsText = State(initialValue: recipe.tags.joined(separator: ", "))
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
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                        .font(.callout)
                }
                Section {
                    TextField("quick, vegetarian, mom's recipes", text: $tagsText)
                    if !store.tags.isEmpty {
                        FilterWrap(items: store.tags, selected: Set(currentTags)) { picked in
                            toggleTag(picked)
                        }
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Any category — diet, course, source, appliance. Tap to add or remove.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Recipe")
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
        let failure = await store.saveEdits(
            id: recipe.id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            servings: trimmedServings.isEmpty ? nil : trimmedServings,
            ingredients: lines(from: ingredientsText),
            steps: lines(from: stepsText),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: currentTags
        )
        if let failure {
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

    private var currentTags: [String] {
        tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func toggleTag(_ tag: String) {
        var tags = currentTags
        if let index = tags.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        tagsText = tags.joined(separator: ", ")
    }
}

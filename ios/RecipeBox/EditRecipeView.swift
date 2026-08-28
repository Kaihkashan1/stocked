import SwiftUI

/// Full-screen edit form for a saved recipe. Ingredients/steps are edited as
/// plain multi-line text (one item per line) — the server re-parses lines the
/// same way it formats them on save, so the round trip is lossless.
struct EditRecipeView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    @State private var title: String
    @State private var ingredientsText: String
    @State private var stepsText: String
    @State private var notes: String
    @State private var selectedTags: Set<String>
    @State private var course: Course
    @State private var saving = false
    @State private var errorMessage: String?

    init(recipe: Recipe) {
        self.recipe = recipe
        _title = State(initialValue: recipe.title)
        _ingredientsText = State(initialValue: recipe.ingredients.joined(separator: "\n"))
        _stepsText = State(initialValue: recipe.steps.joined(separator: "\n"))
        _notes = State(initialValue: recipe.notes)
        _selectedTags = State(initialValue: Set(recipe.tags))
        _course = State(initialValue: recipe.course)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(kicker: "Title") {
                        TextField("Title", text: $title)
                            .font(Theme.display(17))
                            .padding(.horizontal, 18)
                            .frame(height: 50)
                            .background(Theme.surface)
                            .clipShape(Capsule())
                    }

                    field(kicker: "Ingredients", hint: "one per line") {
                        TextEditor(text: $ingredientsText)
                            .font(Theme.body(14.5))
                            .lineSpacing(14.5 * 0.9)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 120)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }

                    field(kicker: "Steps", hint: "one per line, in order") {
                        TextEditor(text: $stepsText)
                            .font(Theme.body(14.5))
                            .lineSpacing(14.5 * 0.55)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 130)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }

                    field(kicker: "Course") {
                        HStack(spacing: 7) {
                            ForEach(Course.allCases) { option in
                                ChipButton(title: option.rawValue, selected: course == option) {
                                    course = option
                                }
                            }
                        }
                    }

                    field(kicker: "Notes") {
                        TextEditor(text: $notes)
                            .font(Theme.body(14))
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 80)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }

                    field(kicker: "Tags") {
                        FlowLayout(spacing: 8) {
                            ForEach(recipeTags, id: \.self) { tag in
                                ChipButton(title: tag, selected: selectedTags.contains(tag)) {
                                    toggleTag(tag)
                                }
                                .fixedSize()
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.body(12.5))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 40)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.neutral700)
            Spacer()
            Text("Edit recipe")
                .font(Theme.display(20))
                .foregroundStyle(Theme.ink)
            Spacer()
            Button(saving ? "Saving…" : "Save") {
                Task { await save() }
            }
            .font(Theme.body(14, weight: .bold))
            .foregroundStyle(Theme.accent700)
            .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 16)
    }

    private func field<Content: View>(kicker: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: kicker, color: Theme.neutral600)
            content()
            if let hint {
                Text(hint)
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.neutral600)
            }
        }
    }

    private func save() async {
        saving = true
        errorMessage = nil
        defer { saving = false }

        let failure = await store.saveEdits(
            id: recipe.id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredients: lines(from: ingredientsText),
            steps: lines(from: stepsText),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: Array(selectedTags),
            course: course
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

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }
}

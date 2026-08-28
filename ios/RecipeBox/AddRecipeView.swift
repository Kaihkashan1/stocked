import SwiftUI

/// Full-screen form for typing a recipe in by hand, or reviewing a photo
/// extraction before it's saved. Servings, time and a free meal picker are
/// gone on purpose — Course and Tags are the only classifications this form
/// collects, so anything created here is reachable from every filter on the
/// list screen. Cuisine isn't collected either: a photo extraction still
/// produces one, but nothing downstream reads or stores it anymore.
struct AddRecipeView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let prefill: RecipeExtraction?

    @State private var title: String
    @State private var ingredientsText: String
    @State private var stepsText: String
    @State private var course: Course
    @State private var selectedTags: Set<String>
    @State private var saving = false
    @State private var errorMessage: String?

    /// `prefill` comes from a photo extraction (POST /api/extract-photo) —
    /// nothing is saved until Save is tapped, same as typing it in by hand.
    init(prefill: RecipeExtraction? = nil) {
        self.prefill = prefill
        _title = State(initialValue: prefill?.title ?? "")
        _ingredientsText = State(initialValue: (prefill?.ingredients ?? []).joined(separator: "\n"))
        _stepsText = State(initialValue: (prefill?.steps ?? []).joined(separator: "\n"))
        _course = State(initialValue: Course(meal: prefill?.meal ?? "other"))
        _selectedTags = State(initialValue: Set(prefill?.tags ?? []))
    }

    private var isFromPhoto: Bool { prefill != nil }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let prefill {
                        confidencePill(prefill)
                    }

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

                    Text("Source is set automatically — this one files under **\(isFromPhoto ? "Photo" : "Typed in")** in Filters.")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.neutral600)

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
            Text(isFromPhoto ? "From a photo" : "Type it in")
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

    private func confidencePill(_ prefill: RecipeExtraction) -> some View {
        Text("Read \(prefill.ingredients.count) ingredients and \(prefill.steps.count) steps. Confidence: \(prefill.confidence).")
            .font(Theme.body(13))
            .foregroundStyle(Theme.sage800)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sage100)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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

        let draft = RecipeCreate(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredients: lines(from: ingredientsText),
            steps: lines(from: stepsText),
            course: course.rawValue,
            tags: Array(selectedTags),
            notes: ""
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
}

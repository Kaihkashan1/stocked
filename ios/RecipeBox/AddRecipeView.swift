import SwiftUI

/// Full-screen form for typing a recipe in by hand, or reviewing a photo
/// extraction before it's saved. Servings, time and a free meal picker are
/// gone on purpose — Course and Tags are the only classifications this form
/// collects, so anything created here is reachable from every filter on the
/// list screen.
struct AddRecipeView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let prefill: RecipeExtraction?

    @State private var title: String
    @State private var ingredientsText: String
    @State private var stepsText: String
    @State private var stepLines: [String]
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
        let steps = prefill?.steps ?? []
        _stepsText = State(initialValue: steps.joined(separator: "\n"))
        _stepLines = State(initialValue: steps.isEmpty ? [""] : steps)
        _course = State(initialValue: Course(meal: prefill?.meal ?? "other"))
        _selectedTags = State(initialValue: Set(prefill?.tags ?? []))
    }

    private var isFromPhoto: Bool { prefill != nil }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isFromPhoto ? L("From a photo") : L("Type it in"))
                            .font(Theme.display(30))
                            .foregroundStyle(Theme.ink)
                        if isFromPhoto {
                            Text("Check what we read off the page before it goes in the box.")
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.neutral700)
                        }
                    }

                    if let prefill {
                        confidencePill(prefill)
                    }

                    field(kicker: L("Title")) {
                        TextField("Title", text: $title)
                            .font(Theme.display(17))
                            .padding(.horizontal, 18)
                            .frame(height: 50)
                            .background(Theme.surface)
                            .clipShape(Capsule())
                    }

                    field(kicker: L("Ingredients"), hint: isFromPhoto ? nil : L("one per line")) {
                        TextEditor(text: $ingredientsText)
                            .font(Theme.body(14.5))
                            .lineSpacing(14.5 * 0.9)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 120)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }

                    if isFromPhoto {
                        photoStepsField
                    } else {
                        field(kicker: L("Steps"), hint: L("one per line, in order")) {
                            TextEditor(text: $stepsText)
                                .font(Theme.body(14.5))
                                .lineSpacing(14.5 * 0.55)
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .frame(minHeight: 130)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        }
                    }

                    field(kicker: L("Course")) {
                        HStack(spacing: 7) {
                            ForEach(Course.allCases) { option in
                                ChipButton(title: option.localizedName, selected: course == option) {
                                    course = option
                                }
                            }
                        }
                    }

                    field(kicker: L("Tags")) {
                        TagPicker(selected: $selectedTags, extraTags: store.tags)
                    }

                    Text(L("Source is set automatically — this one files under **\(isFromPhoto ? L("Photo") : L("Typed in"))** in Filters."))
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

    /// Numbered, editable step rows for photo review (handoff §5).
    private var photoStepsField: some View {
        field(kicker: L("Steps")) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(stepLines.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 12) {
                        StepNumberBadge(number: index + 1, size: 22, fontSize: 12, topOffset: 1)

                        TextField(L("Step \(index + 1)"), text: $stepLines[index], axis: .vertical)
                            .font(Theme.body(14))
                            .lineLimit(2...8)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.neutral700)
            Spacer()
            Button(saving ? L("Saving…") : L("Save")) {
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
        Text(L("Read \(prefill.ingredients.count) ingredients and \(prefill.steps.count) steps. Confidence: \(L(String.LocalizationValue(prefill.confidence)))."))
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

        let steps: [String]
        if isFromPhoto {
            steps = stepLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            steps = lines(from: stepsText)
        }

        let draft = RecipeCreate(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredients: lines(from: ingredientsText),
            steps: steps,
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
}

import PhotosUI
import SwiftUI
import UIKit

/// Full-screen edit form for a saved recipe. Field order and the
/// `qty | item` ingredient lines match the handoff edit sheet.
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
    @State private var replacementJPEG: Data?
    @State private var removeExistingPhoto = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?

    init(recipe: Recipe) {
        self.recipe = recipe
        _title = State(initialValue: recipe.title)
        _ingredientsText = State(initialValue: recipe.ingredients.map(formatIngredientForEdit).joined(separator: "\n"))
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
                    field(kicker: L("Title")) {
                        TextField("Title", text: $title)
                            .font(Theme.display(17))
                            .padding(.horizontal, 18)
                            .frame(height: 50)
                            .background(Theme.surface)
                            .clipShape(Capsule())
                    }

                    field(kicker: L("Course")) {
                        FlowLayout(spacing: 7) {
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

                    field(kicker: L("Ingredients"), hint: L("qty | item, or \"## Section\" for parts")) {
                        TextEditor(text: $ingredientsText)
                            .font(Theme.body(14.5))
                            .lineSpacing(14.5 * 0.9)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 120)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }

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

                    field(kicker: L("Notes")) {
                        TextEditor(text: $notes)
                            .font(Theme.body(14))
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 80)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }

                    field(kicker: L("Photo")) {
                        photoEditor
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { _, item in
            guard let item else { return }
            Task {
                defer { photoPickerItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let jpeg = image.recipePhotoJPEGData()
                else { return }
                replacementJPEG = jpeg
                removeExistingPhoto = false
            }
        }
    }

    @ViewBuilder
    private var photoEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let replacementJPEG, let preview = UIImage(data: replacementJPEG) {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else if let url = recipe.resolvedPhotoURL(baseURLString: store.serverURL), !removeExistingPhoto {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    default:
                        Theme.neutral200
                            .frame(height: 120)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }

            HStack(spacing: 8) {
                Button(showsPhoto ? L("Replace photo") : L("Add photo")) {
                    showPhotoPicker = true
                }
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.accent700)
                if showsPhoto {
                    Button(L("Remove photo")) {
                        replacementJPEG = nil
                        removeExistingPhoto = true
                    }
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.accent800)
                }
            }
        }
    }

    private var showsPhoto: Bool {
        replacementJPEG != nil || (recipe.photoURL != nil && !recipe.photoURL!.isEmpty && !removeExistingPhoto)
    }

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.neutral700)
            Spacer()
            Text("Edit recipe")
                .font(Theme.display(22))
                .foregroundStyle(Theme.ink)
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
            ingredients: lines(from: ingredientsText).map(parseIngredientFromEdit),
            steps: lines(from: stepsText),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: Array(selectedTags),
            course: course,
            photoJPEG: replacementJPEG,
            clearPhoto: removeExistingPhoto && replacementJPEG == nil
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
}

/// Formats a stored ingredient line for the edit sheet's `qty | item` rows.
func formatIngredientForEdit(_ line: String) -> String {
    let parsed = splitIngredientSection(line)
    if let section = parsed.section, parsed.item == nil {
        return "## \(section)"
    }
    let qtyLine = splitIngredientQuantity(line)
    if let quantity = qtyLine.quantity {
        return "\(quantity) | \(qtyLine.text)"
    }
    return "| \(qtyLine.text)"
}

/// Turns an edit-sheet `qty | item` line back into a normal ingredient string.
func parseIngredientFromEdit(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.range(of: "^#{1,3}\\s+", options: .regularExpression) != nil {
        return trimmed
    }
    guard let bar = trimmed.firstIndex(of: "|") else {
        return trimmed
    }
    let qty = trimmed[..<bar].trimmingCharacters(in: .whitespaces)
    let item = trimmed[trimmed.index(after: bar)...].trimmingCharacters(in: .whitespaces)
    if qty.isEmpty { return item }
    if item.isEmpty { return qty }
    return "\(qty) \(item)"
}

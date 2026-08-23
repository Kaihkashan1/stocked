import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL = ""
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(RecipeStore.hostedURL, text: $draftURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Recipes load from the hosted Recipe Box server. You do not need your Mac running. Only change this if you are testing a local backend.")
                }

                Section {
                    Button("Save and reload") {
                        Task { await save() }
                    }
                    .disabled(draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    if let saveError {
                        Text(saveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { draftURL = store.serverURL }
        }
    }

    private func save() async {
        saving = true
        saveError = nil
        defer { saving = false }
        store.serverURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = await store.refresh()
        if ok {
            dismiss()
        } else {
            saveError = "Could not reach that server. Check the address and your internet connection."
        }
    }
}

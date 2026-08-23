import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RecipeStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL = ""
    @State private var saving = false

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
        defer { saving = false }
        store.serverURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.refresh()
        if store.errorMessage == nil {
            dismiss()
        }
    }
}

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
                    TextField("http://192.168.0.54:8000", text: $draftURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Mac server")
                } footer: {
                    Text("On the Mac, run the Recipe Box backend, then use that Mac’s current Wi-Fi IP. iPhone and Mac must be on the same network.")
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

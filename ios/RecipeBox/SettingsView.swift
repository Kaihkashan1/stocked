import SwiftUI

struct SettingsView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(PantryStore.self) private var pantryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL = ""
    @State private var saving = false
    @State private var saveError: String?
    /// nil while loading or if the fetch failed — the card just doesn't
    /// appear rather than showing a stale/fake number (same rule the
    /// backend follows for a missing Apify token, see GET /api/usage).
    @State private var usage: UsageStats?

    var body: some View {
        // @Bindable is how an @Observable object in the environment still
        // hands out a two-way Binding ($store.serverSecret below).
        @Bindable var store = store
        return VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(Theme.display(20))
                    .foregroundStyle(Theme.ink)
                Spacer()
                CircleIconButton(systemImage: "xmark", size: 36) { dismiss() }
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    field(
                        kicker: "Server",
                        footnote: "Recipes load from the hosted Stocked server. You do not need your Mac running. Only change this if you are testing a local backend."
                    ) {
                        TextField(RecipeStore.hostedURL, text: $draftURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    field(
                        kicker: "Edit key",
                        footnote: "Same value as RECIPE_BOX_SECRET on the server — the Shortcut already sends this. Leave blank against a dev server with no secret set."
                    ) {
                        SecureField("Only needed to favorite/edit", text: $store.serverSecret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .tracking(2)
                    }

                    if let usage {
                        usageCard(usage)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            Task { await save() }
                        } label: {
                            Text(saving ? "Saving…" : "Save and reload")
                                .font(Theme.display(16))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Theme.accent)
                                .clipShape(Capsule())
                                .themeShadow(Theme.shadowSM)
                        }
                        .buttonStyle(.plain)
                        .disabled(draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                        .opacity(draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving ? 0.6 : 1)

                        if let saveError {
                            Text(saveError)
                                .font(Theme.body(12.5))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 32)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { draftURL = store.serverURL }
        .task { usage = await store.fetchUsage() }
    }

    private func usageCard(_ usage: UsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: "API usage", color: Theme.neutral600)
            VStack(alignment: .leading, spacing: 16) {
                UsageBar(
                    label: "Gemini reads today",
                    valueText: "\(usage.gemini.used) of \(usage.gemini.limit)",
                    used: Double(usage.gemini.used),
                    limit: Double(usage.gemini.limit),
                    resetText: UsageStats.GeminiUsage.resetsLabel
                )
                if let apify = usage.apify {
                    UsageBar(
                        label: "Instagram credit",
                        valueText: "\(formatUsd(apify.usedUsd)) of \(formatUsd(apify.limitUsd))",
                        used: apify.usedUsd,
                        limit: apify.limitUsd,
                        resetText: apify.resetsLabel
                    )
                }
            }
            .padding(18)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private func formatUsd(_ value: Double) -> String {
        "$" + String(format: value == value.rounded() ? "%.0f" : "%.2f", value)
    }

    private func field<Content: View>(kicker: String, footnote: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: kicker, color: Theme.neutral600)
            content()
                .font(Theme.body(14.5))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Theme.surface)
                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                .clipShape(Capsule())
            Text(footnote)
                .font(Theme.body(12))
                .foregroundStyle(Theme.neutral600)
        }
    }

    private func save() async {
        saving = true
        saveError = nil
        defer { saving = false }
        store.serverURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        async let recipesOK = store.refresh()
        async let pantryOK = pantryStore.refresh()
        let ok = await recipesOK
        _ = await pantryOK
        if ok {
            dismiss()
        } else {
            saveError = "Could not reach that server. Check the address and your internet connection."
        }
    }
}

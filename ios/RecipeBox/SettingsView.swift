import SwiftUI

struct SettingsView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(PantryStore.self) private var pantryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL = ""
    @State private var saving = false
    @State private var saveError: String?
    @State private var developerOpen = false
    @State private var logsOpen = false
    /// nil until Developer → Logs is opened the first time.
    @State private var importLog: [ImportLogEntry]?
    @State private var importLogFailed = false
    /// nil while loading or if the fetch failed — the section is omitted
    /// rather than showing a stale/fake number (same rule the backend
    /// follows for a missing Apify token, see GET /api/usage).
    @State private var usage: UsageStats?

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.accent700)
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Close"))
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Settings")
                        .font(Theme.display(30))
                        .foregroundStyle(Theme.ink)

                    if let usage {
                        importLimitsSection(usage)
                    }

                    developerSection(secret: $store.serverSecret)
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 32)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { draftURL = store.serverURL }
        .task { usage = await store.fetchUsage() }
    }

    private func developerSection(secret: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    developerOpen.toggle()
                }
            } label: {
                HStack {
                    Kicker(text: L("Developer"), color: Theme.neutral600)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.neutral800)
                        .rotationEffect(.degrees(developerOpen ? 180 : 0))
                }
                .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)
            }

            if developerOpen {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    field(
                        kicker: L("Server"),
                        footnote: L("Recipes load from the hosted server. Your Mac does not need to be running.")
                    ) {
                        TextField(RecipeStore.hostedURL, text: $draftURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    field(
                        kicker: L("Edit key"),
                        footnote: L("Only needed to favorite or edit. Same value the Shortcut sends.")
                    ) {
                        SecureField("Only needed to favorite/edit", text: secret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .tracking(2)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            Task { await save() }
                        } label: {
                            Text(saving ? L("Saving…") : L("Save and reload"))
                                .font(Theme.display(15))
                                .foregroundStyle(Theme.bg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(Theme.accent)
                                .clipShape(Capsule())
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

                    logsSection
                }
                .padding(.top, 4)
            }
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    logsOpen.toggle()
                }
                if logsOpen, importLog == nil, !importLogFailed {
                    Task {
                        if let rows = await store.fetchImportLog() {
                            importLog = rows
                        } else {
                            importLogFailed = true
                        }
                    }
                }
            } label: {
                HStack {
                    Kicker(text: L("Logs"), color: Theme.neutral600)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.neutral800)
                        .rotationEffect(.degrees(logsOpen ? 180 : 0))
                }
                .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)
            }

            if logsOpen {
                if importLogFailed {
                    Text(L("Couldn't load logs."))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.neutral600)
                        .padding(.bottom, 8)
                } else if let importLog, importLog.isEmpty {
                    Text(L("No imports yet."))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.neutral600)
                        .padding(.bottom, 8)
                } else if let importLog {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(importLog) { row in
                            importLogRow(row)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func importLogRow(_ row: ImportLogEntry) -> some View {
        let urlText = (row.url.isEmpty || row.url == "(photo)") ? L("(photo)") : row.url
        let statusText = row.reason.isEmpty ? row.status : "\(row.status) — \(row.reason)"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.timestamp)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.neutral600)
                Spacer(minLength: 0)
                if row.usedBackup {
                    Text(L("backup"))
                        .font(Theme.body(11, weight: .semibold))
                        .foregroundStyle(Theme.sage800)
                        .textCase(.uppercase)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Theme.sage800, lineWidth: 1))
                }
            }
            Text(urlText)
                .font(Theme.body(13.5))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(statusText)
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.neutral600)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private func importLimitsSection(_ usage: UsageStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker(text: L("Import limits"), color: Theme.neutral600)
            VStack(alignment: .leading, spacing: 10) {
                UsageBar(
                    label: L("Imports today"),
                    valueText: L("\(usage.gemini.used) of \(usage.gemini.limit)"),
                    used: Double(usage.gemini.used),
                    limit: Double(usage.gemini.limit),
                    resetText: UsageStats.GeminiUsage.resetsLabel
                )
                if let apify = usage.apify {
                    UsageBar(
                        label: L("Import cost this month"),
                        valueText: L("\(formatUsd(apify.usedUsd)) of \(formatUsd(apify.limitUsd))"),
                        used: apify.usedUsd,
                        limit: apify.limitUsd,
                        resetText: apify.resetsLabel
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
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
                .font(Theme.body(12.5))
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
            saveError = L("Could not reach that server. Check the address and your internet connection.")
        }
    }
}

import SwiftUI

struct SettingsView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(PantryStore.self) private var pantryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var draftURL = ""
    @State private var saving = false
    @State private var saveError: String?
    @State private var developerOpen = false
    /// nil until Settings loads the log.
    @State private var importLog: [ImportLogEntry]?
    @State private var importLogFailed = false
    @State private var logFilter: ImportLogFilter = .all
    @State private var logShown = 5
    @State private var revealedLogIDs: Set<UUID> = []
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

                    logsSection
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 32)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { draftURL = store.serverURL }
        .task {
            usage = await store.fetchUsage()
            if let rows = await store.fetchImportLog() {
                importLog = rows
            } else {
                importLogFailed = true
            }
        }
    }

    private func developerSection(secret: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    developerOpen.toggle()
                }
            } label: {
                HStack {
                    Kicker(text: L("Developer settings"), color: Theme.neutral600)
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
                }
                .padding(.top, 4)
            }
        }
    }

    private var filteredImportLog: [ImportLogEntry] {
        guard let importLog else { return [] }
        switch logFilter {
        case .all: return importLog
        case .saved: return importLog.filter { !$0.isError }
        case .errors: return importLog.filter(\.isError)
        }
    }

    private var logPageSize: Int { 5 }

    private var visibleImportLog: [ImportLogEntry] {
        Array(filteredImportLog.prefix(logShown))
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(text: L("Logs"), color: Theme.neutral600)
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                logFilterChip(.all, title: L("All"))
                logFilterChip(.saved, title: L("Saved"))
                logFilterChip(.errors, title: L("Errors"))
            }
            .padding(.bottom, 6)

            if importLogFailed {
                Text(L("Couldn't load logs."))
                    .font(Theme.body(13.5))
                    .foregroundStyle(Theme.neutral600)
                    .padding(.vertical, 14)
            } else if let importLog, importLog.isEmpty {
                Text(L("No imports yet."))
                    .font(Theme.body(13.5))
                    .foregroundStyle(Theme.neutral600)
                    .padding(.vertical, 14)
            } else if importLog != nil, filteredImportLog.isEmpty {
                Text(L("No matching logs."))
                    .font(Theme.body(13.5))
                    .foregroundStyle(Theme.neutral600)
                    .padding(.vertical, 14)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleImportLog) { row in
                        importLogRow(row)
                    }
                    if logShown < filteredImportLog.count {
                        Button(L("Show more")) {
                            logShown += logPageSize
                        }
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.neutral800)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                }
                .padding(.bottom, 8)
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

    private func logFilterChip(_ filter: ImportLogFilter, title: String) -> some View {
        Button {
            logFilter = filter
            logShown = logPageSize
        } label: {
            Text(title)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(logFilter == filter ? Theme.bg : Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(logFilter == filter ? Theme.ink : Theme.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func importLogRow(_ row: ImportLogEntry) -> some View {
        let isPhoto = row.url.isEmpty || row.url == "(photo)"
        let headline = row.displayTitle.isEmpty
            ? (row.isError ? L("Errors") : L("Saved"))
            : row.displayTitle
        let detailsOpen = revealedLogIDs.contains(row.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: row.isError ? "xmark" : "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(row.isError ? Theme.accent700 : Theme.sage500)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(row.isError ? L("Errors") : L("Saved"))
                Text(row.timestamp)
                    .font(Theme.body(12.5))
                    .foregroundStyle(Theme.neutral600)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 9)
            Text(headline)
                .font(Theme.display(16))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Button {
                if detailsOpen {
                    revealedLogIDs.remove(row.id)
                } else {
                    revealedLogIDs.insert(row.id)
                }
            } label: {
                HStack(spacing: 5) {
                    Text(L("Additional details"))
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.neutral600)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.neutral600)
                        .rotationEffect(.degrees(detailsOpen ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            if detailsOpen {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.displayModel)
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.neutral700)
                    importLogLink(row, isPhoto: isPhoto)
                }
                .padding(.top, 9)
            }
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    @ViewBuilder
    private func importLogLink(_ row: ImportLogEntry, isPhoto: Bool) -> some View {
        if isPhoto {
            Text("(photo)")
                .font(Theme.body(13))
                .foregroundStyle(Theme.neutral600)
        } else if let link = URL(string: row.url) {
            Button {
                openURL(link)
            } label: {
                Text(row.url)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.accent700)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
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

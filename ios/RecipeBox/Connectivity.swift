import Network
import Observation
import SwiftUI

/// Live reachability for the hosted API. Used to keep the last-synced
/// cookbook/cupboard on screen when the phone is offline, and to kick a
/// refresh the moment connectivity comes back.
@Observable
@MainActor
final class Connectivity {
    /// True until the first path update arrives, so a banner doesn't flash
    /// on launch before NWPathMonitor has spoken.
    private(set) var isOnline = true
    private(set) var hasPath = false

    var isOffline: Bool { hasPath && !isOnline }

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "recipebox.connectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                self.hasPath = true
            }
        }
        monitor.start(queue: queue)
    }
}

/// Compact strip shown while the last-synced cache is standing in for the
/// server. Sage, not error-red — this is expected, not a crash.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
            Text("Offline — showing recipes saved on this phone")
                .font(Theme.body(12.5, weight: .semibold))
        }
        .foregroundStyle(Theme.sage800)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, Theme.screenPadding)
        .background(Theme.sage100)
    }
}

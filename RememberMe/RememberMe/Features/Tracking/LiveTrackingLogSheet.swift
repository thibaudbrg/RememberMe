import SwiftUI

/// Live debug log of the background tracker. Each entry shows what happened
/// (state transition, location fix, visit, motion change, auth change, timer,
/// CL error) with a category icon, a primary message, and an optional detail
/// line. Newest first.
///
/// Purely diagnostic. The log is persisted to a protected, backup-excluded file
/// (last ~2000 entries) so it survives the app being backgrounded or relaunched —
/// each launch is marked with an "app launched" entry so gaps between sessions are
/// visible. The actual tracker state and trip data persist independently in the
/// encrypted database.
struct LiveTrackingLogSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var filter: FilterChoice = .all

    private enum FilterChoice: String, CaseIterable, Identifiable {
        case all = "All"
        case state = "State"
        case motion = "Motion"
        case fix = "Fixes"
        case visit = "Visits"
        case auth = "Auth"
        case timer = "Timers"
        case error = "Errors"
        case user = "User"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Live tracking log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") {
                            environment.tracker.clearLog()
                        }
                        .disabled(environment.tracker.recentEvents.isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        let entries = filtered(environment.tracker.recentEvents)
        VStack(spacing: 0) {
            filterBar
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Events will appear here as you move. Make sure live tracking is on and authorization is set to Always.")
                )
            } else {
                List {
                    summarySection(total: environment.tracker.recentEvents.count, shown: entries.count)
                    Section("Events (newest first)") {
                        ForEach(entries) { entry in
                            row(for: entry)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilterChoice.allCases) { choice in
                    Button {
                        filter = choice
                    } label: {
                        Text(choice.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(filter == choice ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color(.secondarySystemBackground)))
                            )
                            .foregroundStyle(filter == choice ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func summarySection(total: Int, shown: Int) -> some View {
        Section {
            HStack {
                Text("Showing").font(.callout)
                Spacer()
                Text(filter == .all ? "\(total) events" : "\(shown) of \(total)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            HStack {
                Text("Tracker state").font(.callout)
                Spacer()
                Text(environment.tracker.state.rawValue)
                    .foregroundStyle(.secondary)
                    .font(.callout.monospaced())
            }
            Text("Holds the last ~2000 events and survives app restarts (look for “app launched” markers between sessions). Drive / walk to generate transitions; Clear wipes the saved log.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(for entry: LocationTracker.TrackerLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                categoryIcon(entry.category)
                Text(entry.message)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(entry.timestamp, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let detail = entry.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func categoryIcon(_ category: LocationTracker.TrackerLogEntry.Category) -> some View {
        switch category {
        case .stateTransition:
            Image(systemName: "arrow.left.arrow.right.circle.fill").foregroundStyle(.purple)
        case .fix:
            Image(systemName: "location.fill").foregroundStyle(.blue)
        case .visit:
            Image(systemName: "mappin.circle.fill").foregroundStyle(.indigo)
        case .motion:
            Image(systemName: "figure.walk.motion").foregroundStyle(.orange)
        case .auth:
            Image(systemName: "key.fill").foregroundStyle(.green)
        case .timer:
            Image(systemName: "timer").foregroundStyle(.teal)
        case .user:
            Image(systemName: "person.fill").foregroundStyle(.brown)
        case .error:
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func filtered(_ entries: [LocationTracker.TrackerLogEntry]) -> [LocationTracker.TrackerLogEntry] {
        switch filter {
        case .all: entries
        case .state: entries.filter { $0.category == .stateTransition }
        case .motion: entries.filter { $0.category == .motion }
        case .fix: entries.filter { $0.category == .fix }
        case .visit: entries.filter { $0.category == .visit }
        case .auth: entries.filter { $0.category == .auth }
        case .timer: entries.filter { $0.category == .timer }
        case .error: entries.filter { $0.category == .error }
        case .user: entries.filter { $0.category == .user }
        }
    }
}

#Preview {
    LiveTrackingLogSheet()
        .environment(AppEnvironment.preview())
}

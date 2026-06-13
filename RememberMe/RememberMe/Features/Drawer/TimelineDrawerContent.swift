import Core
import Persistence
import SwiftUI

/// Drawer tab showing the selected day's events plus a calendar picker at the top.
/// Tapping a row sets the map's focused item (visit → coordinate, trip → polyline).
struct TimelineDrawerContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(PremiumStore.self) private var premium
    @State private var refinementContext: RefinementSheetContext?
    @State private var refineDayRunning = false
    @State private var showingPaywall = false

    /// Identifiable wrapper so `.sheet(item:)` can drive presentation. Carries both the
    /// trip and the optional journey context — single-trip refinement passes nil, journey
    /// passes the detected `Journey`.
    struct RefinementSheetContext: Identifiable, Equatable {
        let id = UUID()
        let trip: TripSummary
        let journey: Journey?

        static func == (lhs: RefinementSheetContext, rhs: RefinementSheetContext) -> Bool {
            lhs.id == rhs.id
        }
    }

    var body: some View {
        ScrollView {
            // Eager VStack so the ScrollView measures the full content height up-front;
            // LazyVStack defers measurement of off-screen rows, which makes the scroll
            // indicator scale against a too-small content size and "jump" mid-scroll.
            VStack(alignment: .leading, spacing: 14) {
                DayPickerView()
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                DaySummaryChips(summary: environment.daySummary)
                    .padding(.horizontal, 20)

                FilterChipRow()
                    .padding(.horizontal, 20)

                let entries = environment.visibleDayEvents

                if entries.isEmpty {
                    emptyState
                } else if environment.selectedRange == .day {
                    EventList(
                        entries: entries,
                        onTap: handleEventTap,
                        onRefine: handleRefineTap
                    )
                    .padding(.horizontal, 20)
                } else {
                    GroupedEventList(
                        entries: entries,
                        onTap: handleEventTap,
                        onRefine: handleRefineTap
                    )
                    .padding(.horizontal, 20)
                }

                if showRefineRangeButton {
                    RefineDayButton(label: refineRangeButtonLabel) {
                        if premium.isPremium {
                            refineDayRunning = true
                        } else {
                            showingPaywall = true
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallSheet(contextLine: "Route refinement is a Premium feature.")
        }
        .sheet(isPresented: $refineDayRunning) {
            RefineHistoryProgressSheet(
                days: refineRangeDays,
                title: refineRangeSheetTitle
            )
            .presentationDetents([.large])
        }
        .sheet(item: $refinementContext, onDismiss: {
            // Cleanup when the whole sheet closes (not when pushing internally — that's
            // why we don't put this in the detail view's onDisappear, which fires on push
            // and would clobber the navigation binding mid-flight).
            environment.pathRefinement.state = .idle
            // Drop the active fetch identity too, so a late in-flight fetch for the
            // just-closed trip can't push its candidates into a subsequently-opened trip (M14).
            environment.pathRefinement.activeTripID = nil
        }) { context in
            NavigationStack {
                PathRefinementTripDetailView(trip: context.trip, journey: context.journey)
            }
            .presentationDetents([.large])
        }
    }

    /// Returns the matching `TripSummary` for an activity timeline entry — needed because
    /// `TimelineEntry` carries only distance + mode, while `PathRefinementTripDetailView`
    /// wants start/end coords. Looks up by id in `dayTrips`.
    private func tripSummary(for entry: TimelineEntry) -> TripSummary? {
        environment.dayTrips.first(where: { $0.id == entry.id })
    }

    private func handleRefineTap(_ entry: TimelineEntry, journey: Journey?) {
        guard let trip = tripSummary(for: entry) else { return }
        guard premium.isPremium else {
            showingPaywall = true
            return
        }
        refinementContext = RefinementSheetContext(trip: trip, journey: journey)
    }

    /// True when at least one trip in the active range still needs refining and has a
    /// routable mode. Used to gate the "Refine whole day / week / month" button. The button
    /// stays visible for free users — tapping it presents the paywall instead of the runner.
    /// `dayTrips` already spans `environment.dayRange`, so the same check works for all
    /// three range kinds — no extra per-day fetch needed.
    private var showRefineRangeButton: Bool {
        return environment.dayTrips.contains { trip in
            !environment.dayRefinedActivityIDs.contains(trip.id)
                && RefinementMode.map(recordedMode: trip.mode) != nil
        }
    }

    /// Label on the bottom button, adapting to the active range.
    private var refineRangeButtonLabel: String {
        switch environment.selectedRange {
        case .day: "Refine whole day"
        case .week: "Refine whole week"
        case .month: "Refine whole month"
        }
    }

    /// Navigation title on the runner sheet, mirroring the button label.
    private var refineRangeSheetTitle: String { refineRangeButtonLabel }

    /// Days the runner should iterate. For `.day` that's just the selected day; for week /
    /// month we intersect `daysWithData` with the active `dayRange` so we don't waste
    /// requests on days that have no events.
    private var refineRangeDays: [Date] {
        switch environment.selectedRange {
        case .day:
            return [environment.selectedDay]
        case .week, .month:
            let range = environment.dayRange
            return environment.daysWithData.filter { range.contains($0) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Nothing on this day")
                .font(.headline)
            Text("Pick another day, or import history if you haven't.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func handleEventTap(_ entry: TimelineEntry) {
        switch entry.detail {
        case let .visit(placeID, userLabel, resolvedLabel, _, coordinate):
            // Visit taps open PlaceDetailView as its own sheet at .medium — no need to
            // resize the bottom drawer here.
            environment.focus(.visit(placeID: placeID, coordinate: coordinate))
            environment.selectedPlace = VisitMarker(
                placeID: placeID,
                coordinate: coordinate,
                mostRecentVisit: entry.start.date,
                visitCount: 0,
                userLabel: userLabel,
                resolvedLabel: resolvedLabel
            )
        case .activity:
            // Trip taps don't open a sheet — they just zoom the map. Slide the drawer to
            // .medium so the user sees a balanced map-on-top / list-on-bottom split.
            environment.drawerSize = .medium
            environment.focus(.trip(id: entry.id))
        case .path:
            environment.drawerSize = .medium
            environment.focus(.path(id: entry.id))
        }
    }
}

// MARK: - Filter chips

private struct FilterChipRow: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AppEnvironment.TimelineFilter.allCases) { filter in
                    FilterChip(
                        label: filter.label,
                        isSelected: environment.timelineFilter == filter
                    ) {
                        environment.timelineFilter = filter
                    }
                }
            }
        }
        .scrollClipDisabled()
    }
}

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Summary chips

private struct DaySummaryChips: View {
    let summary: DaySummary

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(summary.activitySummaries) { entry in
                    SummaryChip(
                        symbol: TripStyle.symbol(for: entry.mode),
                        text: distanceText(entry.distanceMeters),
                        subtext: durationText(entry.durationSeconds)
                    )
                }
                if summary.visitCount > 0 {
                    SummaryChip(
                        symbol: "mappin.and.ellipse",
                        text: "\(summary.visitCount)",
                        subtext: summary.visitCount == 1 ? "visit" : "visits"
                    )
                }
            }
        }
        .scrollClipDisabled()
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters)) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60
        let remaining = mins % 60
        return remaining == 0 ? "\(hours) h" : "\(hours) h \(remaining)"
    }
}

private struct SummaryChip: View {
    let symbol: String
    let text: String
    let subtext: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption)
            Text(text).font(.callout.weight(.semibold))
            Text(subtext).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

// MARK: - Event list

private struct EventList: View {
    @Environment(AppEnvironment.self) private var environment
    let entries: [TimelineEntry]
    let onTap: (TimelineEntry) -> Void
    let onRefine: (TimelineEntry, Journey?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                EventTimelineRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(entry) }
                    .contextMenu {
                        if entry.kind == "activity" {
                            // Mode change — free for everyone; doesn't touch
                            // coords / distance / timestamps, just relabels the trip.
                            ChangeModeMenu(entry: entry)

                            // Refinement items stay visible for free users — the tap
                            // handler presents the paywall when Premium isn't owned.
                            // Precomputed lookup — runs in O(1). Same Journey instance for
                            // every member leg, so A, B, and C all see identical menu items.
                            let journey = environment.dayJourneysByAnchor[entry.id]
                            Button {
                                onRefine(entry, nil)
                            } label: {
                                Label(
                                    "Refine this trip only",
                                    systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                                )
                            }
                            if let journey, journey.isMultiLeg {
                                Button {
                                    onRefine(entry, journey)
                                } label: {
                                    Label(
                                        "Refine whole journey — \(journey.legCount) legs",
                                        systemImage: "arrow.triangle.branch"
                                    )
                                }
                            }
                        }
                    }
                if entry.id != entries.last?.id {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Multi-day view: groups entries by their local start day and shows each group as its own
/// labelled card. Order is newest day first. Tapping the day header jumps to that day's
/// day-mode filter so the user can drill in to a single day from the week/month view.
private struct GroupedEventList: View {
    @Environment(AppEnvironment.self) private var environment
    let entries: [TimelineEntry]
    let onTap: (TimelineEntry) -> Void
    let onRefine: (TimelineEntry, Journey?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task {
                            // Switch the active range to .day first so loadDay()'s next
                            // run uses the right window, then jump to the tapped day.
                            await environment.selectRange(.day)
                            await environment.selectDay(group.day)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(dayLabel(group.day))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    EventList(entries: group.entries, onTap: onTap, onRefine: onRefine)
                }
            }
        }
    }

    private struct DayGroup {
        let day: Date
        let entries: [TimelineEntry]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.start.date)
        }
        return buckets
            .map { DayGroup(day: $0.key, entries: $0.value.sorted { $0.start.date < $1.start.date }) }
            .sorted { $0.day > $1.day }
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct EventTimelineRow: View {
    @Environment(AppEnvironment.self) private var environment
    let entry: TimelineEntry

    private var isRefined: Bool { environment.dayRefinedActivityIDs.contains(entry.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.tint)
                if isRefined {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                        .background(Circle().fill(.background).frame(width: 13, height: 13))
                        .offset(x: 5, y: 4)
                        .accessibilityLabel("Refined")
                }
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    // Tiny grey indicator if a photo was taken near this event. Uses the
                    // precomputed set (O(1) lookup) instead of re-scanning all photos per row.
                    if environment.entryIDsWithNearbyPhotos.contains(entry.id) {
                        Image(systemName: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.start.date.formatted(.dateTime.hour().minute()))
                    .font(.caption.monospacedDigit())
                Text(durationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var symbol: String {
        switch entry.detail {
        case let .activity(_, mode): TripStyle.symbol(for: mode)
        case .visit: "mappin.and.ellipse"
        case .path: "point.topleft.down.curvedto.point.bottomright.up"
        }
    }

    private var title: String {
        switch entry.detail {
        case let .activity(distance, mode):
            "\(TripStyle.friendlyLabel(for: mode)) — \(distanceLabel(distance))"
        case let .visit(_, userLabel, resolvedLabel, semanticType, _):
            userLabel ?? resolvedLabel ?? semanticTypeLabel(semanticType)
        case let .path(count):
            "Path (\(count) GPS samples)"
        }
    }

    private var subtitle: String? {
        switch entry.detail {
        case let .visit(_, _, _, semanticType, _):
            // Hide when Google Takeout didn't classify the visit (most of them).
            // Keep it for the handful of tagged ones: Home, Work, Search.
            if semanticType.isEmpty || semanticType == "Unknown" { return nil }
            return semanticTypeLabel(semanticType)
        case .activity:
            return "Trip"
        case .path:
            return "Background trace"
        }
    }

    private var durationText: String {
        let seconds = entry.duration
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        let hours = seconds / 3600
        return hours < 10 ? String(format: "%.1fh", hours) : String(format: "%.0fh", hours)
    }

    private func distanceLabel(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters)) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    private func semanticTypeLabel(_ type: String) -> String {
        switch type {
        case "Home": "Home"
        case "Work": "Work"
        case "Search": "Searched place"
        default: type.isEmpty ? "Visit" : type
        }
    }
}

/// Submenu inside the timeline context-menu for swapping an activity's transport mode.
/// Pure metadata edit — coordinates, distance, timestamps stay as-recorded; only the
/// icon + label update. Looks up the matching `TripSummary` from `dayTrips` so the DB
/// update can target the activity row.
private struct ChangeModeMenu: View {
    @Environment(AppEnvironment.self) private var environment
    let entry: TimelineEntry

    /// (storedMode, displayLabel, sfSymbol). The stored mode strings match what
    /// `TripStyle.symbol(for:)` and `friendlyLabel(for:)` recognise so the row's icon
    /// and label update automatically after `loadDay()`.
    private static let options: [(String, String, String)] = [
        ("walking", "Walking", "figure.walk"),
        ("driving", "Driving", "car.fill"),
        ("cycling", "Cycling", "bicycle"),
        ("bus", "Bus", "bus"),
        ("train", "Train", "tram"),
        ("subway", "Subway", "tram.fill"),
        ("tram", "Tram", "tram"),
        ("ferry", "Ferry", "ferry"),
    ]

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.0) { stored, label, symbol in
                Button {
                    guard let trip = environment.dayTrips.first(where: { $0.id == entry.id })
                    else { return }
                    Task { await environment.setMode(for: trip, to: stored) }
                } label: {
                    Label(label, systemImage: symbol)
                }
            }
        } label: {
            Label("Change mode", systemImage: "arrow.left.arrow.right")
        }
    }
}

/// Capsule call-to-action shown at the bottom of the timeline when there are still
/// refinable trips in the active range. Triggers the sequential runner sheet.
private struct RefineDayButton: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label(label, systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.tint.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

import Core
import Persistence
import SwiftUI

/// Drawer tab showing the selected day's events plus a calendar picker at the top.
/// Tapping a row sets the map's focused item (visit → coordinate, trip → polyline).
struct TimelineDrawerContent: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
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
                    EventList(entries: entries) { entry in
                        handleEventTap(entry)
                    }
                    .padding(.horizontal, 20)
                } else {
                    GroupedEventList(entries: entries) { entry in
                        handleEventTap(entry)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 32)
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
    let entries: [TimelineEntry]
    let onTap: (TimelineEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                EventTimelineRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(entry) }
                if entry.id != entries.last?.id {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Multi-day view: groups entries by their local start day and shows each group as its own
/// labelled card. Order is newest day first.
private struct GroupedEventList: View {
    let entries: [TimelineEntry]
    let onTap: (TimelineEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(dayLabel(group.day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    EventList(entries: group.entries, onTap: onTap)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .foregroundStyle(.tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    // Tiny grey indicator if a photo was taken near this event.
                    if environment.hasNearbyPhoto(for: entry) {
                        Image(systemName: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var subtitle: String {
        switch entry.detail {
        case let .visit(_, _, _, semanticType, _):
            semanticType
        case .activity:
            "Trip"
        case .path:
            "Background trace"
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

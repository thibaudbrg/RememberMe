import Core
import Persistence
import SwiftUI

/// Insights tab: all-time stats across the user's whole history.
struct InsightsDrawerContent: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if environment.insights.totalEvents == 0 {
                    emptyState
                } else {
                    summary
                    distanceByMode
                    topPlaces
                    busiestDay
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Nothing to summarize yet")
                .font(.headline)
            Text("Import your Google Takeout from Settings to see all-time stats here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Sections

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your history")
                    .font(.title3.weight(.semibold))
                if let range = environment.insights.dateRange {
                    Text(rangeText(range))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                CountCard(label: "Activities", value: environment.counts.activities, symbol: "figure.walk")
                CountCard(label: "Visits", value: environment.counts.visits, symbol: "mappin.and.ellipse")
                CountCard(
                    label: "Paths",
                    value: environment.counts.paths,
                    symbol: "point.topleft.down.curvedto.point.bottomright.up"
                )
            }
        }
    }

    private var distanceByMode: some View {
        let modes = environment.insights.activitiesByMode
        return Group {
            if !modes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Distance by mode")
                        .font(.headline)
                    VStack(spacing: 0) {
                        ForEach(modes) { mode in
                            ModeStatRow(
                                symbol: TripStyle.symbol(for: mode.mode),
                                title: TripStyle.friendlyLabel(for: mode.mode),
                                distance: distanceText(mode.distanceMeters),
                                duration: durationText(mode.durationSeconds)
                            )
                            if mode.id != modes.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var topPlaces: some View {
        let places = environment.insights.topPlaces
        return Group {
            if !places.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Top places")
                        .font(.headline)
                    VStack(spacing: 0) {
                        ForEach(places) { place in
                            TopPlaceRow(place: place)
                            if place.id != places.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var busiestDay: some View {
        Group {
            if let busiest = environment.insights.busiestDay {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Busiest day")
                        .font(.headline)
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(busiest.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                                .font(.callout.weight(.medium))
                            Text("\(busiest.eventCount) events")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("View") {
                            Task { await environment.selectDay(busiest.day) }
                            environment.drawerTab = .timeline
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    // MARK: - Formatting helpers

    private func rangeText(_ range: ClosedRange<Date>) -> String {
        let start = range.lowerBound.formatted(.dateTime.month(.wide).year())
        let end = range.upperBound.formatted(.dateTime.month(.wide).year())
        return start == end ? start : "\(start) – \(end)"
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters)) m" }
        if meters < 100_000 { return String(format: "%.1f km", meters / 1000) }
        return String(format: "%.0f km", meters / 1000)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60
        return "\(hours) h"
    }
}

private struct CountCard: View {
    let label: String
    let value: Int
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Text(formatted)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct ModeStatRow: View {
    let symbol: String
    let title: String
    let distance: String
    let duration: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.tint)
            Text(title)
                .font(.callout.weight(.medium))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(distance).font(.callout.weight(.semibold)).monospacedDigit()
                Text(duration).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct TopPlaceRow: View {
    let place: TopPlace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.tint)
            Text(place.displayLabel ?? "Unnamed place")
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Text("\(place.visitCount)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(place.visitCount == 1 ? "visit" : "visits")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

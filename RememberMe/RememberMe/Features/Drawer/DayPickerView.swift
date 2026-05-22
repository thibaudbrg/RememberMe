import Persistence
import SwiftUI

/// Header that lets the user pick a date range: previous chevron, label pill (opens calendar),
/// next chevron, plus a Day/Week/Month segmented picker. Stepping is range-aware — a week view's
/// chevron jumps by one week, a month view's by one month.
struct DayPickerView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showingCalendar = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ChevronButton(symbol: "chevron.backward", visible: previousAnchor != nil) {
                    Task { await environment.stepRange(by: -1) }
                }

                Button {
                    showingCalendar = true
                } label: {
                    HStack(spacing: 6) {
                        Text(rangeLabel)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                }

                ChevronButton(symbol: "chevron.forward", visible: nextAnchor != nil) {
                    Task { await environment.stepRange(by: 1) }
                }

                Spacer(minLength: 0)

                if !isAtToday {
                    Button(todayButtonLabel) {
                        Task { await environment.selectDay(Date()) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Picker("Range", selection: rangeBinding) {
                ForEach(AppEnvironment.DateRangeKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
        }
        .sheet(isPresented: $showingCalendar) {
            CalendarSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var rangeBinding: Binding<AppEnvironment.DateRangeKind> {
        Binding(
            get: { environment.selectedRange },
            set: { newValue in Task { await environment.selectRange(newValue) } }
        )
    }

    private var todayButtonLabel: String {
        switch environment.selectedRange {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        }
    }

    /// True when the current range contains today.
    private var isAtToday: Bool {
        environment.dayRange.contains(Date())
    }

    // MARK: - Prev/Next logic

    /// In `.day` mode we still gate the chevrons on `daysWithData` so we don't take the user
    /// through long stretches of empty days. In `.week` / `.month` modes we always allow stepping
    /// as long as there's still data anywhere in the relevant direction.
    private var previousAnchor: Date? {
        guard !environment.daysWithData.isEmpty else { return nil }
        let earliest = environment.daysWithData.last ?? environment.selectedDay
        let range = environment.dayRange
        return earliest < range.lowerBound ? earliest : nil
    }

    private var nextAnchor: Date? {
        guard !environment.daysWithData.isEmpty else { return nil }
        let latest = environment.daysWithData.first ?? environment.selectedDay
        let range = environment.dayRange
        return latest >= range.upperBound ? latest : nil
    }

    /// Human-readable label for the current range. Day → "Today"/"Yesterday"/"May 21 2026".
    /// Week → "May 18 – 24, 2026". Month → "May 2026".
    private var rangeLabel: String {
        switch environment.selectedRange {
        case .day:
            let date = environment.selectedDay
            if Calendar.current.isDateInToday(date) { return "Today" }
            if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
            return date.formatted(.dateTime.day().month(.wide).year())
        case .week:
            let range = environment.dayRange
            let end = range.upperBound.addingTimeInterval(-1)
            let calendar = Calendar.current
            let startD = calendar.component(.day, from: range.lowerBound)
            let endD = calendar.component(.day, from: end)
            let sameMonth = calendar.isDate(range.lowerBound, equalTo: end, toGranularity: .month)
            if sameMonth {
                let month = range.lowerBound.formatted(.dateTime.month(.abbreviated))
                let year = calendar.component(.year, from: range.lowerBound)
                return "\(month) \(startD)–\(endD), \(year)"
            }
            let startLabel = range.lowerBound.formatted(.dateTime.month(.abbreviated).day())
            let endLabel = end.formatted(.dateTime.month(.abbreviated).day().year())
            return "\(startLabel) – \(endLabel)"
        case .month:
            return environment.selectedDay.formatted(.dateTime.month(.wide).year())
        }
    }
}

/// Small chevron button. When `visible` is false it collapses to zero width but reserves the layout slot
/// so the centered pill doesn't jitter as the user navigates to the data boundaries.
private struct ChevronButton: View {
    let symbol: String
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: Circle())
        }
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
        .accessibilityHidden(!visible)
    }
}

private struct CalendarSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var selection = Date()

    private var allowedRange: ClosedRange<Date> {
        let earliest = environment.daysWithData.last ?? Date()
        let latest = max(Date(), environment.daysWithData.first ?? Date())
        return earliest ... latest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Pick a day")
                    .font(.title3.weight(.semibold))
                Spacer()
                if !Calendar.current.isDateInToday(selection) {
                    Button("Today") {
                        selection = Date()
                        Task {
                            // Drop back to single-day view — picking a specific date in
                            // the calendar always means "show me that day".
                            await environment.selectRange(.day)
                            await environment.selectDay(Date())
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Done") { dismiss() }
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 20)
            // Bumped down so the title clears the sheet's drag indicator. With the previous
            // 16pt padding the title was nearly behind the handle.
            .padding(.top, 40)

            DatePicker(
                "",
                selection: $selection,
                in: allowedRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .onChange(of: selection) { _, newValue in
                Task {
                    // Picking a specific date in the calendar means "show me that day",
                    // even if the user was previously in the week/month filter.
                    await environment.selectRange(.day)
                    await environment.selectDay(newValue)
                }
            }

            if !environment.daysWithData.isEmpty {
                Divider().padding(.vertical, 4)
                Text("\(environment.daysWithData.count) day\(environment.daysWithData.count == 1 ? "" : "s") with data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .onAppear { selection = environment.selectedDay }
    }
}

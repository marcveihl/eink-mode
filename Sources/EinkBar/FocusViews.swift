import SwiftUI
import Charts
import EinkCore

/// Daily tracker and motivational stats for focus sessions.
struct FocusStatsView: View {
    @ObservedObject var model: AppModel
    let start: () -> Void
    @State private var hovered: FocusStats.Day?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let stats = model.stats {
                today(stats)
                Text(stats.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Tile(title: "Streak", value: "\(stats.streak) day\(stats.streak == 1 ? "" : "s")",
                         detail: "Best \(stats.bestStreak)", symbol: "flame")
                    Tile(title: "This week", value: "\(stats.weekCompleted)", detail: hours(stats.weekMinutes), symbol: "calendar")
                    Tile(title: "All time", value: "\(stats.totalCompleted)", detail: hours(stats.totalMinutes), symbol: "sum")
                    Tile(title: "Best day", value: "\(stats.bestDay)", detail: "Goal met \(stats.daysGoalMet)×", symbol: "trophy")
                }
                week(stats)
            } else { ProgressView().frame(maxWidth: .infinity) }
            HStack {
                if let focus = model.focus {
                    Label(MenuBuilder.focusLine(focus), systemImage: focus.phase == .focus ? "timer" : "cup.and.saucer")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop Focus Session") { model.stopFocus() }
                } else {
                    Text("\(model.focusSettings.sessions) × \(model.focusSettings.focusMinutes) min focus, \(model.focusSettings.breakMinutes) min color breaks")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Focus Session", action: start).keyboardShortcut(.defaultAction)
                        .disabled(model.status == nil || model.needsRecovery)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func today(_ stats: FocusStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today").font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(stats.today.completed)").font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("of \(stats.goal) sessions").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Text("\(hours(stats.today.focusMinutes)) focused").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(stats.today.completed, stats.goal)), total: Double(stats.goal))
                .tint(.primary)
                .accessibilityLabel("Daily goal progress: \(stats.today.completed) of \(stats.goal)")
            HStack {
                Spacer()
                Stepper("Daily goal: \(model.focusSettings.dailyGoal) session\(model.focusSettings.dailyGoal == 1 ? "" : "s")",
                        value: Binding(get: { model.focusSettings.dailyGoal }, set: { goal in model.change { $0.focus.dailyGoal = goal } }),
                        in: 1...24)
                    .font(.callout).foregroundStyle(.secondary).fixedSize()
                    .disabled(model.needsRecovery)
            }
        }
    }

    /// One series (sessions per day), so one ink color, no legend; the goal is a recessive dashed rule.
    private func week(_ stats: FocusStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 7 days").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if let hovered {
                    Text("\(hovered.label): \(hovered.completed) session\(hovered.completed == 1 ? "" : "s") · \(hours(hovered.minutes))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    // Keyed here rather than on the plot, so it never collides with bars.
                    Text("- - -  goal \(stats.goal)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(stats.week, id: \.date) { day in
                    BarMark(x: .value("Day", day.label), y: .value("Sessions", day.completed), width: .ratio(0.5))
                        .foregroundStyle(Color.primary.opacity(day.label == "Today" ? 0.85 : 0.45))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        .annotation(position: .top) {
                            if day.label == "Today" && day.completed > 0 {
                                Text("\(day.completed)").font(.caption.bold()).monospacedDigit()
                            }
                        }
                        .accessibilityLabel(day.label)
                        .accessibilityValue("\(day.completed) sessions, \(day.minutes) minutes")
                }
                RuleMark(y: .value("Goal", stats.goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.primary.opacity(0.45))
            }
            .chartYScale(domain: 0...max(stats.goal + 1, (stats.week.map(\.completed).max() ?? 0) + 1))
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08)); AxisValueLabel() } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel() } } // no vertical gridlines
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let point) = phase, let label: String = proxy.value(atX: point.x) {
                                hovered = stats.week.first { $0.label == label }
                            } else { hovered = nil }
                        }
                }
            }
            .frame(height: 170)
        }
    }

    private func hours(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

private struct Tile: View {
    let title: String, value: String, detail: String, symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// Settings → Focus: lengths, round size, daily goal, and cues.
struct FocusSettingsView: View {
    @ObservedObject var model: AppModel
    let showStats: () -> Void
    var body: some View {
        Form {
            let focus = model.focusSettings
            Section {
                Stepper("Focus for \(focus.focusMinutes) minutes", value: binding(\.focusMinutes), in: 5...90, step: 5)
                Stepper("Color break for \(focus.breakMinutes) minutes", value: binding(\.breakMinutes), in: 1...30)
                Stepper("\(focus.sessions) session\(focus.sessions == 1 ? "" : "s") per round", value: binding(\.sessions), in: 1...12)
                Text("Each session is grayscale. Between sessions, color comes back for your break, then grayscale returns on its own. After the last session, your display goes back to how it was.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Daily tracker") {
                Stepper("Daily goal: \(focus.dailyGoal) sessions", value: binding(\.dailyGoal), in: 1...24)
                HStack {
                    Text(model.stats.map { "Today \($0.today.completed) of \($0.goal) · \($0.streak)-day streak" } ?? "")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Focus Stats", action: showStats)
                }
            }
            Section("Cues") {
                Toggle("Play a sound when focus and breaks start", isOn: $model.focusSound)
                Toggle("Show the countdown in the menu bar", isOn: $model.menuBarCountdown)
                Text("Changes apply to the next round; a round in progress keeps its timing. Turning E-Ink Mode off ends the round, and minutes already focused still count.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .disabled(model.needsRecovery)
    }
    private func binding(_ key: WritableKeyPath<FocusSettings, Int>) -> Binding<Int> {
        Binding(get: { model.focusSettings[keyPath: key] }, set: { value in model.change { $0.focus[keyPath: key] = value } })
    }
}

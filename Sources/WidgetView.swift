import SwiftUI

/// Styled to sit alongside macOS's own desktop widgets: medium widget size, white type on dark clear glass.
struct WidgetView: View {
    @ObservedObject var model: UsageModel

    static let size = CGSize(width: 344, height: 164)
    static let cornerRadius: CGFloat = 22
    private static let weekLength: TimeInterval = 7 * 24 * 3600

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let session = model.snapshot?.session?.current(at: now)
            let weekly = model.snapshot?.weekly?.current(at: now)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    UsageColumn(
                        title: "Session",
                        percent: session?.percent,
                        detail: detail(for: session) { "Resets in \(timeLeft(until: $0, from: now))" }
                    )
                    UsageColumn(
                        title: "This week",
                        percent: weekly?.percent,
                        detail: detail(for: weekly) { "Resets \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" }
                    )
                }
                Spacer(minLength: 8)
                footer(status: status(session: session, weekly: weekly, now: now))
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(.white)
    }

    private func footer(status: Status) -> some View {
        HStack(spacing: 5) {
            Image(systemName: status.icon)
            Text(status.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            } else if let plan = model.snapshot?.plan {
                Text(plan).foregroundStyle(.white.opacity(0.7))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(status.isWarning ? 1 : 0.7))
        .frame(height: 14)
    }

    private func detail(for window: UsageWindow?, resets: (Date) -> String) -> String {
        guard let window else {
            return model.snapshot == nil && model.problem == nil ? "Loading…" : "—"
        }
        guard let reset = window.resetsAt else { return "Not started yet" }
        return resets(reset)
    }

    private struct Status {
        var icon: String
        var text: String
        var isWarning = false
    }

    private func status(session: UsageWindow?, weekly: UsageWindow?, now: Date) -> Status {
        if let problem = model.problem {
            return Status(icon: "exclamationmark.triangle.fill", text: problem, isWarning: true)
        }
        guard model.snapshot != nil else {
            return Status(icon: "arrow.triangle.2.circlepath", text: "Fetching usage…")
        }
        if let weekly, weekly.percent >= 100 {
            return Status(icon: "xmark.octagon.fill", text: "Weekly limit reached", isWarning: true)
        }
        if let session, session.percent >= 100 {
            return Status(icon: "xmark.octagon.fill", text: "Session limit reached", isWarning: true)
        }
        switch weekly?.pace(now: now, length: Self.weekLength) {
        case .runsOut(let date):
            return Status(icon: "exclamationmark.triangle.fill", text: "Out by \(dayPart(of: date, now: now)) at this pace", isWarning: true)
        case .onTrack(let projected):
            return Status(icon: "checkmark.circle", text: "On track · ~\(Int(projected.rounded()))% by reset")
        case nil:
            return Status(icon: "checkmark.circle", text: "Plenty of room this week")
        }
    }
}

private let spring = Animation.spring(response: 1, dampingFraction: 0.85)

private struct UsageColumn: View {
    var title: String
    var percent: Double?
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(percent.map { "\(Int($0.rounded()))" } ?? "–")
                    .contentTransition(.numericText(value: percent ?? 0))
                if percent != nil {
                    Text("%").font(.system(size: 24, weight: .regular))
                }
            }
            .font(.system(size: 38, weight: .regular))
            .monospacedDigit()
            .animation(spring, value: percent)
            UsageBar(percent: percent ?? 0)
                .padding(.top, 4)
            Text(detail)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageBar: View {
    var percent: Double

    var body: some View {
        let fraction = min(max(percent, 0), 100) / 100
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule()
                    .fill(.white)
                    .frame(width: fraction > 0 ? max(proxy.size.width * fraction, 5) : 0)
            }
        }
        .frame(height: 5)
        .animation(spring, value: fraction)
    }
}

/// "47m", "2h 4m", "3d 6h".
private func timeLeft(until date: Date, from now: Date) -> String {
    let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
    let hours = minutes / 60
    switch hours {
    case 0: return "\(minutes)m"
    case ..<24: return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
    default: return "\(hours / 24)d \(hours % 24)h"
    }
}

/// "tonight", "tomorrow morning", "Thursday night" — the same phrasing as the Claude app's heads-up.
private func dayPart(of date: Date, now: Date) -> String {
    let calendar = Calendar.current
    let hour = calendar.component(.hour, from: date)
    // The small hours still count as the night before.
    let day = hour < 5 ? calendar.date(byAdding: .day, value: -1, to: date)! : date
    let part = switch hour {
    case 5..<12: "morning"
    case 12..<17: "afternoon"
    case 17..<21: "evening"
    default: "night"
    }
    if calendar.isDate(day, inSameDayAs: now) { return part == "night" ? "tonight" : "this \(part)" }
    if calendar.isDate(day, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!) { return "tomorrow \(part)" }
    return "\(day.formatted(.dateTime.weekday(.wide))) \(part)"
}

import SwiftUI

enum DraftDateFormat {
    static func relative(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(elapsed / 3600))h ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if elapsed < 7 * 86400 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func details(_ draft: Draft) -> String {
        [draft.createdAt.map { "Created \($0.formatted(date: .long, time: .shortened))" },
         draft.editedAt.map { "Edited \($0.formatted(date: .long, time: .shortened))" }]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

struct DraftTimestamp: View {
    let draft: Draft
    var compact = false

    var body: some View {
        if let date = draft.editedAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text((compact ? "" : "Edited ") + DraftDateFormat.relative(date, now: context.date))
                    .font(.system(size: compact ? 12 : 11))
                    .foregroundStyle(Color(Paper.muted))
                    .lineLimit(1)
                    .help(DraftDateFormat.details(draft))
                    .accessibilityLabel(DraftDateFormat.details(draft))
            }
        }
    }
}

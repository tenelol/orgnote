import SwiftUI
import WidgetKit

@main
struct OrgnoteWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

struct TodayEntry: TimelineEntry {
    var date: Date
    var overdue: [TodaySnapshot.Item]
    var today: [TodaySnapshot.Item]
    var isPlaceholder = false

    var open: [TodaySnapshot.Item] { overdue + today.filter { !$0.isDone } }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, overdue: [], today: Self.samples, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview && TodaySnapshot.load() == nil ? placeholder(in: context) : entry(for: .now))
    }

    /// One entry now and one at midnight, so "today" rolls over without the app.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
        completion(Timeline(entries: [entry(for: .now), entry(for: midnight)], policy: .after(midnight)))
    }

    private func entry(for date: Date) -> TodayEntry {
        let lists = TodaySnapshot.load()?.lists(for: date) ?? (overdue: [], today: [])
        return TodayEntry(date: date, overdue: lists.overdue, today: lists.today)
    }

    static let samples: [TodaySnapshot.Item] = [
        .init(id: "1", title: "週次レポートを提出", fileID: "", line: 0, day: .now, time: nil,
              isDeadline: true, isDone: false, priority: "A"),
        .init(id: "2", title: "定例ミーティングの準備", fileID: "", line: 0, day: .now, time: "10:00",
              isDeadline: false, isDone: false, priority: nil),
        .init(id: "3", title: "筋トレ", fileID: "", line: 0, day: .now, time: nil,
              isDeadline: false, isDone: false, priority: nil),
    ]
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TodaySnapshot.widgetKind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(TodaySnapshot.agendaURL)
        }
        .configurationDisplayName("今日のTODO")
        .description("予定日と期限が今日のTODOと、期限切れのTODOを表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TodayEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: 0) {
                Image(systemName: "checklist")
            } currentValueLabel: {
                Text("\(entry.open.count)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel("今日のTODO \(entry.open.count)件")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("今日 \(entry.open.count)件")
                    .font(.headline)
                    .widgetAccentable()
                ForEach(entry.open.prefix(2)) { item in
                    Text(item.title).font(.caption).lineLimit(1)
                }
                if entry.open.isEmpty {
                    Text("TODOはありません").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            list(limit: family == .systemSmall ? 3 : 4)
        }
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日")
                    .font(.headline)
                    .foregroundStyle(Color.orgAccent)
                Spacer()
                Text("\(entry.open.count)")
                    .font(.title2.bold().monospacedDigit())
                    .contentTransition(.numericText())
            }
            if entry.open.isEmpty {
                Spacer()
                Label("今日のTODOはありません", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.open.prefix(limit)) { item in
                    Link(destination: TodaySnapshot.url(fileID: item.fileID, line: item.line)) {
                        TodayRow(item: item, isOverdue: entry.overdue.contains(item), compact: family == .systemSmall)
                    }
                }
                Spacer(minLength: 0)
                if entry.open.count > limit {
                    Text("ほか\(entry.open.count - limit)件")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }
}

private struct TodayRow: View {
    var item: TodaySnapshot.Item
    var isOverdue: Bool
    var compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(isOverdue || item.isDeadline ? Color.red : Color.secondary)
                .accessibilityHidden(true)
            if let priority = item.priority, priority.uppercased() == "A" {
                Text("!").font(.caption.bold()).foregroundStyle(.red)
            }
            Text(item.title)
                .font(compact ? .caption : .subheadline)
                .lineLimit(1)
            if !compact {
                Spacer(minLength: 4)
                if let time = item.time {
                    Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if isOverdue {
                    Text("期限切れ").font(.caption2).foregroundStyle(.red)
                } else if item.isDeadline {
                    Text("期限").font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension Color {
    /// The app's accent, repeated here because the widget has its own asset catalog.
    static let orgAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.345, green: 0.780, blue: 0.545, alpha: 1)
            : UIColor(red: 0.149, green: 0.478, blue: 0.314, alpha: 1)
    })
}

#Preview(as: .systemMedium) {
    TodayWidget()
} timeline: {
    TodayEntry(date: .now, overdue: [], today: TodayProvider.samples)
}

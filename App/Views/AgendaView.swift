import OrgKit
import SwiftUI

/// Days at a glance: a freely scrolling strip of days with dots, today's
/// progress ring, and the chosen day split into all-day items and a timeline.
struct AgendaView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(NotebookStyles.self) private var styles
    @Environment(CalendarEvents.self) private var events
    @State private var selected = OrgDate(.now)
    @State private var showsOverdue = true

    private var today: OrgDate { OrgDate(.now) }
    /// How far the strip reaches either side of today.
    private static let reach = 180

    var body: some View {
        let first = today.adding(days: -Self.reach)
        let span = store.agenda(from: first, days: Self.reach * 2 + 1)
        let byDay = Dictionary(uniqueKeysWithValues: span.days.map { ($0.date, $0.items) })
        let overdue = store.agenda(from: today, days: 1).overdue
        let day = byDay[selected] ?? []
        let allDay = day.filter { $0.time == nil }
        let dayEvents = events.byDay[selected] ?? []
        let allDayEvents = dayEvents.filter(\.isAllDay)
        // Tasks and calendar events share one timeline, in time order.
        let timed = (day.filter { $0.time != nil }.map(TimedEntry.task) + dayEvents.filter { !$0.isAllDay }.map(TimedEntry.event))
            .sorted { $0.time < $1.time }

        List {
            if selected == today, !overdue.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsOverdue) {
                        ForEach(overdue) { item in
                            row(item, trailing: DateLabel.short(item.date), alert: true)
                        }
                    } label: {
                        Label("\(overdue.count) Overdue", systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                .listRowBackground(Color.red.opacity(0.1))
            }

            if !allDay.isEmpty || !allDayEvents.isEmpty {
                Section("All-day") {
                    ForEach(allDayEvents) { event in
                        EventRow(event: event, showsBar: true)
                    }
                    ForEach(allDay) { item in
                        row(item, trailing: item.kind == .deadline ? String(localized: "Deadline") : nil,
                            alert: item.kind == .deadline && !item.headline.isDone)
                    }
                }
            }

            if !timed.isEmpty {
                Section("Timed") {
                    ForEach(timed) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Text(entry.time.string)
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                                .padding(.top, 12)
                            switch entry {
                            case let .task(item):
                                bar(color(for: item.fileID))
                                row(item, trailing: nil, alert: false, showsDot: false)
                            case let .event(event):
                                bar(Color(event.color))
                                EventRow(event: event, showsBar: false)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                    }
                }
            }

            if day.isEmpty, dayEvents.isEmpty, !(selected == today && !overdue.isEmpty) {
                Section {
                    ContentUnavailableView {
                        Label(selected == today ? "Nothing Scheduled Today" : "Nothing Scheduled", systemImage: "sun.max")
                    } description: {
                        Text("To-dos with a scheduled date or deadline appear here.")
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        // A short day should sit still rather than bounce under the pinned strip.
        .scrollBounceBehavior(.basedOnSize)
        // Pinned above the list, as in Calendar; inside a row, list updates would cross-fade the slide.
        .safeAreaInset(edge: .top, spacing: 0) {
            DayStrip(dates: (0...(Self.reach * 2)).map { first.adding(days: $0) },
                     selected: $selected, today: today, items: byDay, events: events.byDay)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .navigationTitle(title)
        .navigationSubtitle(selected.date().formatted(.dateTime.month().day().weekday(.wide)))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ProgressRing(done: progress.done, total: progress.total)
            }
            if selected != today {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") { withAnimation(.snappy) { selected = today } }
                }
            }
        }
    }

    private var title: String {
        switch today.days(until: selected) {
        case 0: String(localized: "Today")
        case 1: String(localized: "Tomorrow")
        case -1: String(localized: "Yesterday")
        default: String(localized: "Agenda")
        }
    }

    /// Today's tasks done out of all of today's tasks, overdue ones included.
    private var progress: (done: Int, total: Int) {
        let agenda = store.agenda(from: today, days: 1)
        let tasks = (agenda.overdue + (agenda.days.first?.items ?? [])).filter { $0.headline.keyword != nil }
        return (tasks.filter(\.headline.isDone).count, tasks.count)
    }

    private func bar(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 4)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }

    private func color(for fileID: String) -> Color {
        styles.style(for: fileID, isCaptureTarget: fileID == store.inboxPath).tint
    }

    private func row(_ item: AgendaItem, trailing: String?, alert: Bool, showsDot: Bool = true) -> some View {
        NavigationLink(value: Route.entry(item.fileID, line: item.headline.lineIndex)) {
            HStack(spacing: 0) {
                if showsDot {
                    Circle().fill(color(for: item.fileID)).frame(width: 7, height: 7)
                        .padding(.trailing, 2)
                        .accessibilityHidden(true)
                }
                HeadlineRow(headline: item.headline, subtitle: subtitle(item), trailing: trailing, trailingIsAlert: alert) {
                    withAnimation(.snappy) {
                        store.edit(item.fileID) { $0.toggleDone(forHeadlineAt: item.headline.lineIndex) }
                    }
                }
            }
        }
        .taskActions(fileID: item.fileID, headline: item.headline)
    }

    /// Where the entry lives: the notebook and, if any, the heading above it.
    private func subtitle(_ item: AgendaItem) -> String {
        guard let file = store.files[item.fileID] else { return item.fileID }
        let parent = file.document.headlines.last {
            $0.lineIndex < item.headline.lineIndex && $0.subtreeEndLineIndex > item.headline.lineIndex
        }
        return [file.displayName, parent?.displayTitle].compactMap { $0 }.joined(separator: " › ")
    }
}

/// A strip of days that scrolls freely with momentum and settles on a day
/// boundary. Seven days fit the width; a dot marks days with something on.
/// The focus rides along with the scroll like a picker wheel, and the list
/// below follows it day by day.
private struct DayStrip: View {
    var dates: [OrgDate]
    @Binding var selected: OrgDate
    var today: OrgDate
    var items: [OrgDate: [AgendaItem]]
    var events: [OrgDate: [CalendarEvent]]
    // Grow with the text size so larger type is not cut off.
    @ScaledMetric(relativeTo: .body) private var stripHeight: CGFloat = 72
    @ScaledMetric(relativeTo: .body) private var dayCircle: CGFloat = 34
    /// True while a finger moves the strip or it coasts, as opposed to a programmatic glide.
    @State private var userScrolling = false
    /// Index of the day under the middle of the strip.
    @State private var middle: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Eager on purpose: a lazy stack here, inside the list's top inset, drew nothing.
                HStack(spacing: 0) {
                    ForEach(dates, id: \.self) { date in
                        day(date)
                            .frame(width: Self.cellWidth)
                            .id(date)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .frame(height: stripHeight)
            // The day under the middle is the chosen one, frame by frame while the user
            // scrolls, so the list below follows along.
            .onScrollGeometryChange(for: Int.self) { geometry in
                Int(((geometry.contentOffset.x + geometry.containerSize.width / 2) / Self.cellWidth).rounded(.down))
            } action: { _, index in
                middle = index
                if userScrolling { choose(index) }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
                // Where it snapped to has the final say.
                if phase == .idle, let middle { choose(middle) }
            }
            // After the first layout pass; scrolling before it lands off center.
            .task { proxy.scrollTo(selected, anchor: .center) }
            // A tapped day, or the Today button, glides to the center.
            .onChange(of: selected) { _, date in
                guard !userScrolling, middle.flatMap({ dates.indices.contains($0) ? dates[$0] : nil }) != date else { return }
                withAnimation(.snappy) { proxy.scrollTo(date, anchor: .center) }
            }
        }
        // One adjustable element for VoiceOver, swiped up or down a day at a time,
        // rather than a year of buttons to step through.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Date")
        .accessibilityValue(spokenLabel(selected, items: items[selected]?.count ?? 0, events: events[selected]?.count))
        .accessibilityAdjustableAction { direction in
            let step = switch direction {
            case .increment: 1
            case .decrement: -1
            @unknown default: 0
            }
            let next = selected.adding(days: step)
            if step != 0, dates.contains(next) { selected = next }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func choose(_ index: Int) {
        guard dates.indices.contains(index), dates[index] != selected else { return }
        selected = dates[index]
    }

    /// Seven days across a phone screen.
    private static var cellWidth: CGFloat {
        let width = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
        return (width - 48) / 7
    }

    private func day(_ date: OrgDate) -> some View {
        let items = items[date] ?? []
        return Button {
            withAnimation(.snappy) { selected = date }
        } label: {
            VStack(spacing: 4) {
                Text(date.day == 1 ? date.date().formatted(.dateTime.month(.abbreviated)) : date.date().formatted(.dateTime.weekday(.narrow)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(date.day == 1 ? Color.accentColor : Color.secondary)
                Text("\(date.day)")
                    .font(.body.weight(date == selected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(foreground(date))
                    .frame(width: dayCircle, height: dayCircle)
                    .background {
                        if date == selected { Circle().fill(date == today ? Color.accentColor : Color.primary) }
                    }
                Circle().fill(dot(items, hasEvents: events[date]?.isEmpty == false)).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: stripHeight - 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func spokenLabel(_ date: OrgDate, items: Int, events: Int?) -> String {
        let day = date.date().formatted(.dateTime.month().day().weekday(.wide))
        return switch (items, events) {
        case (0, nil): day
        case let (items, nil): String(localized: "\(day), \(items) items")
        case let (0, events?): String(localized: "\(day), \(events) events")
        case let (items, events?): String(localized: "\(day), \(items) items, \(events) events")
        }
    }

    private func foreground(_ date: OrgDate) -> Color {
        if date == selected { return Color(.systemBackground) }
        return date == today ? .accentColor : .primary
    }

    private func dot(_ items: [AgendaItem], hasEvents: Bool) -> Color {
        // Calendar events alone get a quiet dot; tasks keep the colored ones.
        if items.isEmpty { return hasEvents ? Color(.systemGray3) : .clear }
        if items.contains(where: { $0.kind == .deadline && !$0.headline.isDone }) { return .red }
        return items.allSatisfy(\.headline.isDone) ? Color(.tertiaryLabel) : .accentColor
    }
}

/// One row of the day's timeline.
private enum TimedEntry: Identifiable {
    case task(AgendaItem)
    case event(CalendarEvent)

    var id: String {
        switch self {
        case let .task(item): item.id
        case let .event(event): event.id
        }
    }

    var time: OrgTime {
        switch self {
        case let .task(item): item.time ?? OrgTime(hour: 0, minute: 0)
        case let .event(event): event.time ?? OrgTime(hour: 0, minute: 0)
        }
    }
}

/// A calendar event; tapping opens that day in Calendar, where it can be edited.
private struct EventRow: View {
    var event: CalendarEvent
    var showsBar: Bool

    var body: some View {
        Link(destination: URL(string: "calshow:\(Int(event.start.timeIntervalSinceReferenceDate))")!) {
            HStack(spacing: 10) {
                if showsBar {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(event.color))
                        .frame(width: 4, height: 32)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "calendar")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        // Plain, so the title keeps the label color instead of the link tint.
        .buttonStyle(.plain)
        .accessibilityHint("Opens in Calendar.")
    }

    private var subtitle: String {
        guard !event.isAllDay else { return event.calendar }
        let range = "\(OrgTime(event.start).string)–\(OrgTime(event.end).string)"
        return "\(range) · \(event.calendar)"
    }
}

/// Today's tasks as a filling ring, like Fitness.
private struct ProgressRing: View {
    var done: Int
    var total: Int
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 30

    var body: some View {
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: fraction)
            Text(total == 0 ? "–" : "\(done)/\(total)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(4)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("\(done) of \(total) to-dos done today")
    }
}

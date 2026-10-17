import OrgKit
import SwiftUI

struct AgendaView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let agenda = store.agenda()
        let today = OrgDate(.now)
        List {
            if !agenda.overdue.isEmpty {
                Section {
                    ForEach(agenda.overdue) { item in
                        row(item, trailing: DateLabel.short(item.date), alert: true)
                    }
                } header: {
                    Label("期限切れ", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }

            ForEach(agenda.days) { day in
                if day.date == today || !day.items.isEmpty {
                    Section {
                        if day.items.isEmpty {
                            Text("予定はありません").foregroundStyle(.secondary)
                        }
                        ForEach(day.items) { item in
                            row(item, trailing: item.time?.string, alert: item.kind == .deadline && !item.headline.isDone)
                        }
                    } header: {
                        DayHeader(date: day.date, today: today)
                    }
                }
            }

            if !agenda.unscheduled.isEmpty {
                Section("日付なしのTODO") {
                    ForEach(agenda.unscheduled) { item in
                        row(item, trailing: nil, alert: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("アジェンダ")
        .refreshable { await store.refresh() }
    }

    private func row(_ item: AgendaItem, trailing: String?, alert: Bool) -> some View {
        NavigationLink(value: Route.file(item.fileID, line: item.headline.lineIndex)) {
            HeadlineRow(
                headline: item.headline,
                subtitle: subtitle(item),
                trailing: trailing,
                trailingIsAlert: alert
            ) {
                withAnimation(.snappy) {
                    store.edit(item.fileID) { $0.toggleDone(forHeadlineAt: item.headline.lineIndex) }
                }
            }
        }
        .taskActions(fileID: item.fileID, headline: item.headline)
    }

    private func subtitle(_ item: AgendaItem) -> String {
        let file = store.files[item.fileID]?.displayName ?? item.fileID
        switch item.kind {
        case .deadline: return "期限 · \(file)"
        case .scheduled where item.headline.scheduled == nil: return file
        case .scheduled: return "予定 · \(file)"
        case .timestamp: return file
        }
    }
}

private struct DayHeader: View {
    var date: OrgDate
    var today: OrgDate

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(date == today ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(date.date().formatted(.dateTime.month().day()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    private var title: String {
        switch today.days(until: date) {
        case 0: "今日"
        case 1: "明日"
        default: date.date().formatted(.dateTime.weekday(.wide))
        }
    }
}

import Foundation
import OrgKit

/// What the keyboard bar's commands do to a document, shared by the editor
/// and the capture sheet so both behave the same.
enum OrgCommands {
    enum Outcome {
        case changed(OrgDocument)
        /// The command needs a day picked for the headline at `line` first.
        case pickDate(PlanningKind, line: Int, current: Date)
        case none
    }

    static func apply(_ command: EditorCommand, at line: Int, to document: OrgDocument, now: Date = .now) -> Outcome {
        guard line < document.lines.count else { return .none }
        var document = document
        let headline = document.headline(containing: line)

        switch command {
        case .heading:
            let current = document.lines[line]
            if let headline = document.headline(at: line) {
                // Cycles 1 → 2 → 3 → body text. Deeper levels look the same as
                // level 3, so stars kept piling up on taps that seemed to do nothing.
                let rest = current.drop { $0 == "*" }.drop { $0 == " " || $0 == "\t" }
                replace(line, with: headline.level >= 3 ? String(rest)
                    : String(repeating: "*", count: headline.level + 1) + " " + rest, in: &document)
            } else {
                // Leading indentation would stop Org from seeing a headline.
                replace(line, with: "* " + current.drop { $0 == " " || $0 == "\t" }, in: &document)
            }
        case .cycleTodo:
            if let headline {
                document.cycleKeyword(forHeadlineAt: headline.lineIndex, now: now)
            } else {
                replace(line, with: "* TODO " + document.lines[line].trimmingCharacters(in: .whitespaces), in: &document)
            }
        case .checkbox:
            if !document.toggleCheckbox(at: line) {
                let current = document.lines[line]
                let indent = String(current.prefix { $0 == " " || $0 == "\t" })
                var rest = String(current.dropFirst(indent.count))
                if rest.hasPrefix("- ") || rest.hasPrefix("+ ") { rest.removeFirst(2) }
                replace(line, with: "\(indent)- [ ] \(rest)", in: &document)
            }
        case let .planning(kind, choice):
            guard let headline else { return .none }
            let today = OrgDate(now)
            switch choice {
            case .today: setPlanning(kind, today, at: headline.lineIndex, in: &document)
            case .tomorrow: setPlanning(kind, today.adding(days: 1), at: headline.lineIndex, in: &document)
            case .nextWeek:
                let monday = Calendar.current.nextDate(after: now, matching: DateComponents(weekday: 2),
                                                       matchingPolicy: .nextTime) ?? now
                setPlanning(kind, OrgDate(monday), at: headline.lineIndex, in: &document)
            case .pick:
                let existing = kind == .deadline ? headline.deadline : headline.scheduled
                return .pickDate(kind, line: headline.lineIndex, current: existing?.date.date() ?? now)
            case .clear: setPlanning(kind, nil, at: headline.lineIndex, in: &document)
            }
        case let .priority(value):
            guard let headline else { return .none }
            document.setPriority(value, forHeadlineAt: headline.lineIndex)
        }
        return .changed(document)
    }

    /// Sets or clears a planning date, keeping an existing time or repeater
    /// when only the day changes.
    static func setPlanning(_ kind: PlanningKind, _ day: OrgDate?, at line: Int, in document: inout OrgDocument) {
        guard let day else {
            document.setPlanning(kind, to: nil, forHeadlineAt: line)
            return
        }
        var timestamp = document.headline(at: line)?.planning.first { $0.kind == kind }?.timestamp ?? OrgTimestamp(date: day)
        timestamp.date = day
        document.setPlanning(kind, to: timestamp, forHeadlineAt: line)
    }

    /// Applies a checkbox or TODO tap from the text view.
    static func toggle(_ toggle: OrgToggle, in document: inout OrgDocument) {
        switch toggle {
        case let .checkbox(line): document.toggleCheckbox(at: line)
        case let .todo(line): document.toggleDone(forHeadlineAt: line)
        case .link: break
        }
    }

    private static func replace(_ index: Int, with line: String, in document: inout OrgDocument) {
        var lines = document.lines
        lines[index] = line
        document.replaceText(lines.joined(separator: document.newline))
    }
}

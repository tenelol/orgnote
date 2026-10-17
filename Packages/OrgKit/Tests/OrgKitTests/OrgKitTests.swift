import Foundation
import Testing
@testable import OrgKit

private func date(_ iso: String, _ time: String = "12:00") -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: "\(iso) \(time)")!
}

private let today = OrgDate(year: 2026, month: 10, day: 17)

@Suite struct TimestampTests {
    @Test func parsesFullTimestamp() throws {
        let ts = try #require(OrgTimestamp.parse("<2026-10-17 Sat 09:30-10:00 +1w -2d>"))
        #expect(ts.date == today)
        #expect(ts.time == OrgTime(hour: 9, minute: 30))
        #expect(ts.endTime == OrgTime(hour: 10, minute: 0))
        #expect(ts.repeater == OrgRepeater(kind: .cumulate, value: 1, unit: .week))
        #expect(ts.warning == "-2d")
        #expect(ts.isActive)
        #expect(ts.string == "<2026-10-17 Sat 09:30-10:00 +1w -2d>")
    }

    @Test func acceptsLocalizedDayNamesAndRejectsMismatchedBrackets() {
        #expect(OrgTimestamp.parse("[2026-10-17 土]")?.isActive == false)
        #expect(OrgTimestamp.parse("<2026-10-17 Sat]") == nil)
        #expect(OrgTimestamp.parse("<2026-13-01 Sat>") == nil)
    }

    @Test func repeaterSemantics() {
        let base = OrgDate(year: 2026, month: 10, day: 1)
        #expect(OrgRepeater(kind: .cumulate, value: 1, unit: .week).next(after: base, today: today)
            == OrgDate(year: 2026, month: 10, day: 8))
        #expect(OrgRepeater(kind: .catchUp, value: 1, unit: .week).next(after: base, today: today)
            == OrgDate(year: 2026, month: 10, day: 22))
        #expect(OrgRepeater(kind: .restart, value: 1, unit: .month).next(after: base, today: today)
            == OrgDate(year: 2026, month: 11, day: 17))
        #expect(OrgDate(year: 2026, month: 1, day: 31).adding(1, .month) == OrgDate(year: 2026, month: 2, day: 28))
    }

    @Test func weekdayNames() {
        #expect(today.weekdayAbbreviation == "Sat")
        #expect(today.adding(days: 1).weekdayAbbreviation == "Sun")
    }
}

@Suite struct DocumentTests {
    let sample = """
    #+TITLE: Projects
    * TODO [#A] Write report :work:urgent:
      SCHEDULED: <2026-10-17 Sat> DEADLINE: <2026-10-20 Tue>
      :PROPERTIES:
      :ID: abc
      :END:
      Body text <2026-10-18 Sun 14:00>
      - [ ] draft
      - [X] outline
    ** Sub heading
    * DONE Old thing
      CLOSED: [2026-10-01 Thu 10:00]
    * Plain note

    """

    @Test func roundTripsExactly() {
        for text in [sample, "", "no newline", "a\r\nb\r\n", "* x\n\n\n"] {
            #expect(OrgDocument(text: text).text == text)
        }
    }

    @Test func parsesHeadlines() throws {
        let doc = OrgDocument(text: sample)
        #expect(doc.title == "Projects")
        #expect(doc.headlines.count == 4)
        let h = doc.headlines[0]
        #expect(h.level == 1)
        #expect(h.keyword == "TODO")
        #expect(h.priority == "A")
        #expect(h.title == "Write report")
        #expect(h.tags == ["work", "urgent"])
        #expect(h.scheduled?.date == today)
        #expect(h.deadline?.date == OrgDate(year: 2026, month: 10, day: 20))
        #expect(h.timestamps.map(\.date) == [OrgDate(year: 2026, month: 10, day: 18)])
        #expect(h.checkboxes == (1, 2))
        #expect(h.endLineIndex == 9)
        #expect(h.subtreeEndLineIndex == 10)
        #expect(doc.bodyLines(of: h).first == "  Body text <2026-10-18 Sun 14:00>")
        #expect(doc.headlines[2].isDone)
        #expect(doc.headlines[3].keyword == nil)
        #expect(doc.headline(containing: 7)?.lineIndex == 1)
    }

    @Test func keywordIsOnlyRecognizedFromSettings() {
        let doc = OrgDocument(text: "#+TODO: TODO NEXT(n) | DONE(d!) CANCELLED\n* NEXT Call\n* WAITING x\n")
        #expect(doc.keywords == OrgTodoKeywords(active: ["TODO", "NEXT"], done: ["DONE", "CANCELLED"]))
        #expect(doc.headlines[0].keyword == "NEXT")
        #expect(doc.headlines[1].keyword == nil)
        #expect(doc.headlines[1].title == "WAITING x")
    }

    @Test func boldAtLineStartIsNotAHeadline() {
        #expect(OrgDocument(text: "*bold* text\n").headlines.isEmpty)
    }

    @Test func completingStampsClosedAndReopeningRemovesIt() {
        var doc = OrgDocument(text: "* TODO Task :x:\n  SCHEDULED: <2026-10-17 Sat>\n")
        doc.toggleDone(forHeadlineAt: 0, now: date("2026-10-17", "16:20"))
        #expect(doc.text == "* DONE Task :x:\n  CLOSED: [2026-10-17 Sat 16:20] SCHEDULED: <2026-10-17 Sat>\n")
        doc.toggleDone(forHeadlineAt: 0, now: date("2026-10-17"))
        #expect(doc.text == "* TODO Task :x:\n  SCHEDULED: <2026-10-17 Sat>\n")
    }

    @Test func completingWithoutPlanningAddsLine() {
        var doc = OrgDocument(text: "** TODO Task\nbody\n")
        doc.toggleDone(forHeadlineAt: 0, now: date("2026-10-17", "08:05"))
        #expect(doc.text == "** DONE Task\n   CLOSED: [2026-10-17 Sat 08:05]\nbody\n")
        doc.toggleDone(forHeadlineAt: 0)
        #expect(doc.text == "** TODO Task\nbody\n")
    }

    @Test func completingRepeatingTaskAdvancesDate() {
        var doc = OrgDocument(text: "* TODO Water plants\n  SCHEDULED: <2026-10-15 Thu +1w>\n")
        doc.toggleDone(forHeadlineAt: 0, now: date("2026-10-17"))
        #expect(doc.text == "* TODO Water plants\n  SCHEDULED: <2026-10-22 Thu +1w>\n")
    }

    @Test func cyclesKeywords() {
        var doc = OrgDocument(text: "* Task\n")
        doc.cycleKeyword(forHeadlineAt: 0, now: date("2026-10-17", "09:00"))
        #expect(doc.text == "* TODO Task\n")
        doc.cycleKeyword(forHeadlineAt: 0, now: date("2026-10-17", "09:00"))
        #expect(doc.text == "* DONE Task\n  CLOSED: [2026-10-17 Sat 09:00]\n")
        doc.cycleKeyword(forHeadlineAt: 0, now: date("2026-10-17", "09:00"))
        #expect(doc.text == "* Task\n")
    }

    @Test func keywordOnEmptyHeadline() {
        var doc = OrgDocument(text: "*\n")
        doc.setKeyword("TODO", forHeadlineAt: 0)
        #expect(doc.text == "* TODO\n")
        #expect(doc.headlines[0].keyword == "TODO")
    }

    @Test func setsAndClearsPlanningKeepingOthersVerbatim() {
        var doc = OrgDocument(text: "* TODO A\n  DEADLINE: <2026-10-20 火>\n")
        doc.setPlanning(.scheduled, to: OrgTimestamp(date: today), forHeadlineAt: 0)
        #expect(doc.text == "* TODO A\n  DEADLINE: <2026-10-20 火> SCHEDULED: <2026-10-17 Sat>\n")
        doc.setPlanning(.deadline, to: nil, forHeadlineAt: 0)
        doc.setPlanning(.scheduled, to: nil, forHeadlineAt: 0)
        #expect(doc.text == "* TODO A\n")
    }

    @Test func setsPriority() {
        var doc = OrgDocument(text: "* TODO Task\n* Other\n")
        doc.setPriority("B", forHeadlineAt: 0)
        doc.setPriority("A", forHeadlineAt: 1)
        #expect(doc.text == "* TODO [#B] Task\n* [#A] Other\n")
        doc.setPriority(nil, forHeadlineAt: 0)
        #expect(doc.text == "* TODO Task\n* [#A] Other\n")
    }

    @Test func togglesCheckboxesIncludingLenientEmptyBrackets() {
        var doc = OrgDocument(text: "- [] 数学\n  - [X] 読書\n- plain\n")
        let results = [doc.toggleCheckbox(at: 0), doc.toggleCheckbox(at: 1), doc.toggleCheckbox(at: 2)]
        #expect(results == [true, true, false])
        #expect(doc.text == "- [X] 数学\n  - [ ] 読書\n- plain\n")
    }

    @Test func appendsCaptureEntries() {
        let created = date("2026-10-17", "16:20")
        var empty = OrgDocument(text: "")
        empty.appendEntry(title: "First", created: created)
        #expect(empty.text == "* First\n  [2026-10-17 Sat 16:20]\n")

        var doc = OrgDocument(text: "* Existing")
        let line = doc.appendEntry(
            title: "Buy milk", body: "2 bottles\n\nlow fat", keyword: "TODO",
            scheduled: OrgTimestamp(date: today), tags: ["home"], created: created)
        #expect(line == 1)
        #expect(doc.text == """
        * Existing
        * TODO Buy milk :home:
          SCHEDULED: <2026-10-17 Sat>
          [2026-10-17 Sat 16:20]
          2 bottles

          low fat

        """)
        #expect(doc.headlines[1].tags == ["home"])
    }
}

@Suite struct SubtreeTests {
    let text = """
    * Inbox note
      [2026-10-17 Sat 09:12]
      - [ ] item
    ** Child
    * Second

    """

    @Test func extractsAndRemovesWholeSubtree() {
        var doc = OrgDocument(text: text)
        #expect(doc.subtree(at: 0) == ["* Inbox note", "  [2026-10-17 Sat 09:12]", "  - [ ] item", "** Child"])
        #expect(doc.subtree(at: 4) == ["* Second"])
        doc.removeSubtree(at: 0)
        #expect(doc.text == "* Second\n")
        doc.removeSubtree(at: 0)
        #expect(doc.text == "")
    }

    @Test func insertsUnderHeadlineShiftingLevels() {
        var target = OrgDocument(text: "#+TITLE: Notes\n* 読書\n** Old\n* 勉強\n")
        let line = target.insertSubtree(["* Inbox note", "  body", "** Child"], under: 1)
        #expect(line == 3)
        #expect(target.text == "#+TITLE: Notes\n* 読書\n** Old\n** Inbox note\n  body\n*** Child\n* 勉強\n")
    }

    @Test func insertsAtTopLevelAndIntoEmptyOrUnterminatedFiles() {
        var empty = OrgDocument(text: "")
        #expect(empty.insertSubtree(["** Deep", "*** Deeper"], under: nil) == 0)
        #expect(empty.text == "* Deep\n** Deeper\n")

        var unterminated = OrgDocument(text: "* A")
        unterminated.insertSubtree(["* B"], under: nil)
        #expect(unterminated.text == "* A\n* B\n")

        var last = OrgDocument(text: "* A\n* B\n")
        last.insertSubtree(["* C"], under: 1)
        #expect(last.text == "* A\n* B\n** C\n")
    }

    @Test func previewSkipsStampsAndMarkup() {
        let doc = OrgDocument(text: text)
        let h = doc.headlines[0]
        #expect(doc.preview(of: h) == "item")
        #expect(doc.created(of: h)?.time == OrgTime(hour: 9, minute: 12))
    }
}

@Suite struct AgendaTests {
    @Test func buildsSections() {
        let text = """
        * TODO Late
          SCHEDULED: <2026-10-10 Sat>
        * TODO Today later
          SCHEDULED: <2026-10-17 Sat>
        * TODO Today morning
          SCHEDULED: <2026-10-17 Sat 09:00>
        * DONE Finished today
          CLOSED: [2026-10-17 Sat 10:00] SCHEDULED: <2026-10-17 Sat>
        * Meeting <2026-10-19 Mon 13:00>
        * TODO Weekly
          SCHEDULED: <2026-10-13 Tue +1w>
        * TODO Someday
        * Note without dates
        * DONE Old
          SCHEDULED: <2026-10-01 Thu>
        * TODO Overdue deadline
          DEADLINE: <2026-10-16 Fri>
        """
        let agenda = Agenda(documents: [("a.org", OrgDocument(text: text))], today: today)
        #expect(agenda.overdue.map(\.headline.title) == ["Late", "Weekly", "Overdue deadline"])
        #expect(agenda.days.count == 7)
        #expect(agenda.days[0].items.map(\.headline.title) == ["Today morning", "Today later", "Finished today"])
        #expect(OrgDocument(text: "* See [[https://a.b][docs]] <2026-10-17 Sat>\n").headlines[0].displayTitle == "See docs")
        #expect(agenda.days[2].items.map(\.headline.displayTitle) == ["Meeting"])
        #expect(agenda.days[3].items.map(\.headline.title) == ["Weekly"])
        #expect(agenda.unscheduled.map(\.headline.title) == ["Someday"])
        #expect(agenda.todayCount == 5)
    }
}

@Suite struct SyntaxTests {
    @Test func tokenizesHeadlineParts() {
        let text = "* TODO [#A] Title *bold* :tag:\n  SCHEDULED: <2026-10-17 Sat>\n- [ ] item [[https://x.y][link]]\n"
        let tokens = OrgSyntax.tokens(in: text)
        let ns = text as NSString
        func strings(_ match: (OrgToken.Kind) -> Bool) -> [String] {
            tokens.filter { match($0.kind) }.map { ns.substring(with: $0.range) }
        }
        #expect(strings { $0 == .todoKeyword } == ["TODO"])
        #expect(strings { $0 == .priority } == ["[#A] "])
        #expect(strings { $0 == .tags } == [":tag:"])
        #expect(strings { $0 == .bold } == ["*bold*"])
        #expect(strings { $0 == .planningKeyword } == ["SCHEDULED:"])
        #expect(strings { $0 == .timestamp(active: true) } == ["<2026-10-17 Sat>"])
        #expect(strings { $0 == .checkbox(checked: false) } == ["[ ]"])
        #expect(strings { $0 == .link } == ["link"])
    }

    @Test func rangesAreUTF16() {
        let text = "日本語 😀\n* TODO 見出し\n"
        let tokens = OrgSyntax.tokens(in: text)
        let ns = text as NSString
        #expect(tokens.contains { $0.kind == .todoKeyword && ns.substring(with: $0.range) == "TODO" })
    }
}

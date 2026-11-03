import Foundation
import OrgKit

/// The notebooks a new library starts with: a short tour written as the very
/// Org text it explains, and the notebook new memos go into.
nonisolated enum WelcomeNotes {
    struct Note {
        var name: String
        var text: String
    }

    /// The inbox and the tour, in Japanese or English after the device language.
    static func notes(today: Date = .now, japanese: Bool = Locale.preferredLanguages.first?.hasPrefix("ja") == true) -> (inbox: Note, tour: Note) {
        let scheduled = OrgTimestamp(date: OrgDate(today)).string
        let created = OrgTimestamp.now(active: false, at: today).string
        if japanese {
            return (
                Note(name: "メモ.org", text: "#+TITLE: メモ\n\n"),
                Note(name: "はじめに.org", text: """
                #+TITLE: はじめに

                * Orgnoteへようこそ
                  思いついたことは、下の「新規メモ」からすぐに書けます。1行目が見出しになり、書いたメモは「メモ」ノートにたまります。
                  \(created)
                * TODO 左の丸をタップして完了にしてみる
                  SCHEDULED: \(scheduled)
                  予定日を付けたTODOは「アジェンダ」と「TODO」にも並びます。
                * チェックリストも使えます
                  - [X] チェックボックスをタップする
                  - [ ] キーボードの上のボタンで、見出し・TODO・予定日を付ける
                * あとで整理する
                  「未整理」を開くと、たまったメモを1件ずつ、ほかのノートへ移したり、TODOにしたりできます。
                * 中身はただのテキスト
                  ノートは .org ファイルとして保存されます。パソコンからも開けて、Emacs や Neovim の Org-mode でそのまま編集できます。

                """)
            )
        }
        return (
            Note(name: "Notes.org", text: "#+TITLE: Notes\n\n"),
            Note(name: "Welcome.org", text: """
            #+TITLE: Welcome

            * Welcome to Orgnote
              Jot anything down with New Memo at the bottom. The first line becomes the heading, and new memos collect in the Notes notebook.
              \(created)
            * TODO Tap the circle on the left to finish this
              SCHEDULED: \(scheduled)
              To-dos with a date also show up in Agenda and To-dos.
            * Checklists work too
              - [X] Tap a checkbox
              - [ ] Use the buttons above the keyboard for headings, to-dos and dates
            * Sort things out later
              Open Unsorted to go through your memos one at a time: move each to another notebook or turn it into a to-do.
            * It is all plain text
              Every notebook is a .org file. Open it from your computer too, and edit it as is in Emacs or Neovim with Org mode.

            """)
        )
    }
}

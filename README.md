# Orgnote

**Org-mode notes on iPhone that feel as quick as Apple Notes.**

Orgnote is a notes, to-do and agenda app whose every notebook is a plain `.org` file. Jot something down in a second, check off tasks, see your week at a glance — and open the very same files in Emacs or Neovim on your computer. No account, no server, no lock-in.

[日本語のREADMEはこちら](README.ja.md)

## Features

- **Capture in a second.** New Memo sits above the tab bar, on the Action button and in Shortcuts. The first line becomes the heading.
- **A live-preview editor.** Org markup fades away as you write: to-dos and checkboxes become buttons, dates become chips, and the raw syntax comes back on the line you are editing. The file itself never changes behind your back.
- **Notebooks with covers.** Each `.org` file is a notebook; each heading is a card. Folders keep larger libraries tidy.
- **Agenda and to-dos.** `SCHEDULED`, `DEADLINE`, plain timestamps and repeaters (`+1w`, `++1w`, `.+1d`) on a scrolling day strip, next to your Calendar events. A to-do list you can filter by priority and tag.
- **Sort things out later.** New memos land in one notebook; Unsorted walks you through them one card at a time — move, schedule, finish, delete or skip.
- **Reminders, search, widgets.** Set a reminder while you write, search headings, text and `#tags`, and keep today's to-dos on your Home and Lock Screen.
- **Your files, your way.** Notes live in iCloud Drive (or on the device). Point Orgnote at an existing Org folder instead and it edits it in place, touching only the lines you change.

## Install

Orgnote is on its way to the App Store. Until then, build it from source (below).

## Using Orgnote with Emacs or Neovim

On first launch, tap **Get Started** to keep notes in an *Orgnote* folder in iCloud Drive, or choose **Use an Existing Org Folder** to pick one you sync with your computer — for example `iCloud Drive/org`, symlinked to `~/org` on your Mac:

```bash
mkdir -p ~/Library/Mobile\ Documents/com~apple~CloudDocs/org
```

Move your existing `~/org` into that folder, then replace `~/org` with a symlink to it (a symlink placed *inside* iCloud Drive does not sync).

Orgnote reads and writes through `NSFileCoordinator`, watches the folder for changes from other devices, and asks which version to keep if both sides changed a file; the one you did not keep goes to *Settings › Backups*.

## Building from source

Requirements: Xcode 26.4 or later (iOS 26.1 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open Orgnote.xcodeproj
```

The defaults in `Config/Orgnote.xcconfig` (bundle ID `com.example.orgnote`, no team) build and run in the Simulator as is. To run on a device or publish, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill in your team ID and bundle ID; that file is gitignored. iCloud Drive storage needs a paid developer account and is switched on there too.

Run the tests:

```bash
swift test --package-path Packages/OrgKit
```

```bash
xcodebuild test -project Orgnote.xcodeproj -scheme Orgnote -destination 'platform=iOS Simulator,name=iPhone 17'
```

The second command runs the end-to-end tests in `UITests/`: on a fresh install they get started, add and sort memos, finish a to-do from the agenda, search, and delete a notebook. GitHub Actions runs both on every push and pull request.

### Project layout

- `App/` — the iOS app (SwiftUI, with a TextKit 2 editor in `App/Editor`).
- `Widget/` — the Today widget, fed by a snapshot the app writes to the shared App Group.
- `Packages/OrgKit/` — Org parsing, editing and the agenda, as a Swift package with its own tests.
- `Config/` — build identity (bundle ID, App Group, team, iCloud).
- `docs/RELEASING.md` — how to publish to the App Store.

## Privacy

Orgnote collects nothing. It has no analytics and talks to no server; your notes stay in your own files.

## Contributing

Issues and pull requests are welcome. Please keep changes focused and run the tests above before opening a pull request.

## License

[MIT](LICENSE)

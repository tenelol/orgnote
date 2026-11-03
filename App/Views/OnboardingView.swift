import SwiftUI

/// First launch: one tap to start in the app's own folder, or, for people
/// who already keep Org files, a folder of their choosing.
struct OnboardingView: View {
    @Environment(LibraryStore.self) private var store
    @State private var picking = false
    @State private var starting = false
    /// nil until the iCloud check returns.
    @State private var iCloud: Bool?

    var body: some View {
        // Scrolls so every line and the button stay reachable at accessibility text sizes.
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "asterisk")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(width: 120, height: 120)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .accessibilityHidden(true)
                    .padding(.top, 48)

                VStack(spacing: 10) {
                    Text("Welcome to Orgnote")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Write down ideas the moment they come, and see your to-dos and dates in one place.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Feature(symbol: "square.and.pencil", title: "Write Instantly",
                            detail: "Just tap New Memo and start typing. The first line becomes the heading.")
                    Feature(symbol: "calendar", title: "Dates and To-dos",
                            detail: "To-dos with dates appear in the agenda, and you can set reminders for them.")
                    Feature(symbol: "doc.plaintext", title: "Just Plain Text",
                            detail: "Notebooks are .org files. Open them on your computer and edit them as they are in Org mode for Emacs or Neovim.")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    starting = true
                    Task {
                        await store.useAppFolder()
                        starting = false
                    }
                } label: {
                    Group {
                        if starting { ProgressView() } else { Text("Get Started") }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(starting || iCloud == nil)
                .accessibilityIdentifier("onboarding.start")

                Text(iCloud == true
                     ? "Notebooks are saved in the Orgnote folder in iCloud Drive and sync with your other devices."
                     : "Notebooks are saved on this iPhone. Open them in the Files app under On My iPhone › Orgnote.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(iCloud == nil ? 0 : 1)

                Button("Use an Existing Org Folder") { picking = true }
                    .font(.footnote.weight(.semibold))
                    .disabled(starting)
                    .accessibilityIdentifier("onboarding.pickFolder")
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .task { iCloud = await LibraryStore.iCloudAvailable() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): store.choose(folder: url)
            case let .failure(error):
                store.notice = Notice(message: String(localized: "Couldn’t open the folder. Choose it again. (\(error.localizedDescription))"), isError: true)
            }
        }
    }
}

private struct Feature: View {
    var symbol: String
    var title: LocalizedStringKey
    var detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

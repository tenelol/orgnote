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
                    Text("Orgnoteへようこそ")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("思いついたことをすぐに書いて、TODOや予定もまとめて見られるメモアプリです。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Feature(symbol: "square.and.pencil", title: "すぐに書ける",
                            detail: "「新規メモ」を押して書くだけ。1行目が見出しになります。")
                    Feature(symbol: "calendar", title: "予定とTODO",
                            detail: "日付を付けたTODOはアジェンダに並び、通知も設定できます。")
                    Feature(symbol: "doc.plaintext", title: "ただのテキスト",
                            detail: "ノートは .org ファイル。パソコンでも開けて、EmacsやNeovimのOrg-modeでもそのまま編集できます。")
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
                        if starting { ProgressView() } else { Text("はじめる") }
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
                     ? "ノートはiCloud Driveの「Orgnote」フォルダに保存され、ほかのデバイスとも同期します。"
                     : "ノートはこのiPhoneに保存され、「ファイル」アプリの このiPhone内 › Orgnote から開けます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(iCloud == nil ? 0 : 1)

                Button("Org-modeのフォルダがある方はこちら") { picking = true }
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
                store.notice = Notice(message: "フォルダを開けませんでした。もう一度選んでください。（\(error.localizedDescription)）", isError: true)
            }
        }
    }
}

private struct Feature: View {
    var symbol: String
    var title: String
    var detail: String

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

import SwiftUI

struct OnboardingView: View {
    @Environment(LibraryStore.self) private var store
    @State private var picking = false

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
                    Text("iCloud Driveのフォルダを選ぶと、Macの ~/org とそのまま同期します。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Feature(symbol: "square.and.pencil", title: "すぐに書ける",
                            detail: "書いたメモはインボックスに入り、あとから整理できます。")
                    Feature(symbol: "calendar", title: "アジェンダ",
                            detail: "予定日と期限から、今日やることをまとめて表示します。")
                    Feature(symbol: "doc.plaintext", title: "ただのテキスト",
                            detail: "中身は.orgファイルなので、Macのエディタでもそのまま開けます。")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    picking = true
                } label: {
                    Text("フォルダを選択")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("iCloud Drive › org を選んでください。フォルダは「ファイル」アプリで作成できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(.bar)
        }
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

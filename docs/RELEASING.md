# App Storeへの配信手順

Orgnoteを自分のApple Developerアカウントで App Store に出すための手順。コードはそのままで、設定ファイル1つと Apple 側の登録だけで配信できる。

## 0. 必要なもの

- 有料の Apple Developer Program のアカウント（年額）。
- Xcode 26.4 以降と XcodeGen（`brew install xcodegen` など）。
- このリポジトリのクローン。

## 1. 署名と ID を決める

`Config/Local.xcconfig.example` を `Config/Local.xcconfig` にコピーして、自分の値を入れる。このファイルはgitに入らない。

```
DEVELOPMENT_TEAM = ABCDE12345            // developer.apple.com › Membership のチームID
ORGNOTE_BUNDLE_ID = com.yourname.orgnote // 自分で決めた一意のID
ORGNOTE_APP_GROUP = group.$(ORGNOTE_BUNDLE_ID)

// iCloud Driveに保存する（おすすめ）
ORGNOTE_ENTITLEMENTS = App/Orgnote+iCloud.entitlements
ORGNOTE_ICLOUD_CONTAINER = iCloud.$(ORGNOTE_BUNDLE_ID)
```

ウィジェットのバンドルIDは自動で `<ORGNOTE_BUNDLE_ID>.widget` になる。

## 2. Apple Developer サイトで登録する

[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) で次を作る。Xcode の自動署名でも作られるが、iCloudとApp Groupは先に作っておくと確実。

1. **App Groups**: `group.com.yourname.orgnote`
2. **iCloud Containers**: `iCloud.com.yourname.orgnote`
3. **App ID**（アプリ本体）: `com.yourname.orgnote`。Capabilities で *App Groups*（上の1を割り当て）と *iCloud*（*CloudKit support* ではなく *Include CloudKit support* なしの iCloud Documents、上の2を割り当て）を有効にする。
4. **App ID**（ウィジェット）: `com.yourname.orgnote.widget`。*App Groups* を有効にして1を割り当てる。

## 3. App Store Connect にアプリを作る

[App Store Connect](https://appstoreconnect.apple.com) › アプリ › 「+」› 新規App。

- プラットフォーム: iOS
- 名前: Orgnote（使われていれば「Orgnote - Org-mode Notes」など）
- プライマリ言語: 英語（日本語は「ローカリゼーション」で追加）
- バンドルID: 2で作ったもの
- SKU: 任意（例 `orgnote`）

## 4. アーカイブしてアップロードする

```bash
xcodegen generate
open Orgnote.xcodeproj
```

1. Xcode で実行先を *Any iOS Device (arm64)* にする。
2. *Product › Archive*。
3. Organizer で *Distribute App › App Store Connect › Upload*。

バージョンは `project.yml` の `MARKETING_VERSION`（表示用、例 `1.0.0`）と `CURRENT_PROJECT_VERSION`（ビルド番号、アップロードのたびに増やす）で決まる。

## 5. TestFlight で確認する

アップロードしたビルドが処理されたら、App Store Connect の TestFlight タブで自分や友達をテスターに加えて試す。初回起動、iCloud Driveへの保存、ウィジェット、通知を実機で確認する。

## 6. 審査に出す

App Store Connect の各項目は次を目安に埋める。

- **App のプライバシー**: 「データを収集していません」。アプリに解析やサーバー通信はなく、`App/PrivacyInfo.xcprivacy` もその内容で同梱している。
- **暗号化**: 独自の暗号化は使っていない（`ITSAppUsesNonExemptEncryption = false` を設定済み）。
- **年齢制限**: すべての項目「なし」で 4+。
- **カテゴリ**: 仕事効率化（Productivity）。
- **審査メモ**: ログインは不要。「はじめる」を押すと使い方のノートが作られ、すぐに試せる。カレンダーと通知の許可は、設定でオンにしたときだけ求める。
- **スクリーンショット**: 6.9インチ（iPhone 17 Pro Max など）の画像が必須。シミュレータで撮れる。
- **サポートURL・プライバシーポリシーURL**: GitHub のリポジトリや README の Privacy 節を使える。

## 7. 公開後

新しいバージョンを出すときは、`MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` を上げて 4〜6 を繰り返す。

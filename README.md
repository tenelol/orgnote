# Orgnote

iCloud Driveに置いたOrg-modeファイルを、純正メモのような軽さで書いて管理するiPhoneアプリ。正本はただの `.org` ファイルなので、MacのNeovim（nvim-orgmode）からも同じファイルをそのまま編集できる。

- **メモ**: 純正メモと同じく、フォルダをたどる階層表示。フォルダとファイルはアプリ内でも作れる。新規メモの保存先（既定は `refile.org`）には印を付ける。
- **アジェンダ**: `SCHEDULED` / `DEADLINE` / 本文中のアクティブなタイムスタンプから、期限切れ・今日・7日間を表示。繰り返し（`+1w` `++1w` `.+1d`）に対応。
- **TODO**: すべての未完了タスクを、ファイル・優先度・タグ別に表示。
- **新規メモ**: タブバー上のボタン、ショートカット、アクションボタンから開く。1行目が見出しになる。
- **エディタ**: ライブプレビュー。Orgの記号は隠して、TODOとチェックボックスは丸ボタン、予定日・期限はチップとして表示し、カーソルのある行だけ素の記法に戻す。ファイルの文字は変えず、記号は見えなくするだけなので、Neovim側には影響しない。キーボード上にOrgコマンド（見出し・TODO・チェック・予定日・期限・優先度）を置き、メニューから「Orgの記法を表示」に切り替えられる。
- **ウィジェット**: 今日のTODOと期限切れのTODOを表示する（ホーム画面の小・中サイズとロック画面用）。アプリが今週分のタスクをApp Groupに書き出し、ウィジェットはそれを読むだけ。

## 同期のしくみ

アプリは、ユーザーが選んだiCloud Driveのフォルダを、security-scoped bookmarkで読み書きする。iCloudのentitlementは使わないため、無料のApple IDでも実機で動く（ただし署名は7日ごとに更新が必要）。

- 読み書きは `NSFileCoordinator` 経由で行う。変更の検知は `NSFilePresenter` と、アプリが前面にある間の4秒ごとのポーリングを併用する。
- 編集は短い遅延のあとに保存する。保存の直前にディスク上の内容を確認し、Macでの変更とぶつかった場合はどちらの版を残すかを尋ねる。選ばなかった版は、アプリ内の `Application Support/Backups` に保存する。
- Orgの編集は変更した行だけを書き換えるため、Neovim側やGitでの差分は最小限になる。

## Mac側の設定

`~/org` をiCloud Drive内のフォルダへのsymlinkにする。逆向き（iCloud Drive内にsymlinkを置く）は同期されない。

```bash
mkdir -p ~/Library/Mobile\ Documents/com~apple~CloudDocs/org
```

既存の `~/org` の中身をそのフォルダへ移したあと、`~/org` をsymlinkに置き換える。iPhoneでは、初回起動時に「iCloud Drive › org」を選ぶ。

## 実機への自動インストール

無料の個人チームで署名したアプリは7日で起動しなくなる。`scripts/refresh-device.sh <UDID>` は、プロファイルの残りが3日（`ORGNOTE_RENEW_DAYS`）を切ったときだけ新しいプロファイルを取得し、`main` にコミット済みの内容をビルドしてiPhoneに入れ直す。iPhoneに届かないときは何もせずに終わる。このMacではdotfilesの `orgnote-refresh` モジュールがlaunchdで6時間ごとに実行し、ログを `~/Library/Logs/orgnote-refresh.log` に残す。

## 開発

```bash
xcodegen generate
```

```bash
swift test --package-path Packages/OrgKit
```

- `project.yml` からXcodeプロジェクトを生成する。Nixで入れたXcodeGenには既定の設定プリセットが含まれないため、必要なビルド設定は `project.yml` に明示している。
- Orgの解析・編集・アジェンダは `Packages/OrgKit` にあり、Mac上でテストできる。
- Debugビルドでは、起動引数 `-OrgnoteFolderPath <path>` を渡すとフォルダ選択を省略できる（シミュレータでの確認用）。

# Orgnote

iCloud Driveに置いたOrg-modeファイルを、純正メモのような軽さで書いて管理するiPhoneアプリ。正本はただの `.org` ファイルなので、MacのNeovim（nvim-orgmode）からも同じファイルをそのまま編集できる。

- **メモ**: フォルダ内の `.org` を更新順に表示。インボックス（既定は `refile.org`）を先頭に置く。
- **アジェンダ**: `SCHEDULED` / `DEADLINE` / 本文中のアクティブなタイムスタンプから、期限切れ・今日・7日間を表示。繰り返し（`+1w` `++1w` `.+1d`）に対応。
- **TODO**: すべての未完了タスクを、ファイル・優先度・タグ別に表示。
- **新規メモ**: タブバー上のボタン、ショートカット、アクションボタンから開く。1行目が見出しになる。
- **エディタ**: Orgの構文ハイライト、チェックボックスやTODOのタップによる切り替え、キーボード上のOrgコマンド（見出し・TODO・チェック・予定日・期限・優先度）。

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

# Windows Porting Status

作成日: 2026-05-20

このメモは、macOS 専用実装になっている Echoes を Windows 対応へ進めるための引き継ぎ資料です。現時点のソースを読んだ範囲では、Windows 対応はまだ実装途中というより、macOS 依存を分離する前段階です。`README.md` でも `macOS (uses AppKit via Fiddle; no Linux/Windows support)` と明記されています。

## 現状

- Ruby gem 形式のターミナルエミュレータです。CLI 起点は `exe/echoes` で、通常は `Echoes::GUI.new.run`、`--tty` 指定時のみ `Echoes::Terminal.new.run` に分岐します。
- GUI は `lib/echoes/gui.rb` に大きく集約され、`lib/echoes/objc.rb` の Fiddle ラッパーを通じて AppKit / Foundation / CoreGraphics / CoreText を直接呼び出しています。
- `lib/echoes.rb` が `echoes/objc`、`echoes/preferences`、`echoes/gui` を無条件で require しているため、Windows では GUI を起動しない用途でも macOS フレームワークのロードで失敗します。
- 通常ペインは `lib/echoes/pane.rb` の `spawn_with_pty` で `PTY.open`、`fork`、`setsid`、macOS 固有 ioctl (`DARWIN_TIOCSCTTY`, `DARWIN_TIOCSPGRP`) を使います。
- TTY モードも `lib/echoes/terminal.rb` で Ruby 標準の `PTY.spawn` に依存しています。
- 組み込み rubish モードは `lib/echoes/embedded_shell.rb` と `lib/echoes/embedded_shell_helper.rb` で、`PTY.open`、制御 pipe、`Process.spawn`、`tcsetpgrp`、`TIOCSCTTY` を使ってジョブ制御を成立させています。
- インストーラは `lib/echoes/installer.rb` が `~/Applications` に `Echoes.app` / `EchoesEmbed.app` のラッパーを作る macOS 専用です。
- CI は `.github/workflows/main.yml` で `macos-latest` のみです。Windows ジョブはありません。
- `git status --short` は空で、調査開始時点では未コミット差分はありませんでした。

## Windows 対応の主なブロッカー

### 1. 起動時の macOS 無条件ロード

`lib/echoes.rb` が `echoes/objc` と `echoes/gui` を無条件で読み込みます。`lib/echoes/objc.rb` はロード直後に以下を `Fiddle.dlopen` します。

- `/usr/lib/libobjc.A.dylib`
- `/System/Library/Frameworks/AppKit.framework/AppKit`
- `/System/Library/Frameworks/Foundation.framework/Foundation`
- `/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics`
- `/System/Library/Frameworks/CoreText.framework/CoreText`

Windows ではここで即時に失敗します。まず `Echoes::Platform` のような小さな判定層を作り、コア実装、GUI 実装、macOS 実装を遅延ロードできる形に分ける必要があります。

### 2. GUI バックエンドが AppKit 直結

`lib/echoes/gui.rb` は AppKit の window / view / menu / pasteboard / open panel / font / drawing / mouse / IME / timer / screen API を直接呼び出します。Windows 対応では、このファイルをそのまま拡張するより、少なくとも次の境界に分ける必要があります。

- window / event loop
- drawing / text measurement / font fallback
- clipboard / pasteboard
- file dialog / drag and drop
- preferences
- notification / URL open
- display enumeration / fullscreen window

Windows 側の候補は未実装です。Ruby から直接 Win32 API を Fiddle で呼ぶか、既存 GUI toolkit を使うかを先に決める必要があります。現在の機能量を考えると、描画と入力イベントを抽象化せずに Windows を足すと保守不能になります。

### 3. PTY とプロセス制御が Unix/macOS 前提

通常ペインは `lib/echoes/pane.rb` で `PTY.open`、`fork`、`Process.setsid`、`exec`、`TIOCSCTTY`、`TIOCSPGRP` を使っています。Windows Ruby には同じ意味の `fork` / Unix PTY / process group / ioctl がありません。

Windows では ConPTY (`CreatePseudoConsole`) を使う別実装が必要です。必要になる責務は次の通りです。

- 疑似コンソールの作成とリサイズ
- 子プロセス起動 (`cmd.exe`, PowerShell, pwsh など)
- stdin/stdout pipe の読み書き
- Ctrl-C 相当の配送
- cwd / env / PATH の扱い
- 終了検知とリソース解放

既存の `Pane` は表示ロジックもキーバインドも多く持っているため、まず「shell backend」インターフェイスを切り出し、macOS PTY backend と Windows ConPTY backend を差し替えられる形にするのが現実的です。

### 4. 組み込み rubish モードも Unix ジョブ制御前提

`EmbeddedShell` は helper subprocess に pty slave を制御端末として持たせる設計です。`embedded_shell_helper.rb` は `tcsetpgrp` と `TIOCSCTTY` に依存し、SIGINT / SIGQUIT の挙動も Unix process group 前提です。

Windows 対応では、組み込み rubish モードを初期スコープから外すか、通常ペインとは別に Windows 用 helper / interrupt / command execution モデルを設計する必要があります。最初のマイルストーンでは通常シェルのみを対象にし、embedded mode は macOS のみに明示的に制限するのが安全です。

### 5. `.app` バンドルとインストーラ

`Echoes.app` と `EchoesEmbed.app` は bash launcher と `Info.plist` を持つ macOS app bundle です。`lib/echoes/installer.rb` は `~/Applications` へ app wrapper をコピーします。

Windows では別の配布・起動経路が必要です。候補:

- gem executable のみをサポートする
- `.bat` / `.cmd` launcher を生成する
- 将来的に Windows 用 executable / installer を用意する

`echoes install` は OS 別に分岐し、Windows では未対応メッセージまたは Windows launcher 生成に切り替える必要があります。

### 6. 設定・永続化

`lib/echoes/preferences.rb` は `NSUserDefaults` 固定です。`lib/echoes/configuration.rb` の DSL 設定は `~/.config/echoes/echoes.conf` を読むため Windows でも動く可能性はありますが、Windows らしい場所ではありません。

必要対応:

- GUI preferences を OS 別 backend に分離する
- Windows では `%APPDATA%/Echoes` などを候補にする
- 既存 `~/.config/echoes/echoes.conf` 互換を残すか決める

### 7. 画像・フォント・描画

Kitty graphics / iTerm2 images は AppKit / CoreGraphics の PNG decode と CGImage 描画に依存しています。`lib/echoes/kitty_graphics.rb` は AppKit decoder を遅延ロードする形ですが、Windows 実装はありません。GUI のフォント計測も AppKit の `NSFont` / `NSString#sizeWithAttributes:` / CoreText fallback に依存します。

Windows 側では以下の代替が必要です。

- PNG decode
- RGBA buffer の描画
- 等幅セル幅・行高の計測
- Unicode fallback font の解決
- underline / strikethrough / bold / italic / ligature の扱い

### 8. テストが macOS / Unix コマンド前提

`test/test_helper.rb` が `require "echoes"` するため、現状のままだと Windows では大半のテストがロード段階で失敗します。さらに以下のような前提があります。

- `/bin/cat`, `/bin/sh`, `/bin/sleep`, `/bin/echo`, `/usr/bin/true`, `/usr/bin/env`, `/usr/bin/tput`
- AppKit を直接触る `gui_test.rb`, `objc_test.rb`, `preferences_test.rb`
- `Echoes.app` / `EchoesEmbed.app` を前提にする `installer_test.rb`
- macOS の `/tmp` 解決差を考慮したテストコメント

Windows 対応では、純粋な parser / screen / cell / copy mode / pane tree などの OS 非依存テストを先に分離し、OS 依存テストには skip 条件または backend 別 test helper を入れる必要があります。

## 対応方針

### フェーズ 1: OS 非依存コアをロード可能にする

- `Echoes::Platform` を追加し、`windows?`, `macos?`, `unix?` 程度の判定を集約する。
- `lib/echoes.rb` から `objc`, `preferences`, `gui` の無条件 require を外す。
- `exe/echoes` 側で GUI 起動時に OS 別 GUI backend を require する。
- Windows では GUI 未実装なら明確なエラーを出し、少なくとも `require "echoes"` と純粋ロジックのテストが通る状態にする。
- `test/test_helper.rb` を OS 非依存テスト用にし、AppKit が必要なテストは明示的に macOS helper を使う。

### フェーズ 2: shell backend 抽象化

- `Pane` から PTY 起動・読み書き・resize・alive・close を backend に切り出す。
- macOS 既存実装を `MacPtyBackend` のようなクラスへ移す。
- `Terminal` の `PTY.spawn` 依存も同じ抽象に寄せるか、Windows では一旦 `--tty` 非対応にする。
- backend contract をテストで固定する。

### フェーズ 3: Windows ConPTY backend

- Windows 用 backend を追加する。
- 起動対象 shell の初期値を Windows 用に決める。候補は `ENV["COMSPEC"]`, `pwsh`, `powershell.exe`。
- resize / read / write / close / process exit / Ctrl-C を実装する。
- 既存 parser / screen に流し込む byte stream が macOS PTY と同じように扱えるか確認する。

### フェーズ 4: GUI backend の設計と実装

- `GUI` の責務を、terminal state orchestration と AppKit rendering/event handling に分離する。
- Windows の GUI 技術を決める。Fiddle で Win32 + DirectWrite/GDI を叩く場合は既存 AppKit 実装に近いが実装量が大きい。toolkit 採用の場合は依存と配布方法の判断が必要。
- 最小版は、window、text drawing、keyboard input、clipboard、resize、timer から始める。
- IME、drag and drop、file dialog、multi-display presentation window、native notification は後続に回す。

### フェーズ 5: インストール・CI・ドキュメント

- `.github/workflows/main.yml` に Windows ジョブを追加する。ただし最初は OS 非依存テストだけを対象にする。
- `README.md` の Requirements / Installation / Development を OS 別に更新する。
- `echoes install` の Windows 動作を定義する。
- gemspec の説明文と post install message を OS 別実態に合わせる。

## 推奨する最初の実装タスク

1. `Echoes::Platform` を追加する。
2. `lib/echoes.rb` の require を分割し、Windows で `require "echoes"` が AppKit をロードしないようにする。
3. AppKit 必須テストを `skip unless Echoes::Platform.macos?` で隔離する。
4. `/bin/*` 前提のテストを OS 条件付きにするか、テスト用 command resolver を導入する。
5. CI に Windows の「コアテスト」ジョブを追加する。
6. `Pane` の shell backend 抽象を作り、現行 macOS 実装をそのまま backend に移す。
7. Windows ConPTY backend の spike を小さく作る。

## 注意点

- `lib/echoes/gui.rb` は 1 ファイルに多くの責務が集まっています。Windows 対応のために直接分岐を増やすと急速に読みにくくなるため、先に境界を作るべきです。
- embedded rubish mode は通常シェルより移植難度が高いです。Windows 初期対応の対象外にしても、通常ペインが動けば価値があります。
- OSC / parser / screen / copy mode / pane tree は比較的 OS 非依存です。ここを Windows CI で守れる状態にすると、その後の移植作業が進めやすくなります。
- `syslog` は gemspec に dependency としてありますが、現ソース上では利用箇所が見当たりませんでした。Windows 対応時に不要なら削除候補です。

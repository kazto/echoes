# Windows Porting Status

作成日: 2026-05-20

このメモは、macOS 専用実装から Windows 対応へ進めるための引き継ぎ資料です。2026-05-25 時点では、ロード境界、Windows core test、shell backend 抽象、Windows ConPTY backend の最小 read/write/resize/cwd/env/close、installer、preferences backend 分離、Windows GUI の描画・入力・clipboard・image rendering・font fallback・OSC notification 最小境界までは進んでいます。一方で embedded rubish mode、Ctrl-C 相当の配送、native toast notification は未完です。

## 現状

- Ruby gem 形式のターミナルエミュレータです。CLI 起点は `exe/echoes` で、GUI 起動時だけ OS 別 GUI backend を lazy load します。
- GUI は macOS AppKit 実装が中心で、Windows GUI はまだ最小実装段階です。
- Windows GUI の初期方針は Pure Ruby を維持するため Fiddle + Win32 API です。Win32 window / GDI text drawing / key input / resize / polling repaint loop / clipboard / mouse wheel scroll まで実装済みです。clipboard は `CF_UNICODETEXT` helper 経由で copy / paste と OSC 52 に対応済みです。text drawing は regular / bold / italic / bold-italic font selection、underline / strikethrough、wide-char continuation skip、OSC 66 multicell text 描画、GDI font fallback に対応済みです。OSC 9 / OSC 777 notification request は native toast ではなく Win32 window title に反映する最小境界として対応済みです。
- Windows の PNG decode は GDI+ を Fiddle で呼ぶ Pure Ruby 実装です。Kitty graphics と iTerm2 inline images は同じ GDI+ decoder で RGBA buffer へ変換し、Win32 GUI は GDI `StretchDIBits` で `screen.placements` を描画します。
- `require "echoes"` は Windows でも AppKit / CoreGraphics をロードしないように分離済みです。
- 通常ペインは `ShellBackend` 経由で shell process を扱います。macOS では既存 PTY backend、Windows では ConPTY backend を選べます。Windows ConPTY backend は console code page 由来の bytes を locale encoding から UTF-8 へ decode し、入力は UTF-8 から locale encoding へ encode します。
- TTY モードは backend 注入に寄せていますが、Windows ではまだ GUI/通常ペインほど検証していません。
- 組み込み rubish モードは `lib/echoes/embedded_shell.rb` と `lib/echoes/embedded_shell_helper.rb` で、`PTY.open`、制御 pipe、`Process.spawn`、`tcsetpgrp`、`TIOCSCTTY` を使ってジョブ制御を成立させています。
- インストーラは OS 別に分岐済みです。macOS では `~/Applications` に `Echoes.app` / `EchoesEmbed.app` のラッパーを作り、Windows では `~/bin/echoes.bat` を生成します。
- Preferences は OS 別 backend に分離済みです。macOS では `NSUserDefaults`、Windows では JSON file persistence を使います。
- CI には Windows core test job を追加済みです。ただしリモート CI の成功は未確認です。
- Windows ローカルでは `ruby -S rake test:core` が通過しています。2026-05-26 時点では 629 tests, 1356 assertions, 0 failures, 8 omissions です。`bundle exec rake ...` は `rubish` git checkout 不足で失敗するため、Windows core CI は暫定的に Bundler を使わない構成です。

## Windows 対応の主なブロッカー

### 1. 起動時の macOS 無条件ロード

`lib/echoes.rb` が `echoes/objc` と `echoes/gui` を無条件で読み込みます。`lib/echoes/objc.rb` はロード直後に以下を `Fiddle.dlopen` します。

- `/usr/lib/libobjc.A.dylib`
- `/System/Library/Frameworks/AppKit.framework/AppKit`
- `/System/Library/Frameworks/Foundation.framework/Foundation`
- `/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics`
- `/System/Library/Frameworks/CoreText.framework/CoreText`

この問題は Phase 1 で対応済みです。`Echoes::Platform` と lazy load 境界により、Windows で `require "echoes"` と OS 非依存テストを動かせる状態になっています。

### 2. GUI バックエンドが AppKit 直結

`lib/echoes/gui.rb` は AppKit の window / view / menu / pasteboard / open panel / font / drawing / mouse / IME / timer / screen API を直接呼び出します。Windows 対応では、このファイルをそのまま拡張するより、少なくとも次の境界に分ける必要があります。

- window / event loop
- drawing / text measurement / font fallback
- clipboard / pasteboard
- file dialog / drag and drop
- preferences
- notification / URL open
- display enumeration / fullscreen window

Windows 側は Pure Ruby 方針を維持するため、Fiddle + Win32 API で進めます。現在の機能量を考えると、描画と入力イベントを抽象化せずに Windows を足すと保守不能になるため、既存 AppKit 実装の責務分類と共通化は引き続き必要です。

### 3. PTY とプロセス制御が Unix/macOS 前提

通常ペインの macOS 実装は PTY / fork / process group / ioctl 前提ですが、現在は `ShellBackend` に切り出し済みです。Windows では `lib/echoes/conpty.rb` と `WindowsConPTYBackend` が ConPTY (`CreatePseudoConsole`) を使います。

Windows ConPTY backend で対応済み、または残っている責務は次の通りです。

- 疑似コンソールの作成とリサイズ: 実装済み。`cmd.exe mode con` で resize 反映を確認済み。
- 子プロセス起動 (`cmd.exe`, PowerShell, pwsh など): 初期 shell 解決と `cmd.exe` 起動は確認済み。
- stdin/stdout pipe の読み書き: 実装済み。stdout/stderr を ConPTY output pipe に明示し、stdin は ConPTY に任せる構成。
- 日本語などの locale encoded output: 実装済み。ConPTY 出力を locale encoding から UTF-8 へ decode し、入力を UTF-8 から locale encoding へ encode する。
- Ctrl-C 相当の配送: 未解決。`\x03` write と `GenerateConsoleCtrlEvent` は期待通りに効いていません。
- cwd / env / PATH の扱い: cwd と explicit env は確認済み。
- 終了検知とリソース解放: close / process exit は確認済み。

`Pane` は Windows で ConPTY backend を選ぶようになっています。`pane_test`, `tab_test`, `shell_backend_test` は Windows ローカルで通過済みです。

### 4. 組み込み rubish モードも Unix ジョブ制御前提

`EmbeddedShell` は helper subprocess に pty slave を制御端末として持たせる設計です。`embedded_shell_helper.rb` は `tcsetpgrp` と `TIOCSCTTY` に依存し、SIGINT / SIGQUIT の挙動も Unix process group 前提です。

Windows 対応では、組み込み rubish モードを初期スコープから外すか、通常ペインとは別に Windows 用 helper / interrupt / command execution モデルを設計する必要があります。最初のマイルストーンでは通常シェルのみを対象にし、embedded mode は macOS のみに明示的に制限するのが安全です。

### 5. `.app` バンドルとインストーラ

`Echoes.app` と `EchoesEmbed.app` は bash launcher と `Info.plist` を持つ macOS app bundle です。`lib/echoes/installer.rb` は macOS では `~/Applications` へ app wrapper をコピーします。

Windows では初期対応として `~/bin/echoes.bat` を生成します。これは gem-bundled launcher を `ruby ... %*` で呼ぶ薄い wrapper です。将来的に Windows 用 executable / installer を用意する余地はありますが、現時点では `.bat` launcher を採用しています。

### 6. 設定・永続化

`lib/echoes/preferences.rb` は OS 別 backend に分離済みです。`MacOSBackend` は既存の `NSUserDefaults` suite を維持し、`JsonBackend` は `%APPDATA%/Echoes/preferences.json` に保存します。テスト時や明示指定時は `ECHOES_CONFIG_HOME/preferences.json` を使います。JSON backend の保存先選択と round-trip はテスト済みです。

対応済み:

- GUI preferences を OS 別 backend に分離する
- Windows では `%APPDATA%/Echoes` を使う
- `Configuration` の DSL 設定は Windows では `%APPDATA%/Echoes/echoes.conf`、次に既存 `~/.config/echoes/echoes.conf` を読む

### 7. 画像・フォント・描画

Kitty graphics / iTerm2 images は macOS では AppKit / CoreGraphics の PNG decode と CGImage 描画に依存しています。Windows では GDI+ decoder で PNG / raw RGB / raw RGBA を RGBA buffer に変換し、GUI 上では GDI `StretchDIBits` で描画します。基本的な text style は GDI font selection と `FillRect` decoration で描画します。OSC 66 / OSC 7772 multicell text は GDI font と `TextOutW` で描画し、family 指定時の予約幅は `GetTextExtentPoint32W` で測ります。GUI の高度なフォント計測はまだ AppKit の `NSFont` / `NSString#sizeWithAttributes:` / CoreText fallback に依存します。

Windows 側では以下を実装済み、または後続対応とします。

- PNG decode: GDI+ decoder 実装済み
- RGBA buffer の描画: GDI `StretchDIBits` 実装済み
- 等幅セル幅・行高の計測: 実装済み
- Unicode fallback font の解決: `GetGlyphIndicesW` で base font に glyph がない文字を検出し、`Yu Gothic UI` / `Meiryo` / `Segoe UI Emoji` / `Segoe UI Symbol` / `MS Gothic` へ run 単位で切り替える。color emoji / complex shaping は GDI 依存の制限あり。
- underline / strikethrough / bold / italic: 実装済み
- ligature の扱い: 後続対応

Clipboard は Win32 `CF_UNICODETEXT` 経由の helper を追加済みです。

### 8. テストが macOS / Unix コマンド前提

初期状態では `test/test_helper.rb` が `require "echoes"` した時点で AppKit 依存をロードし、Windows では大半のテストがロード段階で失敗していました。現在は core test のロード境界を分離済みですが、フルテストにはまだ以下のような macOS / Unix 前提が残っています。

- `/bin/cat`, `/bin/sh`, `/bin/sleep`, `/bin/echo`, `/usr/bin/true`, `/usr/bin/env`, `/usr/bin/tput`
- AppKit を直接触る `gui_test.rb`, `objc_test.rb`
- `Echoes.app` / `EchoesEmbed.app` を前提にする macOS installer tests
- macOS の `/tmp` 解決差を考慮したテストコメント

Windows 対応では、純粋な parser / screen / cell / copy mode / pane tree などの OS 非依存テストを先に分離し、OS 依存テストには skip 条件または backend 別 test helper を入れる必要があります。現在は preferences tests と Windows installer tests も core 対象に含まれています。

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
- Windows の GUI 技術は Fiddle + Win32 API とする。Pure Ruby 方針を維持し、toolkit / native helper は現時点では採用しない。
- 最小版は、window、text drawing、keyboard input、clipboard、resize、timer から始める。これらは Win32 backend に実装済みで、clipboard は `CF_UNICODETEXT` helper と Ctrl+Shift+C/V 経路を追加済み。残る確認は実 GUI 上で Windows shell の起動、入力、出力、resize、copy/paste を手動確認すること。
- IME、drag and drop、file dialog、multi-display presentation window、native toast notification は後続に回す。OSC notification の最小境界は window title 反映として実装済み。

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

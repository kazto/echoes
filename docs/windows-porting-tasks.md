# Windows Porting Task List

作成日: 2026-05-20

元資料: `docs/windows-porting-status.md`

このタスクリストは、Windows 対応を進めるための作業項目を依存順に並べたものです。まず Windows で `require "echoes"` と OS 非依存テストを動かせる状態を作り、その後に shell backend、ConPTY、GUI、配布まわりへ進みます。

## 進捗メモ

更新日: 2026-05-22

- `feature/windows` ブランチで Phase 1 と Phase 2 の最小対応を進行中。
- `Echoes::Platform` を追加し、OS 判定と default shell 判定を集約済み。
- `ShakeDetector` を AppKit GUI から切り出し、Windows でも OS 非依存テストに含められる状態に更新済み。
- `rake test:core` を追加し、Windows では OS 非依存コアテストだけを実行する default test に更新済み。2026-05-22 時点で pane / tab / pane_tree / preferences / shell_backend / cli / installer も core 対象に追加済み。
- GitHub Actions に Windows core test job を追加済み。ただしリモート CI の成功はまだ未確認。
- Windows ローカル確認済み:
  - 2026-05-22: `ruby -S rake test:core`: 590 tests, 1254 assertions, 0 failures, 8 omissions
  - 2026-05-22: `ruby -S rake test`: 585 tests, 1247 assertions, 0 failures, 8 omissions
  - `ruby -Ilib -e "require 'echoes'; puts Echoes::VERSION"`: `0.2.0`
- 既知の未解決事項:
  - Windows ローカルでは `bundle exec rake ...` が `rubish` git checkout 不足で失敗する。Windows core CI は暫定的に Bundler を使わず `gem install rake test-unit` と `ruby -S rake test:core` で実行する。
  - macOS フルテストはこの作業環境では未実行。
  - 2026-05-22 追加調査: ConPTY backend で `cmd.exe` の初期出力、入力 echo、コマンド出力を pipe 経由で取得できることを確認。stdout/stderr を pseudoconsole output pipe に明示し、stdin は ConPTY に任せる必要がある。

## Phase 0: 作業前確認

- [ ] `bundle exec rake test` を macOS で実行し、現行ベースラインを確認する。
- [x] `git status --short` で未コミット差分を確認する。
- [x] Windows 対応の初期スコープを決める。
  - 推奨: 通常シェル + OS 非依存コアテストを最初の対象にする。
  - 後回し推奨: AppKit 相当のフル GUI、embedded rubish mode、画像表示、IME、インストーラ。
- [ ] Windows の対象 Ruby と対象 Windows バージョンを決める。
  - 暫定: ローカル検証は Ruby 4.0 / Windows で実施。
  - ConPTY を使う前提なら Windows 10 1809 以降が必要。

## Phase 1: OS 判定とロード境界

- [x] `lib/echoes/platform.rb` を追加し、`macos?`, `windows?`, `unix?` を定義する。
- [x] `lib/echoes.rb` で `echoes/objc`, `echoes/preferences`, `echoes/gui` を無条件 require しないようにする。
  - `preferences` は require 自体を残しつつ、内部で OS 別に安全に分岐する形に更新済み。
- [x] `exe/echoes` を修正し、GUI 起動時だけ OS 別 GUI backend を require する。
  - `Echoes::CLI` を追加し、`--tty` では GUI backend をロードしない構成に更新済み。
- [x] Windows で GUI 未実装の場合、`echoes` 実行時に明確な未対応メッセージを出す。
  - 非対応 platform では `Echoes.load_gui_backend` が明示的に `Echoes::Error` を出す。Windows では既存 `gui_win32` を lazy load する。
- [x] `require "echoes"` が Windows で AppKit / CoreGraphics をロードしないことを確認する。
- [x] `test/test_helper.rb` を OS 非依存テスト向けに整理する。
- [ ] AppKit 必須テスト用の helper を分ける。
- [x] AppKit 依存の `gui_test.rb`, `objc_test.rb` を macOS 限定で skip する。
  - `gui_test.rb` と `objc_test.rb` は macOS 限定に整理済み。
  - `preferences_test.rb` は JSON backend により Windows でも実行可能なため、macOS 限定にはしていない。
- [x] `/bin/*` や `/usr/bin/*` 前提のテストを洗い出し、OS 条件付きにする。
  - core 対象の shell command は `TestHelper::CAT_COMMAND` / `TRUE_COMMAND` 経由に整理済み。`editor_test` は `rvim` 依存のため core 対象外。
- [x] parser / screen / cell / copy mode / pane tree など OS 非依存テストだけを Windows で走らせるコマンドを用意する。
  - `ruby -S rake test:core` を追加済み。

## Phase 2: CI の最小 Windows ジョブ

- [x] `.github/workflows/main.yml` に Windows ジョブを追加する。
- [x] Windows ジョブでは、最初は OS 非依存テストだけを実行する。
- [x] macOS ジョブは既存のフルテストを維持する。
- [ ] CI 上で Bundler が `rubish-gem` / `rvim` を取得できるか確認する。
  - Windows core CI は暫定的に Bundler を使わない構成にしている。
- [ ] CI の Ruby バージョン表記と `CLAUDE.md` の記述差分を確認し、必要ならドキュメントを更新する。

## Phase 3: Shell Backend 抽象化

- [x] `Pane` から shell process の責務を切り出す。
  - 起動
  - 読み取り
  - 書き込み
  - resize
  - alive 判定
  - close
  - interrupt
- [x] macOS 既存実装を `MacPtyBackend` 相当のクラスへ移す。
- [x] `Pane` は backend の共通 API だけを呼ぶようにする。
- [ ] `Pane` の既存テストを backend 抽象後も macOS で通す。
  - Windows では `pane_test`, `tab_test`, `pane_tree_test` が通過済み。macOS は未確認。
- [x] backend contract の単体テストを追加する。
- [x] `Terminal` の `PTY.spawn` 依存を backend に寄せるか、Windows では `--tty` 未対応として明示する。
  - `Terminal` は `ShellBackend` を注入して起動する形に更新済み。
- [x] `EmbeddedShell` はこの段階では macOS 限定として明示的に分岐する。
  - Windows では `pty` require ではなく `Echoes::Error` で未対応を明示する。

## Phase 4: Windows ConPTY Spike

- [x] Windows 用 backend ファイルを追加する。
  - `WindowsConPTYBackend` を追加済み。既定の Windows backend はまだ安全な `WindowsPopenBackend` のまま。
- [x] ConPTY API 呼び出し方法を決める。
  - Ruby Fiddle で Win32 API を直接呼ぶ。
  - 候補: 既存 gem / native extension を利用する。
- [x] 疑似コンソール作成を実装する。
- [x] stdin / stdout pipe の作成と接続を実装する。
  - `ConPTY#read_available_output` / `ConPTY#write` を追加済み。
- [x] 子プロセス起動を実装する。
- [x] 初期 shell 解決を実装する。
  - 優先候補: `ENV["COMSPEC"]`
  - 次点候補: `pwsh`
  - 次点候補: `powershell.exe`
- [x] read / write が既存 parser に接続できることを確認する。
  - 2026-05-21 の手動確認では `cmd.exe` 起動後に pipe から shell 出力を取得できていない。次作業で ConPTY attribute / startup info の調査が必要。
  - 2026-05-22 の手動確認でも未解決。`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` の Fiddle signature を pointer-sized に修正し、process creation flags と pipe handle close 順序も調整したが、interactive `cmd.exe` の banner / prompt はまだ `ConPTY#read_available_output` から取得できていない。
  - `STARTUPINFOEXW` はこの環境では `STARTUPINFOW=104 bytes`, `STARTUPINFOEXW=112 bytes`, `lpAttributeList offset=104` と確認済み。
  - 解決: `STARTF_USESTDHANDLES` で stdout / stderr だけを ConPTY output pipe に向け、stdin は ConPTY に任せることで `cmd.exe` の banner / prompt / `echo` 出力を `ConPTY#read_available_output` から取得できた。
- [x] `WindowsConPTYBackend#pid` が process handle ではなく process id を返すようにする。
  - `ConPTY#h_process_id` を追加し、`PROCESS_INFORMATION.dwProcessId` を保持するように更新済み。
- [x] resize が ConPTY に反映されることを確認する。
  - `ConPTY#resize(100, 30)` 後に `cmd.exe` の `mode con` で 100 桁 / 30 行が反映されることを確認済み。
- [x] close 時に pipe / process / pseudoconsole handle を解放する。
  - `ConPTY#close` を追加し、process / thread / pseudoconsole / pipe handles をゼロクリアまで含めて解放するように更新済み。
- [ ] Ctrl-C 相当の配送方法を検証する。
  - `"\x03"` の input pipe write では、実行中の `ping` や Ruby child process を中断できないことを確認。
  - `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, process_id)` は API 上 true を返すが、ConPTY 内の実行中 child process までは中断できなかったため未採用。
- [x] 最小の Windows 手動確認手順を記録する。
  - `ruby "-Ilib" -r echoes/conpty -e "c=Echoes::ConPTY.new; c.spawn('cmd.exe', cols: 80, rows: 24); sleep 1; out=+''; out << c.read_available_output(4096).to_s; c.write(%Q(echo echoes-conpty\r\n)); sleep 1; out << c.read_available_output(4096).to_s; c.write(%Q(exit\r\n)); sleep 0.5; out << c.read_available_output(4096).to_s; c.kill; puts out.inspect; exit(out.include?('echoes-conpty') ? 0 : 1)"`

## Phase 5: Windows 通常ペイン統合

- [x] `Pane` で Windows の場合に ConPTY backend を選ぶ。
  - `Pane` は Windows では `ShellBackend.for_platform(windows_backend: :conpty)` を使う。
- [x] Windows の default shell を設定する。
  - `Platform.default_shell` で `ENV["COMSPEC"]`, `pwsh`, `powershell.exe` の順に解決する。
- [x] cwd 指定が Windows backend に渡るようにする。
  - `Pane` の `cwd:` 指定は spawn 時の `Dir.chdir` により ConPTY child に反映されることを確認済み。
- [x] env 指定が Windows backend に渡るようにする。
  - `CreateProcessW` 用の UTF-16 environment block を Pure Ruby で構築し、`CREATE_UNICODE_ENVIRONMENT` 付きで渡す。
- [x] `Pane#read_available_output` が Windows backend でも非ブロッキングに動くことを確認する。
- [x] `Pane#resize` が Windows backend でも例外なく動くことを確認する。
- [x] `Pane#close` が Windows backend でもプロセスを残さないことを確認する。
- [x] Windows backend 用の最小統合テストを追加する。
  - `WindowsConPTYBackend` で `cmd.exe` の read/write と explicit env を確認する Windows 限定テストを追加済み。

## Phase 6: 設定と Preferences

- [x] `Preferences` を OS 別 backend に分ける。
  - `MacOSBackend` は `NSUserDefaults`、`JsonBackend` は JSON file persistence を担当する。
- [x] macOS backend は既存 `NSUserDefaults` 実装を維持する。
- [x] Windows backend の保存場所を決める。
  - `%APPDATA%/Echoes/preferences.json`。`ECHOES_CONFIG_HOME` 指定時はその配下の `preferences.json`。
- [x] `Configuration::CONFIG_PATH` の Windows での扱いを決める。
  - 互換維持: `~/.config/echoes/echoes.conf` も読む。
  - Windows 標準: `%APPDATA%/Echoes/echoes.conf` を読む。
- [x] 設定ファイル探索順をドキュメント化する。
  - 探索順は `ECHOES_CONFIG_HOME/echoes.conf` が最優先。通常 Windows では `%APPDATA%/Echoes/echoes.conf`、次に legacy `~/.config/echoes/echoes.conf` を読む。
- [x] Windows backend の preference 読み書きテストを追加する。
  - platform backend の round-trip に加えて、`JsonBackend` の `ECHOES_CONFIG_HOME` / `%APPDATA%` 保存先選択を確認する。

## Phase 7: GUI Backend 設計

- [ ] `lib/echoes/gui.rb` の責務を分類する。
  - application / event loop
  - window / view
  - drawing
  - font metrics
  - keyboard / mouse
  - clipboard
  - file dialog / drag and drop
  - notifications / URL open
  - display enumeration
- [ ] OS 非依存にできる terminal orchestration を切り出す。
- [ ] AppKit 実装を macOS backend として残す。
- [x] Windows GUI 技術を決める。
  - Fiddle + Win32 API
  - Pure Ruby 方針を維持するため、初期実装は Fiddle + Win32 API を採用する。
  - toolkit / native helper は現時点では採用しない。
- [x] Windows GUI の最小機能セットを決める。
  - window
  - text drawing
  - keyboard input
  - resize
  - timer
  - clipboard
  - 初期最小機能は Win32 window / GDI text drawing / key input / resize / polling repaint loop / clipboard とする。
- [ ] IME、drag and drop、file dialog、multi-display、notification の対応順を決める。

## Phase 8: Windows GUI 最小実装

- [x] Windows window / event loop を実装する。
  - `CreateWindowExW` と `PeekMessageW` ベースの non-blocking message loop を実装済み。
- [x] セルグリッドの描画を実装する。
  - GDI `TextOutW` で screen grid を描画する。
- [x] 等幅フォントの測定を実装する。
  - `CreateFontW` と `GetTextExtentPoint32W` で初期 cell metrics を取得する。
- [x] 基本キー入力を `Pane` に渡す。
  - `WM_CHAR` と `WM_KEYDOWN` の基本キー / 矢印 / Ctrl キー入力を `Pane#write_input` に渡す。
- [x] resize イベントを `Pane#resize` に渡す。
  - `WM_SIZE` から rows / cols を再計算して active tab を resize する。
- [x] timer / repaint loop を実装する。
  - message loop 内で shell output を polling し、出力時に `InvalidateRect` / `UpdateWindow` する。
- [x] clipboard copy / paste を実装する。
  - `CF_UNICODETEXT` を使う Win32 clipboard helper を追加し、OSC 52 と Ctrl+Shift+C/V 経路から利用する。
- [ ] 最小 GUI で Windows shell が起動し、入力と出力ができることを確認する。

## Phase 9: 画像・フォント拡張

- [ ] Windows 用 PNG decode 方針を決める。
- [ ] Kitty graphics の Windows decode / render backend を追加する。
- [ ] iTerm2 images の Windows decode / render backend を追加する。
- [ ] Unicode fallback font の解決を実装する。
- [ ] bold / italic / underline / strikethrough の描画差を確認する。
- [ ] OSC 66 proportional text の Windows 対応可否を判断する。

## Phase 10: Installer と配布

- [x] `echoes install` を OS 別に分岐する。
  - macOS では `.app` wrapper、Windows では `echoes.bat` wrapper を生成する。
- [x] Windows 初期対応では、未対応メッセージにするか launcher 生成にするか決める。
  - 初期対応では `.bat` launcher 生成を採用する。
- [x] launcher を生成する場合、`.cmd` または `.bat` の出力先を決める。
  - 既定では `~/bin/echoes.bat` に生成する。`target_dir:` 指定で差し替え可能。
- [x] gemspec の summary / description / post install message を Windows 対応状況に合わせて更新する。
- [x] `README.md` の Requirements / Installation / Development を OS 別に更新する。
- [x] `.app` 専用の説明を macOS セクションに移す。
  - README には macOS `.app` wrapper と Windows `echoes.bat` wrapper の説明を分けて記載済み。

## Phase 11: Embedded Rubish Mode

- [x] Windows 初期リリースで embedded mode を対象に含めるか決める。
  - 初期 Windows 対応では embedded rubish mode は対象外にする。
- [x] 対象外にする場合、Windows で `ECHOES_EMBED=1` を指定したときの明確なエラーを実装する。
  - `EmbeddedShell` と Windows GUI 初期化の両方で unsupported error を出す。
- [ ] 対象にする場合、Windows 用 helper のプロセス制御モデルを設計する。
- [ ] Ctrl-C / command interruption / history / cwd 通知の Windows 仕様を決める。
- [x] embedded mode の Windows 専用テストを追加する。
  - `embedded_shell_test.rb` と `gui_test.rb` で Windows の unsupported error を確認する。

## Phase 12: 最終確認

- [ ] macOS フルテストを実行する。
- [x] Windows コアテストを実行する。
  - ローカルで `ruby -S rake test:core` 成功。2026-05-21 時点: 563 tests, 1215 assertions。
  - Terminal / EmbeddedShell の Phase 3 対応後: 566 tests, 1223 assertions。
  - ConPTY backend adapter 追加後: 570 tests, 1233 assertions。
  - ConPTY handle cleanup 修正後: 572 tests, 1235 assertions。
  - Windows installer test を core 対象に追加後: 585 tests, 1247 assertions, 8 omissions。
  - Preferences backend 分離テスト追加後: 587 tests, 1251 assertions, 8 omissions。
  - Windows GUI clipboard helper 追加後: 589 tests, 1253 assertions, 8 omissions。
  - Windows GUI copy/paste 経路テスト追加後: 590 tests, 1254 assertions, 8 omissions。
- [x] Windows backend テストを実行する。
  - `ruby "-Ilib;test" test/echoes/shell_backend_test.rb`: 7 tests, 14 assertions, 0 failures。
  - `pane_test.rb`, `tab_test.rb` も ConPTY backend 統合後に通過済み。
- [ ] Windows GUI 手動確認を実施する。
- [x] `README.md` と `docs/windows-porting-status.md` を最新状態に更新する。
- [ ] 未対応機能を明示したリリースノート草案を作る。

## 初回マイルストーンの完了条件

- [x] Windows で `require "echoes"` が成功する。
- [ ] Windows CI で OS 非依存テストが通る。
  - CI job は追加済み。リモート実行結果は未確認。
- [ ] macOS の既存 GUI / PTY テストが壊れていない。
- [x] AppKit 依存テストが macOS 限定として明示されている。
- [ ] 次の作業者が ConPTY backend に着手できる状態になっている。


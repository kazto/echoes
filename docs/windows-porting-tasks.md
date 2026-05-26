# Windows Porting Task List

作成日: 2026-05-20

元資料: `docs/windows-porting-status.md`

このタスクリストは、Windows 対応を進めるための作業項目を依存順に並べたものです。まず Windows で `require "echoes"` と OS 非依存テストを動かせる状態を作り、その後に shell backend、ConPTY、GUI、配布まわりへ進みます。

## 進捗メモ

更新日: 2026-05-25

- `feature/windows` ブランチで Phase 1 と Phase 2 の最小対応を進行中。
- `Echoes::Platform` を追加し、OS 判定と default shell 判定を集約済み。
- `ShakeDetector` を AppKit GUI から切り出し、Windows でも OS 非依存テストに含められる状態に更新済み。
- `rake test:core` を追加し、Windows では OS 非依存コアテストだけを実行する default test に更新済み。2026-05-22 時点で pane / tab / pane_tree / preferences / shell_backend / cli / installer も core 対象に追加済み。
- GitHub Actions に Windows core test job を追加済み。ただしリモート CI の成功はまだ未確認。
- Windows ローカル確認済み:
  - 2026-05-22: `ruby -S rake test:core`: 594 tests, 1265 assertions, 0 failures, 8 omissions
  - 2026-05-22: `ruby -S rake test`: 585 tests, 1247 assertions, 0 failures, 8 omissions
  - `ruby -Ilib -e "require 'echoes'; puts Echoes::VERSION"`: `0.2.0`
- 既知の未解決事項:
  - Windows ローカルでは `bundle exec rake ...` が `rubish` git checkout 不足で失敗する。Windows core CI は暫定的に Bundler を使わず `gem install rake test-unit` と `ruby -S rake test:core` で実行する。
  - macOS フルテストはこの作業環境では未実行。
  - 2026-05-22 追加調査: ConPTY backend で `cmd.exe` の初期出力、入力 echo、コマンド出力を pipe 経由で取得できることを確認。stdout/stderr を pseudoconsole output pipe に明示し、stdin は ConPTY に任せる必要がある。
  - 2026-05-25 追加調査: `cmd.exe` が初回入力時に返す `ESC[?25l ESC[2J ESC[m ESC[H` 系の repaint prefix と、Backspace 時に返す home erase repaint を backend で補正し、`d` 入力後と `dir` 入力後の Backspace が parser 上でプロンプト行を壊さないことを確認。
  - 2026-05-25 追加調査: Win32 GUI resize helper / tab cleanup helper の切り出しとテスト化。`ruby -S rake test:core`: 610 tests, 1319 assertions, 0 failures, 8 omissions。
  - 2026-05-25 追加調査: ConPTY Ctrl-C / child process cleanup の詳細検証（後述）。
  - 2026-05-25 追加調査: Windows GUI 手動 smoke を実施。起動、`d` 入力、`dir` 入力後の Backspace、Enter 後の出力、resize 後の表示維持、終了後 cleanup を確認。resize 時に ConPTY が返す full-screen repaint を backend で破棄する補正を追加。`ruby -S rake test:core`: 611 tests, 1320 assertions, 0 failures, 8 omissions。
  - 2026-05-25 追加調査: `CreateToolhelp32Snapshot` ベースの process tree cleanup を追加。`ConPTY#kill` で root `cmd.exe` の子孫を深い順に `TerminateProcess` してから root を終了する。marker 付き `ruby -e "sleep 60"` を `cmd.exe` 配下で起動し、`ConPTY#kill` 後に `Win32_Process` で残存しないことを確認。
  - 2026-05-25 追加調査: Windows GUI の GDI font fallback を追加。`GetGlyphIndicesW` で base font に glyph がない文字を検出し、`Yu Gothic UI` / `Meiryo` / `Segoe UI Emoji` / `Segoe UI Symbol` / `MS Gothic` へ run 単位で切り替える。emoji は GDI が glyph を報告しない場合でも `Segoe UI Emoji` を優先する。
  - 2026-05-25 追加調査: Windows GUI の OSC 9 / OSC 777 notification handler を追加。初期実装では native toast ではなく、通知 title / message を Win32 window title に反映する最小境界とする。
  - 2026-05-25 追加調査: Windows GUI の IME composition 更新処理を helper 化し、`GCS_COMPSTR` 有無、composition string 更新、空文字時の marked text clearing をテストで固定。
  - 2026-05-25 追加調査: Windows GUI の IME marked text 描画を GDI font fallback 経路に接続。通常セル描画と同じ `font_runs_for_text` で日本語 composition 文字列を fallback font run に分割して描画する。
  - 2026-05-26 追加調査: Windows GUI の mouse wheel scroll を追加。`WM_MOUSEWHEEL` を処理し、active pane の `scroll_offset` を scrollback 範囲で clamp して更新する。
  - 2026-05-26 追加調査: Windows GUI の pane input helper を追加。スクロール中の key input / paste で `scroll_offset` と `scroll_accum` を live output に戻してから shell へ送る。
  - 2026-05-26 追加調査: Windows ConPTY backend の日本語文字化けを修正。ConPTY の console code page 由来 bytes を locale encoding から UTF-8 へ decode し、入力は UTF-8 から locale encoding へ encode する。newline normalizer は non-ASCII byte を壊さないよう binary buffer に変更。

## 引き継ぎ用残タスクまとめ

更新日: 2026-05-25

直近で優先する作業:

- [x] 現在の未コミット差分をレビューしてコミットする。
  - commit `e75b39a`: Win32 GUI resize helper / tab cleanup helper の切り出しとテスト化。
- [x] `feature/windows` の未 push commits を push する。
  - 2026-05-25 確認時点で `feature/windows...origin/feature/windows` は ahead なし。`git log --oneline origin/feature/windows..HEAD` も空。
- [x] Windows GUI を手動起動して、最小操作を確認する。
  - 起動直後に `cmd.exe` banner / prompt が表示される。
  - `d` を 1 文字入力しても prompt が消えない。
  - `dir` 入力後、Backspace 3 回で prompt 末尾へ戻り、カーソルが行頭へ飛ばない。
  - Enter でコマンド出力が表示される。
  - resize 後も表示が崩れず、終了後に `cmd.exe` / ConPTY process が残らない。
- [x] Windows GUI 手動確認の結果を `Phase 8` と `Phase 12` に反映する。
  - 確認コマンドは `ruby -Ilib exe\echoes`。自動化補助で Win32 window にキー入力し、`tmp/gui-smoke/*.png` のスクリーンショットで表示を確認。
  - 初回 resize 確認で ConPTY resize repaint により画面が `dir` のみになる崩れを再現。`WindowsConPTYBackend` で `cmd.exe` resize repaint を破棄する補正を追加し、修正後に `dir` listing が維持されることを確認。

リリース前に必要な確認:

- [ ] Windows CI の実行結果を確認する。
  - CI job は追加済みだが、リモート実行結果は未確認。
  - Windows では Bundler を避ける暫定構成なので、CI の Ruby version と dependency install が現状に合っているか確認する。
- [ ] macOS 側のフルテストを実行する。
  - 少なくとも `bundle exec rake test` または既存 macOS CI と同等のコマンドで、AppKit GUI / PTY 既存挙動が壊れていないことを確認する。
  - `Pane` backend 抽象化後の macOS `pane_test`, `tab_test`, GUI 関連テストの通過を明記する。
- [ ] README / `docs/windows-porting-status.md` / リリースノート草案を最終状態に合わせる。
  - Windows で対応済みの範囲: 通常 shell, ConPTY, 最小 Win32 GUI, clipboard, resize, image rendering。
  - 未対応または制限あり: embedded rubish mode, Ctrl-C interruption, IME の完全対応, drag and drop, file dialog, native toast notification, color emoji / complex shaping。

後続の実装タスク:

- [x] Ctrl-C / command interruption の Windows 仕様を決める。
  - 2026-05-25 詳細検証結果:
    - **`\x03` via ConPTY pipe**: `ping -t` や `trap(:INT)` 付き Ruby を中断できない。cmd.exe 直下でも直接 ConPTY child でも同様。プロンプト入力のキャンセル（行内 `^C`）としては動作する。
    - **`AttachConsole(pid)` + `GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)`**: API は成功を返すが、ConPTY 内の子プロセスには届かない。
    - **`AttachConsole(pid)` + `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, pid)`**: 同上。API 成功だが効果なし。
    - **`AttachConsole(pid)` + `WriteConsoleInputW` via `CONIN$`**: `CONIN$` を `GENERIC_WRITE` で開いて `KEY_EVENT` (Ctrl+C) を書き込むと API は成功 (ret=1, written=1) するが、ConPTY の signal dispatch が発火せず子プロセスは中断されない。
    - **`Job Object` + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`**: Job 作成・プロセス割り当ては成功するが、Job handle close 後も cmd.exe の孫プロセス (ruby.exe) が残る。ConPTY child だけが Job に属し、孫プロセスは含まれないため。
  - **結論**: ConPTY は console の Ctrl-C signal dispatch mechanism を pseudo console 内で再現しない。これは Windows API の根本的な制限。
  - **決定**:
    - Ctrl-C での実行中コマンド中断は、初期リリースでは制限事項として明記する。
    - child process cleanup は `CreateToolhelp32Snapshot` でプロセスツリーを列挙して `TerminateProcess` する helper を追加済み。
    - 将来的に ConPTY 以外の仕組み (WinPTY helper 等) を検討する。
- [x] Unicode fallback font を実装する。
  - GDI renderer のまま、`GetGlyphIndicesW` で glyph 不在を検出して fallback font run に分割する。
  - CJK は `Yu Gothic UI` / `Meiryo` / `MS Gothic`、emoji / symbols は `Segoe UI Emoji` / `Segoe UI Symbol` を優先する。
  - 制限: color emoji / complex shaping は GDI 依存。完全対応が必要なら DirectWrite 移行を後続で検討する。
- [ ] IME、drag and drop、file dialog、multi-display、native toast notification の対応順を決める。
  - IME は composition 表示の最小実装と composition string 更新 helper のテストがあるが、確定文字列・候補 UI・日本語入力の実機確認が必要。
  - drag and drop / file dialog / native toast notification は Windows GUI では未整理。OSC notification は window title 反映の最小境界のみ実装済み。
- [ ] GUI backend 設計整理を進める。
  - `lib/echoes/gui.rb` の責務分類、OS 非依存 terminal orchestration の切り出し、AppKit backend と Win32 backend の境界整理が未完了。
- [ ] Embedded Rubish Mode の Windows 対応方針を再検討する。
  - 初期 Windows 対応では対象外。対象にする場合は helper process の pty / process control / history / cwd 通知を設計する。

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
- [x] Ctrl-C 相当の配送方法を検証する。
  - `"\x03"` の input pipe write では、実行中の `ping` や Ruby child process を中断できないことを確認。
  - `GenerateConsoleCtrlEvent(CTRL_C_EVENT / CTRL_BREAK_EVENT)` は API 上 true を返すが、ConPTY 内の child process までは届かない。
  - `WriteConsoleInputW` で `CONIN$` に `KEY_EVENT Ctrl+C` を書き込んでも、ConPTY の signal dispatch は発火しない。
  - `Job Object` + `KILL_ON_JOB_CLOSE` は ConPTY 直接 child だけに適用され、孫プロセスは対象外。
  - **根本原因**: ConPTY は console の Ctrl-C signal dispatch mechanism を pseudo console 内で再現しない。Windows API の制限。
  - **対応**: `ConPTY#kill` で `CreateToolhelp32Snapshot` から root PID の子孫を列挙し、深い順に `TerminateProcess` してから root `cmd.exe` を終了する。
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
  - `cmd.exe` の初回入力 repaint prefix 除去、Backspace 時の home erase repaint 補正、ConPTY 出力の LF 正規化テストを追加済み。
  - ConPTY process tree cleanup の単体テストと、marker 付き `ruby -e "sleep 60"` を使った残存確認 smoke を追加確認済み。
  - ConPTY の locale encoding decode / encode を追加し、`dir /b` の日本語 filename が UTF-8 として parser に渡ることを Windows 限定テストで確認済み。

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
- [ ] IME、drag and drop、file dialog、multi-display、native toast notification の対応順を決める。

## Phase 8: Windows GUI 最小実装

- [x] Windows window / event loop を実装する。
  - `CreateWindowExW` と `PeekMessageW` ベースの non-blocking message loop を実装済み。
  - `WM_DESTROY` / run loop 終了時に tabs を close し、ConPTY / shell process を残さない cleanup を追加済み。
- [x] セルグリッドの描画を実装する。
  - GDI `TextOutW` で screen grid を描画する。
  - 各 pane 描画前に default background で pane 全体をクリアし、行が短くなった場合の残像を避ける。
- [x] 等幅フォントの測定を実装する。
  - `CreateFontW` と `GetTextExtentPoint32W` で初期 cell metrics を取得する。
- [x] 基本キー入力を `Pane` に渡す。
  - `WM_CHAR` と `WM_KEYDOWN` の基本キー / 矢印 / Ctrl キー入力を `Pane#write_input` に渡す。
  - Win32 special key mapping を `windows_key_sequence` に切り出し、Backspace が `DEL(0x7F)` として送られることを含めてテストで固定済み。
- [x] resize イベントを `Pane#resize` に渡す。
  - `WM_SIZE` から rows / cols を再計算して active tab を resize する。
  - pixel size から cell rows / cols への変換を `handle_window_resize_pixels` に切り出し、cell metrics 未確定時と同一サイズ時に no-op になることをテスト済み。
- [x] timer / repaint loop を実装する。
  - message loop 内で shell output を polling し、出力時に `InvalidateRect` / `UpdateWindow` する。
  - active pane output polling を `poll_active_pane_output` に切り出し、parser feed / empty output / inactive pane の挙動をテストで固定済み。
- [x] clipboard copy / paste を実装する。
  - `CF_UNICODETEXT` を使う Win32 clipboard helper を追加し、OSC 52 と Ctrl+Shift+C/V 経路から利用する。
- [x] OSC notification の最小境界を実装する。
  - OSC 9 / OSC 777 notification request を screen handler 経由で受け、Win32 window title に `title - message` として反映する。
  - native toast notification は後続対応に回す。
- [x] IME composition 更新処理をテスト可能にする。
  - `WM_IME_COMPOSITION` から `update_ime_composition` helper に切り出し、`GCS_COMPSTR` がある場合だけ `ImmGetCompositionStringW` 由来の文字列で `@marked_text` を更新する。
  - composition string が空なら `@marked_text` を clear する。
- [x] IME marked text を fallback font で描画する。
  - IME inline composition overlay も通常セル描画と同じ `font_runs_for_text` を使い、日本語など base font に glyph がない文字を fallback font で描画する。
- [x] mouse wheel で scrollback をスクロールできるようにする。
  - `WM_MOUSEWHEEL` を受け、mouse tracking が off の通常状態では active pane の `scroll_offset` を更新する。
  - offset は `screen.scrollback.size` 範囲に clamp する。
- [x] 入力時に scrollback 表示から live output へ戻す。
  - key input / paste は `write_pane_input` helper 経由で `scroll_offset = 0`、`scroll_accum = 0.0` に戻してから shell へ送る。
- [ ] 最小 GUI で Windows shell が起動し、入力と出力ができることを確認する。

## Phase 9: 画像・フォント拡張

- [x] Windows 用 PNG decode 方針を決める。
  - Pure Ruby から Fiddle で GDI+ を呼び、PNG を RGBA buffer に変換する。
- [x] Kitty graphics の Windows decode / render backend を追加する。
  - `kitty_graphics_win32.rb` の GDI+ decoder で PNG / raw RGB / raw RGBA を `{rgba:, width:, height:}` に揃える。
  - `gui_win32.rb` は `screen.placements` の RGBA buffer を GDI `StretchDIBits` で描画する。
- [x] iTerm2 images の Windows decode / render backend を追加する。
  - iTerm2 inline images は Kitty graphics と同じ GDI+ PNG decoder を使う。
  - render は Kitty graphics と同じ `screen.placements` / GDI blit 経路を使う。
- [x] Unicode fallback font の解決を実装する。
  - `GetGlyphIndicesW` ベースで fallback font を選び、同じ text run 内でも font ごとに分割して `TextOutW` する。
  - 実 GDI smoke で Consolas から CJK / emoji fallback font が選ばれることを確認済み。
- [x] bold / italic / underline / strikethrough の描画差を確認する。
  - Windows GUI は GDI font を regular / bold / italic / bold-italic で切り替え、underline / strikethrough はセル幅に合わせて `FillRect` で描画する。
- [x] OSC 66 proportional text の Windows 対応可否を判断する。
  - 対応する。Windows GUI は multicell text anchor を GDI font / `TextOutW` で描画し、family 指定がある場合は `GetTextExtentPoint32W` を使う glyph measurer で予約幅を決める。

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
  - Windows GDI+ PNG decoder 追加後: 592 tests, 1259 assertions, 8 omissions。
  - Windows GUI image blit 追加後: 594 tests, 1265 assertions, 8 omissions。
  - Windows GUI text style 描画追加後: 596 tests, 1271 assertions, 8 omissions。
  - Windows GUI OSC 66 multicell text 描画追加後: 597 tests, 1275 assertions, 8 omissions。
  - ConPTY repaint / Backspace 補正後: 602 tests, 1282 assertions, 8 omissions。
  - Win32 key mapping テスト追加後: 604 tests, 1298 assertions, 8 omissions。
  - Win32 output polling テスト追加後: 606 tests, 1305 assertions, 8 omissions。
  - Win32 pane background clear テスト追加後: 607 tests, 1306 assertions, 8 omissions。
  - Win32 GUI tab cleanup テスト追加後: 608 tests, 1310 assertions, 8 omissions。
  - Win32 resize helper テスト追加後: 610 tests, 1319 assertions, 8 omissions。
  - ConPTY process tree cleanup テスト追加後: 612 tests, 1321 assertions, 0 failures, 8 omissions。
  - Windows GUI font fallback テスト追加後: 615 tests, 1325 assertions, 0 failures, 8 omissions。
  - Windows GUI notification handler テスト追加後: 617 tests, 1327 assertions, 0 failures, 8 omissions。
  - Windows GUI IME composition helper テスト追加後: 620 tests, 1333 assertions, 0 failures, 8 omissions。
  - Windows GUI IME marked text fallback 描画テスト追加後: 621 tests, 1335 assertions, 0 failures, 8 omissions。
  - Windows GUI mouse wheel scroll テスト追加後: 623 tests, 1343 assertions, 0 failures, 8 omissions。
  - Windows GUI input snap-to-bottom テスト追加後: 624 tests, 1346 assertions, 0 failures, 8 omissions。
  - Windows ConPTY locale encoding テスト追加後: 627 tests, 1351 assertions, 0 failures, 8 omissions。
- [x] Windows backend テストを実行する。
  - `ruby "-Ilib;test" test/echoes/shell_backend_test.rb`: 7 tests, 14 assertions, 0 failures。
  - 2026-05-25: `ruby -Itest -Ilib test\echoes\shell_backend_test.rb`: 12 tests, 21 assertions, 0 failures。
  - ConPTY process tree cleanup テスト追加後: `ruby -Itest -Ilib test\echoes\shell_backend_test.rb`: 14 tests, 23 assertions, 0 failures。
  - Windows ConPTY locale encoding テスト追加後: `ruby -Itest -Ilib test\echoes\shell_backend_test.rb`: 17 tests, 28 assertions, 0 failures。
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


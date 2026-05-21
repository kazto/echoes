# Windows Porting Task List

作成日: 2026-05-20

元資料: `docs/windows-porting-status.md`

このタスクリストは、Windows 対応を進めるための作業項目を依存順に並べたものです。まず Windows で `require "echoes"` と OS 非依存テストを動かせる状態を作り、その後に shell backend、ConPTY、GUI、配布まわりへ進みます。

## 進捗メモ

更新日: 2026-05-21

- `feature/windows` ブランチで Phase 1 と Phase 2 の最小対応を進行中。
- `Echoes::Platform` を追加し、OS 判定と default shell 判定を集約済み。
- `ShakeDetector` を AppKit GUI から切り出し、Windows でも OS 非依存テストに含められる状態に更新済み。
- `rake test:core` を追加し、Windows では OS 非依存コアテストだけを実行する default test に更新済み。2026-05-21 時点で pane / tab / pane_tree / preferences / shell_backend / cli も core 対象に追加済み。
- GitHub Actions に Windows core test job を追加済み。ただしリモート CI の成功はまだ未確認。
- Windows ローカル確認済み:
  - `ruby -S rake test:core`: 566 tests, 1223 assertions, 0 failures, 0 errors
  - `ruby -S rake test`: 566 tests, 1223 assertions, 0 failures, 0 errors
  - `ruby -Ilib -e "require 'echoes'; puts Echoes::VERSION"`: `0.2.0`
- 既知の未解決事項:
  - Windows ローカルでは `bundle exec rake ...` が `rubish` git checkout 不足で失敗する。Windows core CI は暫定的に Bundler を使わず `gem install rake test-unit` と `ruby -S rake test:core` で実行する。
  - macOS フルテストはこの作業環境では未実行。

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
  - core 対象の shell command は `TestHelper::CAT_COMMAND` / `TRUE_COMMAND` 経由に整理済み。`editor_test` は `rvim` 依存、`installer_test` は macOS bundle 前提のため core 対象外。
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

- [ ] Windows 用 backend ファイルを追加する。
- [ ] ConPTY API 呼び出し方法を決める。
  - 候補: Ruby Fiddle で Win32 API を直接呼ぶ。
  - 候補: 既存 gem / native extension を利用する。
- [ ] 疑似コンソール作成を実装する。
- [ ] stdin / stdout pipe の作成と接続を実装する。
- [ ] 子プロセス起動を実装する。
- [ ] 初期 shell 解決を実装する。
  - 優先候補: `ENV["COMSPEC"]`
  - 次点候補: `pwsh`
  - 次点候補: `powershell.exe`
- [ ] read / write が既存 parser に接続できることを確認する。
- [ ] resize が ConPTY に反映されることを確認する。
- [ ] close 時に pipe / process / pseudoconsole handle を解放する。
- [ ] Ctrl-C 相当の配送方法を検証する。
- [ ] 最小の Windows 手動確認手順を記録する。

## Phase 5: Windows 通常ペイン統合

- [ ] `Pane` で Windows の場合に ConPTY backend を選ぶ。
- [ ] Windows の default shell を設定する。
- [ ] cwd 指定が Windows backend に渡るようにする。
- [ ] env 指定が Windows backend に渡るようにする。
- [ ] `Pane#read_available_output` が Windows backend でも非ブロッキングに動くことを確認する。
- [ ] `Pane#resize` が Windows backend でも例外なく動くことを確認する。
- [ ] `Pane#close` が Windows backend でもプロセスを残さないことを確認する。
- [ ] Windows backend 用の最小統合テストを追加する。

## Phase 6: 設定と Preferences

- [ ] `Preferences` を OS 別 backend に分ける。
- [ ] macOS backend は既存 `NSUserDefaults` 実装を維持する。
- [x] Windows backend の保存場所を決める。
  - 候補: `%APPDATA%/Echoes/preferences.json`
- [ ] `Configuration::CONFIG_PATH` の Windows での扱いを決める。
  - 互換維持: `~/.config/echoes/echoes.conf` も読む。
  - Windows 標準: `%APPDATA%/Echoes/echoes.conf` を読む。
- [ ] 設定ファイル探索順をドキュメント化する。
- [x] Windows backend の preference 読み書きテストを追加する。
  - テストでは `ECHOES_CONFIG_HOME` で repo 内の `tmp/test-config` に保存先を差し替える。

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
- [ ] Windows GUI 技術を決める。
  - Fiddle + Win32 API
  - toolkit 採用
  - native helper 採用
- [ ] Windows GUI の最小機能セットを決める。
  - window
  - text drawing
  - keyboard input
  - resize
  - timer
  - clipboard
- [ ] IME、drag and drop、file dialog、multi-display、notification の対応順を決める。

## Phase 8: Windows GUI 最小実装

- [ ] Windows window / event loop を実装する。
- [ ] セルグリッドの描画を実装する。
- [ ] 等幅フォントの測定を実装する。
- [ ] 基本キー入力を `Pane` に渡す。
- [ ] resize イベントを `Pane#resize` に渡す。
- [ ] timer / repaint loop を実装する。
- [ ] clipboard copy / paste を実装する。
- [ ] 最小 GUI で Windows shell が起動し、入力と出力ができることを確認する。

## Phase 9: 画像・フォント拡張

- [ ] Windows 用 PNG decode 方針を決める。
- [ ] Kitty graphics の Windows decode / render backend を追加する。
- [ ] iTerm2 images の Windows decode / render backend を追加する。
- [ ] Unicode fallback font の解決を実装する。
- [ ] bold / italic / underline / strikethrough の描画差を確認する。
- [ ] OSC 66 proportional text の Windows 対応可否を判断する。

## Phase 10: Installer と配布

- [ ] `echoes install` を OS 別に分岐する。
- [ ] Windows 初期対応では、未対応メッセージにするか launcher 生成にするか決める。
- [ ] launcher を生成する場合、`.cmd` または `.bat` の出力先を決める。
- [ ] gemspec の summary / description / post install message を Windows 対応状況に合わせて更新する。
- [ ] `README.md` の Requirements / Installation / Development を OS 別に更新する。
- [ ] `.app` 専用の説明を macOS セクションに移す。

## Phase 11: Embedded Rubish Mode

- [ ] Windows 初期リリースで embedded mode を対象に含めるか決める。
- [ ] 対象外にする場合、Windows で `ECHOES_EMBED=1` を指定したときの明確なエラーを実装する。
- [ ] 対象にする場合、Windows 用 helper のプロセス制御モデルを設計する。
- [ ] Ctrl-C / command interruption / history / cwd 通知の Windows 仕様を決める。
- [ ] embedded mode の Windows 専用テストを追加する。

## Phase 12: 最終確認

- [ ] macOS フルテストを実行する。
- [x] Windows コアテストを実行する。
  - ローカルで `ruby -S rake test:core` 成功。2026-05-21 時点: 563 tests, 1215 assertions。
  - Terminal / EmbeddedShell の Phase 3 対応後: 566 tests, 1223 assertions。
- [ ] Windows backend テストを実行する。
- [ ] Windows GUI 手動確認を実施する。
- [ ] `README.md` と `docs/windows-porting-status.md` を最新状態に更新する。
- [ ] 未対応機能を明示したリリースノート草案を作る。

## 初回マイルストーンの完了条件

- [x] Windows で `require "echoes"` が成功する。
- [ ] Windows CI で OS 非依存テストが通る。
  - CI job は追加済み。リモート実行結果は未確認。
- [ ] macOS の既存 GUI / PTY テストが壊れていない。
- [x] AppKit 依存テストが macOS 限定として明示されている。
- [ ] 次の作業者が ConPTY backend に着手できる状態になっている。


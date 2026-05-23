# Windows GUI Debugging Status

作成日: 2026-05-23

## 発生中の問題

Windows GUI (Win32 backend) で画面が乱れる問題を調査中。

## 現象

1. **初期状態**: 黒背景は表示される（FillRect 成功）
2. **コマンド入力**: キー入力は反応する
3. **シェル出力**: `dir` コマンドの出力が表示されるが、乱れた状態になる
4. **スクリーン内容**: `screen.grid` の内容が正しく反映されない

## 解析済みの事項

### 1. 初期タブ作成
- `Win32Window#start_event_loop` で初期タブを作成するロジックが欠けていた
- 追加済み: MacWindow と同様に `gui_tabs.empty?` のチェックで `@gui.create_tab` を呼ぶ

### 2. 背景描画
- 背景が描画されていなかった
- 追加済み: `draw_pane_content` の先頭で `FillRect` を呼び出す

### 3. ログ機能
- `Fiddle::Closure::BlockCaller` 内で `warn` や `to_s` を呼ぶと segfault になる
- 追加済み: ファイルへのログ出力機能を追加し、安全な文字列化メソッドを使用

### 4. Parser 出力
- シェル出力は正しく受信されている
- LF (`\n`) のみの出力を受信（cmd.exe ではなく bash からの出力）
- ANSI シーケンス (`\e[2J`, `\e[H`, etc.) も受信されている

## 発見したバグ

### line_feed のカーソル位置問題

ログから発見:

```
[SCREEN] carriage_return: cursor from (0, 3)
[SCREEN] line_feed: cursor from (0, 0)
[SCREEN] put_char 'A' at (1, 0)  ← Row 0 にあるはずが Row 1 に！
[SCREEN] put_char 'p' at (1, 1)
[SCREEN] put_char 'p' at (1, 2)
[SCREEN] line_feed: cursor from (1, 7)
[SCREEN] put_char 'A' at (2, 7)  ← col が 7 のまま！
```

**期待**: "AppData" は Row 0 にあるはず
**実際**: Row 1 に書かれている

**期待**: `\n` (LF) の後は次の行の col 0 から
**実際**: col 7 から書き込みが続いている

`line_feed` は `@cursor.row` をインクリメントするが、`@cursor.col` を 0 にしません。
VT100 仕様では LF は col を変えず row のみ動かすのが正しいですが、CRLF (`\r\n`) の場合は CR で col 0 になり、LF で row がインクリメントされます。

bash 出力は `\n` (LF のみ) なので:
1. `carriage_return` は呼ばれない
2. `line_feed` のみが呼ばれる
3. カーソルは下に動くが列位置を保持

しかし、この挙動は間違っています！Windows ターミナルでは `\n` は CRLF 相当に動作するべきです。

## 解決策の方向性

### オプション 1: LF を CRLF として扱う
- Windows ConPTY 出力の `\n` を `\r\n` に変換してから parser に渡す
- または parser の `feed` で LF を CRLF に変換する

### オプション 2: Screen の line_feed で col を 0 にする
- VT100 互換モードではなく Windows モードとして LF を CRLF 相当に扱う
- `line_feed` 内で `@cursor.col = 0` を追加

### オプション 3: ConPTY 設定で CRLF 出力を有効にする
- `ENABLE_VIRTUAL_TERMINAL_PROCESSING` フラグ設定
- または ConPTY API で CRLF モードを指定

## 完了済み作業

1. syslog 依存の削除（gemspec）
2. ドキュメントの更新:
   - `docs/windows-porting-tasks.md` (Ctrl-C 完了記述追加、テストカウント更新)
   - `docs/windows-porting-status.md` (Ctrl-C ステータス更新)
   - `docs/windows-release-notes-draft.md` (Ctrl-C 完了削除)
   - `docs/superpowers/specs/` / `plans/` (ステータス更新)
3. デバッグログ機能の実装

## 残作業

1. **line_feed / CRLF 問題の解決** - 上記オプションのいずれかを検証
2. macOS テスト実行（macOS 環境が必要）
3. Remote Windows CI の成功確認

## 参考コード

- `lib/echoes/gui/win32_window.rb` - Win32 GUI 実装
- `lib/echoes/screen.rb` - Screen/Grid 管理とカーソル操作
- `lib/echoes/parser.rb` - ANSI シーケンス解析
- `lib/echoes/conpty.rb` - Windows ConPTY バックエンド
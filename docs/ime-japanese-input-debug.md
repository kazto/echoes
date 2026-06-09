# IME 日本語入力 文字化け調査 - 引き継ぎ資料

作成日: 2026-05-26
更新日: 2026-05-26
状態: 修正済み - unit test 確認済み、IME 実機入力は最終手動確認待ち

## 実装状況

### 完了済み
- IME メッセージハンドリング (`WM_IME_STARTCOMPOSITION`, `WM_IME_ENDCOMPOSITION`, `WM_IME_COMPOSITION`)
- Composition 文字列取得 (`ImmGetCompositionStringW`, `GCS_COMPSTR`, `GCS_RESULTSTR`)
- Marked text 描画（fallback font 対応）
- 確定文字列の shell への送信機能 (`commit_ime_composition`)
- ConPTY/cmd 入出力の Windows code page 変換

### 未完了
- 日本語 IME 実機入力の最終手動確認

## 問題詳細

### 現象
- IME で「日本語」と入力・確定後、画面に文字化けして表示される
- shell（cmd.exe）でも正しく認識されず、`'???{??' は...` のように表示される

### 調査結果

#### データフロー
```
IME (ImmGetCompositionStringW)
  -> UTF-16LE: [229, 101, 44, 103, 158, 138] // 「日本語」
read_ime_composition_string
  -> UTF-8: [230, 151, 165, 230, 156, 172, 232, 170, 158] // 「日本語」
GUI (write_pane_input)
  -> UTF-8 string
WindowsConPTYBackend#write
  -> UTF-8 bytes: [230, 151, 165, 230, 156, 172, 232, 170, 158]
ConPTY input echo
  -> UTF-8 bytes
cmd error output
  -> CP932 bytes
decode_console_output
  -> mixed UTF-8 / CP932 decode -> UTF-8 string
```

#### 根本原因
ConPTY input pipe は UTF-8 を受け取る一方、cmd の通常出力は CP932 で返るため、同じ output chunk に「入力 echo は UTF-8」「cmd のエラーメッセージは CP932」が混在していました。

- `[239, 191, 189]` は U+FFFD の UTF-8 表現
- UTF-8 直送を CP932 として decode すると、prompt 上の「日本語」が `譌･譛ｬ隱�` のように化ける
- CP932 変換した input を ConPTY input pipe に送ると、cmd が `???{??` として認識する
- `GetOEMCP` は 932 を返し、cmd の通常出力 decode に使う encoding と一致

## 修正内容

### `lib/echoes/shell_backend.rb`
- `Encoding.find("locale")` ではなく Windows `GetOEMCP` 由来の `Encoding.find("CP#{code_page}")` を使用
- UTF-8 input は ConPTY input pipe にそのまま送信
- ConPTY output は UTF-8 と OEM code page が混在する前提で UTF-8 へ decode

### `lib/echoes/gui_win32.rb`
- `WM_IME_COMPOSITION` の `GCS_RESULTSTR` で確定文字列を shell へ送信
- `WM_IME_ENDCOMPOSITION` は marked text の clear のみにする
- `read_ime_composition_string` は UTF-16LE bytes を binary として受けてから UTF-8 へ変換

### `lib/echoes/win32.rb`
- `GCS_RESULTSTR = 0x0800` を追加

### 調査用ログ
- `tmp/ime_debug.log` への調査用書き込みは削除済み

## 検証済み

```powershell
bundle exec ruby -Ilib -Itest test/echoes/shell_backend_test.rb -n /ConPTY/
bundle exec ruby -Ilib -Itest test/echoes/gui_test.rb
bundle exec rake test
```

結果:
- `shell_backend_test.rb -n /ConPTY/`: 14 tests, 25 assertions, 0 failures
- `gui_test.rb`: 57 tests, 121 assertions, 0 failures
- `bundle exec rake test`: 634 tests, 1364 assertions, 0 failures, 8 omissions

## 次に試すべきこと

### 1. IME 実機入力の最終確認
```powershell
ruby -Ilib exe\echoes
```

手順:
1. IME をオン（Win+Space または Alt+半角/全角）
2. `nihongo` と入力
3. Space で「日本語」へ変換
4. Enter で確定

期待結果:
- prompt 上に「日本語」が文字化けせず表示される
- Enter 後の cmd error も `'日本語' は...` のようにコマンド名が正しく表示される

### 2. 他 locale の code page 確認
- 日本語 Windows では `GetOEMCP == 932` で確認済み
- 英語 Windows などでは `GetOEMCP` と cmd/ConPTY 出力が一致するか追加確認する

## 関連ファイル

- `lib/echoes/gui_win32.rb`: IME ハンドリングと描画
- `lib/echoes/win32.rb`: Win32 API バインディング（IMM32 関連）
- `lib/echoes/shell_backend.rb`: ConPTY/cmd encoding 変換
- `lib/echoes/conpty.rb`: ConPTY 実装
- `test/echoes/gui_test.rb`: IME テスト
- `test/echoes/shell_backend_test.rb`: ConPTY encoding テスト

## 技術的メモ

### Windows IME API
- `ImmGetCompositionStringW` は UTF-16LE を返す
- `GCS_COMPSTR`: 未確定テキスト（composition 表示用）
- `GCS_RESULTSTR`: 確定文字列（shell 入力用）
- 確定文字列は `WM_IME_COMPOSITION` の `GCS_RESULTSTR` で処理する

### エンコーディング
- UTF-8: `日本語` -> `[230, 151, 165, 230, 156, 172, 232, 170, 158]`
- CP932: `日本語` -> `[147, 250, 150, 123, 140, 234]`
- UTF-16LE: `日本語` -> `[229, 101, 44, 103, 158, 138]`

## コミット状況

- `feature/windows` ブランチで作業中
- 最新コミット: `43c118c` Add echoes.conf to gitignore
- 未コミットの変更:
  - `lib/echoes/gui_win32.rb` (IME 確定機能追加)
  - `lib/echoes/win32.rb` (GCS_RESULTSTR 定数追加)
  - `test/echoes/gui_test.rb` (IME テスト追加)
  - `lib/echoes/shell_backend.rb` (UTF-8 input と mixed output decode)

## 参考リソース

- Microsoft Docs: Pseudo Console (ConPTY)
- Windows IME API Documentation
- Ruby Fiddle ドキュメント
- Windows Code Pages: CP932 (Shift_JIS), CP65001 (UTF-8)

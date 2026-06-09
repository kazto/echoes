# Windows ConPTY が画像プロトコル(Kitty Graphics / OSC 66)を剥がす問題

ステータス: **解決**(OSC 1337 経路で対応 / 当初案の raw パイプは実測で不要と判明)
最終更新: 2026-06-06
対象プラットフォーム: Windows のみ(macOS / Linux は real PTY のため影響なし)

---

## 解決(2026-06-06 追記・実測で確定)

実測の結論を先に書く。**ConPTY は OSC を切り詰めず素通しし、APC(画像)だけを破棄する。**
したがって修正は「raw パイプで ConPTY を避ける」ではなく、**画像を APC(Kitty
Graphics)ではなく OSC(iTerm2 OSC 1337 インライン画像)で送る**ことに尽きる。

- 通過量の計測(ConPTY 配下の子に OSC 1337 と APC を同サイズ出させて出力パイプを観測する
  アドホック repro): OSC 1337 ペイロードは 64B〜**200KB まで欠損ゼロで通過**、一方 APC
  (`ESC _ G …`)は全サイズで **0 バイトしか到達しない**(完全破棄)。
- 受信経路の検証: 実 PNG → OSC 1337 → `Echoes::Parser` → `GdiPlusPng.decode`
  (`lib/echoes/kitty_graphics_win32.rb`)→ `Screen#put_kitty_image` →
  `Screen#placements` まで Windows で動作確認済み。Echoes の受信・描画側は
  **既に完全実装済みで無改修**(`lib/echoes/parser.rb` の OSC 1337 分岐 +
  `lib/echoes/iterm2_images.rb`)。
- 修正の所在:
  - **Echoes**: 子へ `ECHOES_INLINE_IMAGE_PROTOCOL`(Windows=`osc1337` / その他=`kitty`)を
    広告(`lib/echoes/gui.rb`)。描画ロジック自体は不要。
  - **ziglow(別リポジトリ)**: `ECHOES_INLINE_IMAGE_PROTOCOL=osc1337` を検出したら
    Kitty APC ではなく OSC 1337 で画像を出す。送信フォーマットは
    `\e]1337;File=inline=1[;width=…;height=…]:<base64 PNG>\a`。

下記「根本原因」以降は当初の調査記録として残す。**案A(raw パイプ)は本件には不要**で、
OSC 1337 への切り替えの方が低コスト・高互換(対話シェルは ConPTY のまま、画像はインライン)。

---

## 要約

Echoes は Windows ではパネルの子プロセスを **ConPTY(疑似コンソール)** 経由で
起動している(`lib/echoes/conpty.rb`)。OS の ConPTY は子の出力を一旦
**テキストグリッドとして再構成**してから出力パイプに書き戻す。このとき、
グリッドのセルに属さない **APC / 画像系エスケープシーケンスが破棄される**。

その結果、子アプリが正しく送信した次のシーケンスが Echoes のパーサまで届かない:

- **Kitty Graphics Protocol**(`ESC _ G … ESC \`、APC)— インライン画像
- **Kitty Text Sizing Protocol**(`ESC ] 66 ; … BEL`、OSC 66)— 拡大見出し
  ※ こちらは別途 [`conpty`/OSC 66 の調査](#関連) でも確認済み

Echoes 自身は両プロトコルを **完全に実装している**
(`lib/echoes/kitty_graphics.rb` + `lib/echoes/kitty_graphics_win32.rb` の GdiPlus
デコード、`lib/echoes/parser.rb` の OSC 66 / APC 解釈)。つまり問題は Echoes の
パーサや描画ではなく、**子プロセスと Echoes の間に挟まる ConPTY 再構成層**にある。

---

## 症状

Markdown ビューア `ziglow`(別プロジェクト)が、独立行のローカル画像
`![alt](path.png)` を Kitty Graphics Protocol でインライン表示するようになった。
`TERM_PROGRAM=Echoes` を検出して `ESC _ G f=100,a=T,c=… ; <base64 PNG> ESC \` を
出力する。

- macOS の Echoes(real PTY): **画像が表示される**(想定どおり)。
- Windows の Echoes(ConPTY): **画像が表示されない**。見出しと後続段落の間が
  空白になるだけ。マーカー文字も画像も出ない。

---

## 証拠(再現とバイト列)

ziglow を **ConPTY 経由**で起動し(`isatty` を真にするため)、ConPTY 出力パイプ
から読めるバイト列を観測する。Claude Code は不要 — Ruby だけで再現できる。

```ruby
# repro_conpty_graphics.rb
require "echoes/conpty"

exe = 'C:\path\to\ziglow.exe'              # Kitty graphics を出すアプリ
md  = 'C:\path\to\doc.md'                   # 独立行に ![x](cat.png) を含む md
env = ENV.to_h.merge("TERM" => "xterm-kitty")  # アプリに kitty 出力をさせる

pty = Echoes::ConPTY.new
pty.spawn("\"#{exe}\" \"#{md}\"", cols: 120, rows: 40, env: env)

buf = +"".b
deadline = Time.now + 3
while Time.now < deadline
  chunk = pty.read_available_output(65536)
  buf << chunk.b unless chunk.empty?
  sleep 0.05
end
pty.close rescue nil

puts "bytes captured: #{buf.bytesize}"
puts "contains ESC_G (kitty graphics): #{buf.include?("\e_G")}"
v = buf.gsub("\e","<ESC>").gsub("\a","<BEL>").gsub("\r","<CR>").gsub("\n","<LF>\n")
puts v
```

観測結果(120x40、見出し+画像1枚+段落の md):

```
bytes captured: 178
contains ESC_G (kitty graphics): false
<ESC>[?9001h<ESC>[?1004h<ESC>[?25l<ESC>[2J<ESC>[m<ESC>[H<ESC>[2C ...
<ESC>]66;s=3;# Image test <BEL>
<ESC>[38;5;252m<ESC>[7;1H  Trailing paragraph.<ESC>[10;1H ...
```

ポイント:

- 全体でわずか **178 バイト**。base64 PNG(数 KB〜)はどこにも無い。
- `ESC _ G`(Kitty graphics の導入子)が **1 個も含まれていない**。
- ConPTY は `ESC[2J` で画面を再構成し、見出しの直後にカーソルを `ESC[7;1H`
  (7 行目)へ飛ばして段落を描いている。本来画像があった行(4〜6 行目付近)は
  **完全に空**。

子アプリ側は確かに画像エスケープを送っている(ziglow 側で、マーカー置換が成功
=画像バイト読込成功であることを確認済み)。にもかかわらず ConPTY の出力には
残っていない → **ConPTY がグリッド再構成の過程で APC フレームを捨てている**。

---

## 根本原因

Windows の ConPTY は「VT を解釈してセル単位のテキストグリッドを保持し、変化分を
VT として書き戻す」レンダラとして動作する。画像(Kitty graphics / sixel /
iTerm2 inline)はテキストセルに属さないため、ConPTY の内部グリッドモデルに
居場所がなく、再構成出力に含まれない。OSC 66 の拡大見出しが Windows で崩れるのも
同じ再構成層が原因(関連ドキュメント参照)。

これは Echoes 固有のバグではなく、Windows ConPTY の一般的な制約。Windows Terminal
等が sixel/画像対応を進める中で ConPTY 側のパススルー改善も議論されているが、
**「グリッド再構成を無効化する公開フラグ」は存在しない**(`CreatePseudoConsole` の
公開フラグは `PSEUDOCONSOLE_INHERIT_CURSOR = 0x1` のみ)。

---

## なぜ送信側アプリ(ziglow 等)では直せないか

送信側は正しいバイトを stdout に書いているだけで、その先の ConPTY 再構成は
制御できない。`CreatePseudoConsole` を呼ぶのは **Echoes**(`conpty.rb`)であり、
パイプの張り方・パススルーの可否を決められるのも Echoes 側だけ。したがって修正は
Echoes に閉じる。

---

## Echoes 側の対応案

### 案A(本命): グラフィックス対応の子には ConPTY を使わず raw パイプで起動する

`conpty.rb` の `spawn` は `CreatePseudoConsole` + `STARTF_USESTDHANDLES` で子を
疑似コンソールに繋いでいる。これを **疑似コンソールを介さず、子の stdout/stderr を
直接パイプに繋ぐ**経路に切り替えると、子の生 VT 出力(`ESC _ G …` を含む)が
そのまま `read_available_output` 経由で Echoes のパーサに届く。Echoes の
`parser.rb` / `kitty_graphics.rb` は既に `_G` を解釈できるので、パーサ側の追加実装は
不要。

検討事項:
- 子は console API(画面サイズ問い合わせ等)が使えなくなり、stdout が tty 判定
  されない可能性がある。ziglow のような **VT 専用レンダラ**には十分だが、対話シェル
  (pwsh/zsh のプロンプト描画)には不向き。
- そのため「全パネルを raw パイプ化」ではなく、**用途を分ける**のが現実的:
  - 既定はこれまで通り ConPTY(対話シェル向け)。
  - 画像/特殊シーケンスを通したい起動だけ raw パイプ(例: ビューア起動、または
    設定/環境変数でのオプトイン、あるいは別 API としての「描画専用パネル」)。
- 端末サイズは ConPTY の `ResizePseudoConsole` 相当が無いので、`COLUMNS`/`LINES`
  や `TERM` を env で子に渡し、リサイズ時は明示的に再起動/通知する設計が要る。
- 実装の足場: `conpty.rb` の `CreatePipe` 2 本はそのまま流用でき、
  `CreateProcessW` を `EXTENDED_STARTUPINFO_PRESENT`(疑似コンソール属性)無しで、
  `STARTF_USESTDHANDLES` + 子の stdin/stdout/stderr に raw パイプを差して呼ぶ形に
  なる。

### 案B: ConPTY のパススルー機能を使う(将来 / 要検証)

新しめの Windows ビルドで ConPTY に画像/未知シーケンスのパススルーモードが
入っていないか、`CreatePseudoConsole`/`CreatePseudoConsole**` 系の最新フラグを
要確認。公開・安定フラグが存在するなら案 A より低コスト。現時点では
「グリッド再構成を止める公開 API は無い」という理解(2026-06 時点)なので、
まずは案 A を本線にしつつ、将来の Windows API 追加を監視する位置づけ。

### 案C: 何もしない(Windows では画像非対応と割り切る)

macOS では動くので、Windows は OSC 66 と同様「ConPTY 制約により未対応」と明記する。
最小コストだが、Windows での画像表示は諦めることになる。

推奨は **案A**(描画専用 raw パイプ経路の追加)。OSC 66 拡大見出しの Windows 問題も
同じ経路で同時に解消できる見込みが高い。

---

## 受け入れ条件(案Aを採る場合)

1. raw パイプ経路で起動した子が出した `ESC _ G … ESC \` が、ConPTY を介さず
   Echoes のパーサに**バイトとして到達**する(上の repro スクリプトで
   `contains ESC_G: true` になる、または Echoes パネルに画像が描画される)。
2. 既存の ConPTY パネル(対話シェル)の挙動は不変。
3. OSC 66 拡大見出しも raw パイプ経路で正しく描画される。
4. リサイズ・終了・プロセスツリー終了が raw パイプ経路でも破綻しない。

---

## 関連

- `lib/echoes/conpty.rb` — ConPTY 起動・パイプ・read/write(本件の改修対象)
- `lib/echoes/parser.rb` — VT パーサ(OSC 66 / APC を解釈、改修不要の見込み)
- `lib/echoes/kitty_graphics.rb`, `lib/echoes/kitty_graphics_win32.rb` —
  Kitty Graphics デコード/描画(既に実装済み、改修不要の見込み)
- `docs/windows-porting-status.md`, `docs/macos-windows-feature-parity.md` —
  Windows 移植状況
- OSC 66(拡大見出し)が同じ ConPTY 再構成で崩れる件の調査メモも参照。
  本件はその「画像版」であり、根本原因と修正方針(raw パイプ)を共有する。

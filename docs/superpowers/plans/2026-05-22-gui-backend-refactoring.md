# GUI Backend Refactoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `lib/echoes/gui.rb` (macOS) と `lib/echoes/gui_win32.rb` (Windows) をリファクタリングし、OS非依存の共通GUIコアと、委譲先となるOS固有の `MacWindow` / `Win32Window` クラスに完全に分離します。

**Status:** ✅ COMPLETED - 2026-05-23

**Architecture:** `Echoes::GUI` がタブ・ペイン状態、選択範囲、および検索マッチングなどの状態管理を担当し、実際のネイティブウィンドウ生成、OSメッセージループ、および描画処理は `GUI.window_class` としてロードされるプラットフォーム別コンポーネントに委譲（Delegate）します。両者は定められたAPI契約を通じて双方向に通知し合います。

**Tech Stack:** Ruby (Fiddle, Thread, OS-native API wrappers)

---

## 担当ファイルマップ

*   **`lib/echoes.rb`**: `load_gui_backend` の修正、プラットフォーム判定に基づく `GUI.window_class` へのバインディング。
*   **`lib/echoes/gui.rb`**: OS非依存のGUIオーケストレーター（共通）にリファクタリング。
*   **`lib/echoes/gui/mac_window.rb`**: macOS固有の `AppKit` ウィンドウ / レンダラーコンポーネント（新規作成）。
*   **`lib/echoes/gui/win32_window.rb`**: Windows固有の `Win32/GDI` ウィンドウ / レンダラーコンポーネント（新規作成）。
*   **`lib/echoes/gui_win32.rb`**: 削除。

---

## リファクタリングタスク一覧

### Task 1: GUI コアのロード境界と Window クラスのバインディング

**Files:**
*   Modify: `lib/echoes.rb`
*   Modify: `lib/echoes/gui.rb`
*   Create: `test/echoes/gui_load_test.rb`

- [ ] **Step 1: バインディングの失敗（または仕様通りのロード）を確認するテストを作成**
    `test/echoes/gui_load_test.rb` を作成し、プラットフォームに応じた `window_class` が正しくバインドされることを確認するテストを記述します。

    ```ruby
    # test/echoes/gui_load_test.rb
    require_relative '../test_helper'

    class GuiLoadTest < Test::Unit::TestCase
      def test_gui_window_class_binding
        Echoes.load_gui_backend
        assert_not_nil Echoes::GUI.window_class
        if Echoes::Platform.windows?
          assert_equal "Echoes::GUI::Win32Window", Echoes::GUI.window_class.name
        elsif Echoes::Platform.macos?
          assert_equal "Echoes::GUI::MacWindow", Echoes::GUI.window_class.name
        end
      end
    end
    ```

- [ ] **Step 2: テストを実行し、まだ Window クラスがないため失敗することを確認**
    Run: `ruby -Ilib:test test/echoes/gui_load_test.rb`
    Expected: NameError または failure (GUI.window_class が定義されていないか、ファイルがないため)

- [ ] **Step 3: `lib/echoes.rb` および `lib/echoes/gui.rb` の最小限の実装**
    `gui.rb` に `window_class` アクセサを追加し、`lib/echoes.rb` のロードロジックを更新します。また、空の `gui/mac_window.rb` と `gui/win32_window.rb` をスタブクラスとして定義します。

    ```ruby
    # lib/echoes/gui.rb の先頭部分にクラス定義を追加
    module Echoes
      class GUI
        class << self
          attr_accessor :window_class
        end
      end
    end
    ```

    ```ruby
    # lib/echoes.rb の該当箇所を修正
    def load_gui_backend
      require_relative "echoes/gui"
      if Platform.windows?
        require_relative "echoes/win32"
        require_relative "echoes/gui/win32_window"
        GUI.window_class = GUI::Win32Window
      elsif Platform.macos?
        require_relative "echoes/objc"
        require_relative "echoes/gui/mac_window"
        GUI.window_class = GUI::MacWindow
      else
        raise Error, "Echoes GUI is not supported on this platform"
      end
    end
    ```

    ```ruby
    # lib/echoes/gui/mac_window.rb (暫定の空クラス)
    module Echoes
      class GUI
        class MacWindow
          def initialize(gui, **opts); end
        end
      end
    end
    ```

    ```ruby
    # lib/echoes/gui/win32_window.rb (暫定の空クラス)
    module Echoes
      class GUI
        class Win32Window
          def initialize(gui, **opts); end
        end
      end
    end
    ```

- [ ] **Step 4: テストを再実行し、パスすることを確認**
    Run: `ruby -Ilib:test test/echoes/gui_load_test.rb`
    Expected: PASS

- [ ] **Step 5: 変更をコミット**
    ```bash
    git add lib/echoes.rb lib/echoes/gui.rb lib/echoes/gui/mac_window.rb lib/echoes/gui/win32_window.rb test/echoes/gui_load_test.rb
    git commit -m "refactor: define gui backend loading and window class bindings"
    ```

---

### Task 2: macOS版 `gui.rb` の解体と `MacWindow` への移行

**Files:**
*   Modify: `lib/echoes/gui.rb`
*   Modify: `lib/echoes/gui/mac_window.rb`
*   Test: macOS環境で既存のGUIテストスイート（`test/echoes/gui_test.rb` 等）を実行

- [ ] **Step 1: `MacWindow` に Cocoa / AppKit 呼び出しと描画・イベントハンドラを移管**
    `gui.rb` から `setup_app`, `create_fonts`, `create_view_class`, `setup_timer`, `start_app`, `draw_rect`, `key_down`, `mouse_down` などの ObjC 依存メソッドを `lib/echoes/gui/mac_window.rb` に移行します。
    また、`MacWindow` は `gui` オブジェクトへの参照を保持し、イベント受信時に `gui.handle_key_down` などを呼び出すブリッジを実装します。

    *実装概要 (`lib/echoes/gui/mac_window.rb`)*:
    ```ruby
    module Echoes
      class GUI
        class MacWindow
          def initialize(gui, command:, rows:, cols:, font_size:)
            @gui = gui
            @command = command
            @rows = rows
            @cols = cols
            @font_size = font_size
            # ...元の gui.rb からの ObjC インスタンス変数を移植 ...
          end

          def start_event_loop
            setup_app
            create_fonts
            create_view_class
            open_new_window
            setup_timer
            start_app
          end

          # ... draw_rect, mouse_down などの描画・イベント受信メソッド ...
          # イベント受信時は @gui.handle_key_down などを呼ぶ
        end
      end
    end
    ```

- [ ] **Step 2: `lib/echoes/gui.rb` を OS非依存のピュアな状態管理クラスへリファクタリング**
    `gui.rb` は `@tabs`, `@active_tab`, `@selection_anchor`, `@search_mode` などの状態のみを持ち、`initialize` 内で `@window = GUI.window_class.new(self, ...)` を作成して `run` 時に `@window.start_event_loop` を呼び出す形にリファクタリングします。

    *実装概要 (`lib/echoes/gui.rb`)*:
    ```ruby
    module Echoes
      class GUI
        attr_reader :tabs, :active_tab, :selection_anchor, :selection_end

        def initialize(command: Echoes.config.shell, rows: Echoes.config.rows, cols: Echoes.config.cols, font_size: nil)
          @rows = rows
          @cols = cols
          @font_size = font_size || Preferences.fetch_double(:font_size, default: Echoes.config.font_size)
          @command = command
          @tabs = []
          @active_tab = 0
          
          # Window の作成
          @window = GUI.window_class.new(self, command: @command, rows: @rows, cols: @cols, font_size: @font_size)
          
          create_tab
        end

        def run
          @window.start_event_loop
        end

        # ... create_tab, close_tab, search_next などの OS非依存ロジックのみを保持する ...
      end
    end
    ```

- [ ] **Step 3: macOS 環境で既存テストを走らせ、動作がデグレードしていないことを確認**
    (この作業環境が Windows の場合、CI または macOS ローカルでの手動/自動テストを実行して確認します)

- [ ] **Step 4: 変更をコミット**
    ```bash
    git add lib/echoes/gui.rb lib/echoes/gui/mac_window.rb
    git commit -m "refactor: extract macOS AppKit GUI logic to GUI::MacWindow"
    ```

---

### Task 3: Windows版 `gui_win32.rb` の解体と `Win32Window` への移行

**Files:**
*   Modify: `lib/echoes.rb`
*   Modify: `lib/echoes/gui/win32_window.rb`
*   Delete: `lib/echoes/gui_win32.rb`

- [ ] **Step 1: `Win32Window` に Win32 / GDI 呼び出しと描画・イベントループを移植**
    `gui_win32.rb` に記述されていた `run` メソッド内の `RegisterClassExW`, `CreateWindowExW`, メッセージループ（`PeekMessageW`）、GDIによるフォントとテキスト/画像の描画処理（`draw_pane_content`, `TextOutW`, `StretchDIBits` など）を `lib/echoes/gui/win32_window.rb` に移植します。
    `Win32Window` も `GUI` オブジェクトへの参照を保持し、WndProc 内でイベント（`WM_CHAR`, `WM_KEYDOWN`, `WM_SIZE` など）を検知した際は、`@gui.handle_key_down` や `@gui.handle_resize` に仲介します。

    *実装概要 (`lib/echoes/gui/win32_window.rb`)*:
    ```ruby
    module Echoes
      class GUI
        class Win32Window
          def initialize(gui, command:, rows:, cols:, font_size:)
            @gui = gui
            @command = command
            @rows = rows
            @cols = cols
            @font_size = font_size
            # ... gui_win32.rb からの Win32/GDI 固有インスタンス変数の移植 ...
          end

          def start_event_loop
            # RegisterClassExW, CreateWindowExW, ShowWindow
            # PeekMessageW によるノンブロッキングメッセージループの実行
          end

          # ... draw_pane_content, GDI描画、クリップボード処理 ...
        end
      end
    end
    ```

- [ ] **Step 2: 不要となった旧 `gui_win32.rb` の削除**
    すべての Win32 / GDI コードが `win32_window.rb` に移行され、OS非依存のオーケストレーションは `gui.rb`（共通）に引き継がれたため、旧ファイルは削除します。
    また、`lib/echoes.rb` を更新し、Windows 環境でも `gui.rb`（共通コア）をロードするようにします。

    ```ruby
    # lib/echoes.rb
    def load_gui_backend
      require_relative "echoes/gui" # 共通コアをロード
      if Platform.windows?
        require_relative "echoes/win32"
        require_relative "echoes/gui/win32_window" # Windows用ウィンドウをロード
        GUI.window_class = GUI::Win32Window
      # ...
    ```

- [ ] **Step 3: Windows テストスイートを実行し、一切のデグレードがないことを確認**
    Run: `ruby -S rake test:core`
    Expected: すべてのテストケースが正常にパスする。

- [ ] **Step 4: 旧ファイルの物理削除と変更のコミット**
    ```bash
    git rm lib/echoes/gui_win32.rb
    git add lib/echoes.rb lib/echoes/gui/win32_window.rb
    git commit -m "refactor: migrate Win32 GDI GUI logic to GUI::Win32Window and remove gui_win32.rb"
    ```

---

### Task 4: GUI オーケストレーターとイベントの最終統合と動作確認

**Files:**
*   Modify: `lib/echoes/gui.rb`
*   Modify: `lib/echoes/gui/win32_window.rb`
*   Modify: `lib/echoes/gui/mac_window.rb`

- [ ] **Step 1: ドラッグ選択および検索イベントを各OSのWindowコンポーネントに結合**
    共通コア `Echoes::GUI` で計算される選択範囲や検索マッチングを、各OSのウィンドウが適切に描画できるようバインドを確認・修正します。
    特に、Windows版（`win32_window.rb`）において、共通化したマウスドラッグイベントハンドラ経由で、これまで機能していなかったマウスによるコピペ選択（ドラッグして反転表示、Ctrl+Shift+Cでコピー）が正常に連動することを確認します。

- [ ] **Step 2: Windows コアテストスイートを再実行**
    Run: `ruby -S rake test:core`
    Expected: すべてのテストがPASSする。

- [ ] **Step 3: Windows 上で GUI を起動して、手動確認を実行**
    Run: `ruby exe/echoes`
    1. 起動し、シェル（cmd.exe等）が表示されること。
    2. キー入力、矢印キーが動き、正常に出力がスクロールされること。
    3. マウスのドラッグによりテキストが選択反転されること。
    4. リサイズ時にペイン幅が正しく伸縮すること。

- [ ] **Step 4: 最終コミット**
    ```bash
    git add -A
    git commit -m "refactor: fully integrate GUI orchestrator with platform-specific Windows"
    ```

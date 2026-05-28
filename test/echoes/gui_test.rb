# frozen_string_literal: true

require "test_helper"
require "json"
require "shellwords"
require "tmpdir"

Echoes.load_gui_backend if Echoes::Platform.windows? || Echoes::Platform.macos?

if Echoes::Platform.windows?
  class Echoes::GUIWindowsTest < Test::Unit::TestCase
    StubPane = Struct.new(:screen, :writes, :copy_mode) do
      def write_input(str)
        writes << str
      end
    end
    StubInputPane = Struct.new(:screen, :writes, :scroll_offset, :scroll_accum) do
      def write_input(str)
        writes << str
      end
    end
    StubEmbeddedPane = Struct.new(:screen, :request, :applied) do
      def embedded? = true
      def embedded_shell = self
      def running? = false
      def completion_request = request
      def apply_completion(word_start:, completion:)
        applied << [word_start, completion]
      end
    end
    StubTab = Struct.new(:active_pane) do
      def screen
        active_pane.screen
      end
    end
    StubPaneTree = Struct.new(:active_pane, :layout_rects) do
      def layout(_x, _y, _cols, _rows)
        layout_rects
      end
    end
    StubLayoutTab = Struct.new(:pane_tree) do
      def active_pane
        pane_tree.active_pane
      end
      def screen
        active_pane.screen
      end
      def write_input(str)
        active_pane.write_input(str)
      end
    end
    StubResizableTab = Struct.new(:resizes) do
      def resize(rows, cols)
        resizes << [rows, cols]
      end
    end
    StubClosableTab = Struct.new(:closed) do
      def close
        self.closed += 1
      end
    end
    StubCopyMode = Struct.new(:selection_start, :selection_end) do
      def active = true
      def selecting? = true
    end
    StubCellStyle = Struct.new(:bold, :italic)
    StubParser = Struct.new(:fed) do
      def feed(output)
        fed << output
      end
    end
    StubPollingPane = Struct.new(:alive, :outputs, :parser) do
      def alive? = alive
      def read_available_output = outputs.shift
    end
    StubCursor = Struct.new(:row, :col, :visible)
    StubDrawScreen = Struct.new(:scrollback, :rows, :cols, :grid, :placements, :cursor, :background, :bg_fills) do
      def cursor_style = 0
    end
    StubDrawPane = Struct.new(:screen, :scroll_offset)
    StubHandlerScreen = Struct.new(:clipboard_handler, :glyph_measurer, :capture_handler, :display_info_handler,
                                   :open_window_handler, :cell_pixel_width, :cell_pixel_height, :notification_handler)
    StubHandlerPane = Struct.new(:screen) do
      def refresh_pty_pixel_size
        @refreshed = true
      end
    end
    StubScrollablePane = Struct.new(:screen, :scroll_offset, :scroll_accum)

    test "embedded mode raises a clear unsupported error" do
      old = ENV["ECHOES_EMBED"]
      ENV["ECHOES_EMBED"] = "1"
      error = assert_raise(Echoes::Error) do
        Echoes::GUI.new
      end
      assert_match(/Embedded rubish mode is not supported on Windows/, error.message)
    ensure
      ENV["ECHOES_EMBED"] = old
    end

    test "Win32 UTF-16 scanner finds the terminating null pair on code unit boundaries" do
      raw = "a\x00b\x00\x00\x00ignored".b
      assert_equal 4, Echoes::Win32.utf16_nul_index(raw)
    end

    test "Windows paste wraps clipboard text in bracketed paste markers" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      screen.bracketed_paste_mode = true
      pane = StubPane.new(screen, [])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.instance_variable_set(:@hwnd, nil)

      with_win32_clipboard_text("hello") do
        gui.send(:paste_from_clipboard)
      end

      assert_equal ["\e[200~", "hello", "\e[201~"], pane.writes
    end

    test "Windows key sequence maps navigation and editing keys" do
      gui = Echoes::GUI.allocate

      assert_equal "\e[A", gui.send(:windows_key_sequence, 0x26)
      assert_equal "\e[B", gui.send(:windows_key_sequence, 0x28)
      assert_equal "\e[C", gui.send(:windows_key_sequence, 0x27)
      assert_equal "\e[D", gui.send(:windows_key_sequence, 0x25)
      assert_equal "\e[H", gui.send(:windows_key_sequence, 0x24)
      assert_equal "\e[F", gui.send(:windows_key_sequence, 0x23)
      assert_equal "\e[5~", gui.send(:windows_key_sequence, 0x21)
      assert_equal "\e[6~", gui.send(:windows_key_sequence, 0x22)
      assert_equal "\e[3~", gui.send(:windows_key_sequence, 0x2E)
      assert_equal "\x7F", gui.send(:windows_key_sequence, 0x08)
      assert_equal "\t", gui.send(:windows_key_sequence, 0x09)
      assert_equal "\r", gui.send(:windows_key_sequence, 0x0D)
      assert_equal "\e", gui.send(:windows_key_sequence, 0x1B)
    end

    test "Windows key sequence maps control letters" do
      gui = Echoes::GUI.allocate

      assert_equal "\x03", gui.send(:windows_key_sequence, 0x43, ctrl_pressed: true)
      assert_equal "\x1A", gui.send(:windows_key_sequence, 0x5A, ctrl_pressed: true)
      assert_nil gui.send(:windows_key_sequence, 0x41)
    end

    test "Windows mouse wheel scrolls active pane through scrollback" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      10.times { screen.scrollback << [] }
      pane = StubScrollablePane.new(screen, 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])

      assert_true gui.send(:handle_mouse_wheel_delta, 120)
      assert_equal 3, pane.scroll_offset

      assert_true gui.send(:handle_mouse_wheel_delta, -120)
      assert_equal 0, pane.scroll_offset
    end

    test "Windows mouse wheel clamps active pane scroll offset to scrollback" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      2.times { screen.scrollback << [] }
      pane = StubScrollablePane.new(screen, 1, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])

      assert_true gui.send(:handle_mouse_wheel_delta, 120)
      assert_equal 2, pane.scroll_offset

      assert_true gui.send(:handle_mouse_wheel_delta, -240)
      assert_equal 0, pane.scroll_offset
    end

    test "Windows pane input snaps scrolled pane back to live output" do
      pane = StubInputPane.new(Echoes::Screen.new(rows: 2, cols: 10), [], 4, 1.5)
      gui = Echoes::GUI.allocate

      gui.send(:write_pane_input, pane, "x")

      assert_equal ["x"], pane.writes
      assert_equal 0, pane.scroll_offset
      assert_equal 0.0, pane.scroll_accum
    end

    test "Windows dropped file paths are quoted for shell paste" do
      gui = Echoes::GUI.allocate

      assert_equal 'C:\tmp\a.txt "C:\tmp\my file.txt"',
                   gui.send(:file_paths_for_paste, ['C:\tmp\a.txt', 'C:\tmp\my file.txt'])
      assert_nil gui.send(:file_paths_for_paste, [])
    end

    test "Windows file drop pastes paths into the active pane" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      pane = StubInputPane.new(screen, [], 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])

      singleton = class << Echoes::Win32; self; end
      original = Echoes::Win32.method(:dropped_file_paths)
      singleton.send(:remove_method, :dropped_file_paths)
      singleton.define_method(:dropped_file_paths) { |_hdrop| ['C:\tmp\my file.txt'] }
      assert_true gui.send(:handle_file_drop, :hdrop)

      assert_equal ['"C:\tmp\my file.txt"'], pane.writes
    ensure
      singleton&.send(:remove_method, :dropped_file_paths)
      singleton&.define_method(:dropped_file_paths) { |hdrop| original.call(hdrop) } if original
    end

    test "Windows file drop honors bracketed paste mode" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      screen.bracketed_paste_mode = true
      pane = StubInputPane.new(screen, [], 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.define_singleton_method(:file_paths_for_paste) { |_paths| 'C:\tmp\a.txt' }

      singleton = class << Echoes::Win32; self; end
      original = Echoes::Win32.method(:dropped_file_paths)
      singleton.send(:remove_method, :dropped_file_paths)
      singleton.define_method(:dropped_file_paths) { |_hdrop| ['C:\tmp\a.txt'] }
      assert_true gui.send(:handle_file_drop, :hdrop)

      assert_equal ["\e[200~", 'C:\tmp\a.txt', "\e[201~"], pane.writes
    ensure
      singleton&.send(:remove_method, :dropped_file_paths)
      singleton&.define_method(:dropped_file_paths) { |hdrop| original.call(hdrop) } if original
    end

    test "Windows focus reporting writes focus in and out sequences" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      screen.focus_reporting = true
      pane = StubInputPane.new(screen, [], 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.instance_variable_set(:@hwnd, nil)

      assert_true gui.send(:window_focus_changed, true)
      assert_true gui.send(:window_focus_changed, false)

      assert_equal ["\e[I", "\e[O"], pane.writes
      assert_false gui.instance_variable_get(:@window_focused)
    end

    test "Windows focus reporting ignores panes that did not request it" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      pane = StubInputPane.new(screen, [], 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.instance_variable_set(:@hwnd, nil)

      assert_false gui.send(:window_focus_changed, true)

      assert_equal [], pane.writes
    end

    test "Windows Ctrl-click opens URL under the clicked cell" do
      screen = Echoes::Screen.new(rows: 2, cols: 40)
      "visit https://example.test now".chars.each_with_index do |char, index|
        screen.grid[0][index].char = char
      end
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 40, h: 2, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 40)
      gui.instance_variable_set(:@rows, 2)

      opened = []
      gui.define_singleton_method(:control_pressed?) { true }
      gui.define_singleton_method(:open_url) { |url| opened << url; true }
      gui.define_singleton_method(:current_tab) { @tabs[@active_tab] }

      lparam = (0 * 16 << 16) | (8 * 8)
      assert_true gui.send(:handle_left_button_down, nil, lparam)

      assert_equal ["https://example.test"], opened
    end

    test "Windows left mouse press reports terminal mouse event when tracking is enabled" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.mouse_tracking = :normal
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 10)
      gui.instance_variable_set(:@rows, 4)

      lparam = (1 * 16 << 16) | (2 * 8)
      assert_true gui.send(:handle_left_button_down, nil, lparam)

      assert_equal ["\e[M #{(3 + 32).chr}#{(2 + 32).chr}"], pane.writes
      assert_equal :left, gui.instance_variable_get(:@mouse_button_down)
    end

    test "Windows mouse drag and release use SGR reporting" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.mouse_tracking = :button_event
      screen.mouse_encoding = :sgr
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 10)
      gui.instance_variable_set(:@rows, 4)

      down = (1 * 16 << 16) | (2 * 8)
      move = (2 * 16 << 16) | (3 * 8)
      gui.send(:handle_left_button_down, nil, down)
      assert_true gui.send(:handle_mouse_move, move)
      assert_true gui.send(:handle_mouse_button_up, move)

      assert_equal ["\e[<0;3;2M", "\e[<32;4;3M", "\e[<3;4;3m"], pane.writes
      assert_nil gui.instance_variable_get(:@mouse_button_down)
    end

    test "Windows right mouse reports button two" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.mouse_tracking = :normal
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 10)
      gui.instance_variable_set(:@rows, 4)

      lparam = (0 * 16 << 16) | (1 * 8)
      assert_true gui.send(:handle_mouse_button_down, nil, lparam, 2, :right)

      assert_equal ["\e[M\"\"!"], pane.writes
      assert_equal :right, gui.instance_variable_get(:@mouse_button_down)
    end

    test "Windows middle mouse reports button one" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.mouse_tracking = :normal
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 10)
      gui.instance_variable_set(:@rows, 4)

      lparam = (0 * 16 << 16) | (1 * 8)
      assert_true gui.send(:handle_mouse_button_down, nil, lparam, 1, :middle)

      assert_equal ["\e[M!\"!"], pane.writes
      assert_equal :middle, gui.instance_variable_get(:@mouse_button_down)
    end

    test "Windows middle mouse drag uses SGR button motion code" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.mouse_tracking = :button_event
      screen.mouse_encoding = :sgr
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 10)
      gui.instance_variable_set(:@rows, 4)

      down = (1 * 16 << 16) | (2 * 8)
      move = (2 * 16 << 16) | (3 * 8)
      gui.send(:handle_mouse_button_down, nil, down, 1, :middle)
      assert_true gui.send(:handle_mouse_move, move)

      assert_equal ["\e[<1;3;2M", "\e[<33;4;3M"], pane.writes
    end

    test "Windows X buttons report extended mouse buttons" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.mouse_tracking = :normal
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 10)
      gui.instance_variable_set(:@rows, 4)

      lparam = (0 * 16 << 16) | (1 * 8)
      assert_true gui.send(:handle_xbutton_down, nil, Echoes::Win32::XBUTTON1 << 16, lparam)
      assert_true gui.send(:handle_xbutton_down, nil, Echoes::Win32::XBUTTON2 << 16, lparam)

      assert_equal ["\e[M(\"!", "\e[M)\"!"], pane.writes
      assert_equal :xbutton2, gui.instance_variable_get(:@mouse_button_down)
    end

    test "Windows X button drag uses extended SGR motion code" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.mouse_tracking = :button_event
      screen.mouse_encoding = :sgr
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 10)
      gui.instance_variable_set(:@rows, 4)

      down = (1 * 16 << 16) | (2 * 8)
      move = (2 * 16 << 16) | (3 * 8)
      gui.send(:handle_xbutton_down, nil, Echoes::Win32::XBUTTON1 << 16, down)
      assert_true gui.send(:handle_mouse_move, move)

      assert_equal ["\e[<8;3;2M", "\e[<40;4;3M"], pane.writes
    end

    test "Windows terminal cursor loads and applies the I-beam cursor" do
      gui = Echoes::GUI.allocate
      calls = []
      load_cursor = ->(instance, cursor_id) { calls << [:load, instance, cursor_id]; 1234 }
      set_cursor = ->(cursor) { calls << [:set, cursor]; cursor }

      with_win32_const(:LoadCursorW, load_cursor) do
        with_win32_const(:SetCursor, set_cursor) do
          assert_true gui.send(:set_terminal_cursor)
          assert_true gui.send(:set_terminal_cursor)
        end
      end

      assert_equal [
        [:load, 0, Echoes::Win32::IDC_IBEAM],
        [:set, 1234],
        [:set, 1234]
      ], calls
    end

    test "Windows set cursor applies terminal cursor only in client area" do
      gui = Echoes::GUI.allocate
      applied = 0
      defaults = []
      gui.define_singleton_method(:set_terminal_cursor) { applied += 1; true }

      with_win32_const(:DefWindowProcW, ->(hwnd, msg, wparam, lparam) {
        defaults << [hwnd, msg, wparam, lparam]
        55
      }) do
        assert_equal 1, gui.send(:handle_set_cursor, :hwnd, Echoes::Win32::WM_SETCURSOR, :wparam, Echoes::Win32::HTCLIENT)
        assert_equal 55, gui.send(:handle_set_cursor, :hwnd, Echoes::Win32::WM_SETCURSOR, :wparam, 2)
      end

      assert_equal 1, applied
      assert_equal [[:hwnd, Echoes::Win32::WM_SETCURSOR, :wparam, 2]], defaults
    end

    test "Windows menu bar installs File Edit View Window Shell and Help menus" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, 99)
      popup_handles = [200, 201, 202, 203, 204, 205, 206]
      calls = []

      with_window_registry_windows([]) do
        with_win32_const(:CreateMenu, -> { calls << [:create_menu]; 100 }) do
          with_win32_const(:CreatePopupMenu, -> { handle = popup_handles.shift; calls << [:create_popup, handle]; handle }) do
            with_win32_const(:AppendMenuW, ->(menu, flags, id, _label) { calls << [:append, menu, flags, id]; 1 }) do
              with_win32_const(:SetMenu, ->(hwnd, menu) { calls << [:set_menu, hwnd, menu]; 1 }) do
                with_win32_const(:DrawMenuBar, ->(hwnd) { calls << [:draw, hwnd]; 1 }) do
                  assert_true gui.send(:setup_menu)
                end
              end
            end
          end
        end
      end

      assert_include calls, [:append, 200, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_NEW_TAB]
      assert_include calls, [:append, 200, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_OPEN_FILE]
      assert_include calls, [:append, 200, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_EXIT]
      assert_include calls, [:append, 201, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_COPY]
      assert_include calls, [:append, 201, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_PASTE]
      assert_include calls, [:append, 202, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_FIND]
      assert_include calls, [:append, 202, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_FIND_NEXT]
      assert_include calls, [:append, 202, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_FIND_PREVIOUS]
      assert_include calls, [:append, 202, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_TOGGLE_POINTER]
      assert_include calls, [:append, 202, Echoes::Win32::MF_POPUP, 206]
      assert_include calls, [:append, 206, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_PROFILE_BASE]
      assert_include calls, [:append, 203, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_WINDOW_MINIMIZE]
      assert_include calls, [:append, 203, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_WINDOW_MAXIMIZE]
      assert_include calls, [:append, 203, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_WINDOW_FULLSCREEN]
      assert_include calls, [:append, 203, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_PREVIOUS_TAB]
      assert_include calls, [:append, 203, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_NEXT_TAB]
      assert_include calls, [:append, 204, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_CLOSE_TAB]
      assert_include calls, [:append, 204, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_SPLIT_RIGHT]
      assert_include calls, [:append, 204, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_SPLIT_DOWN]
      assert_include calls, [:append, 204, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_CLOSE_PANE]
      assert_include calls, [:append, 205, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_ABOUT]
      assert_include calls, [:append, 100, Echoes::Win32::MF_POPUP, 200]
      assert_include calls, [:append, 100, Echoes::Win32::MF_POPUP, 201]
      assert_include calls, [:append, 100, Echoes::Win32::MF_POPUP, 202]
      assert_include calls, [:append, 100, Echoes::Win32::MF_POPUP, 203]
      assert_include calls, [:append, 100, Echoes::Win32::MF_POPUP, 204]
      assert_include calls, [:append, 100, Echoes::Win32::MF_POPUP, 205]
      assert_include calls, [:set_menu, 99, 100]
      assert_include calls, [:draw, 99]
    end

    test "Windows menu commands dispatch to GUI actions" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, nil)
      gui.instance_variable_set(:@running, true)
      created = []
      invalidations = 0
      about = 0
      toggles = 0
      copies = 0
      pastes = 0
      close_tabs = 0
      split_rights = 0
      split_downs = 0
      close_panes = 0
      finds = 0
      nexts = 0
      prevs = 0
      profiles = 0
      gui.define_singleton_method(:create_tab) { |editor_file: nil| created << editor_file }
      gui.define_singleton_method(:prompt_for_file_to_edit) { "C:/tmp/demo.txt" }
      gui.define_singleton_method(:invalidate_window) { invalidations += 1 }
      gui.define_singleton_method(:show_about_panel) { about += 1 }
      gui.define_singleton_method(:toggle_pointer_hidden) { toggles += 1 }
      gui.define_singleton_method(:copy_to_clipboard) { copies += 1 }
      gui.define_singleton_method(:paste_from_clipboard) { pastes += 1 }
      gui.define_singleton_method(:close_tab) { |_index| close_tabs += 1 }
      gui.define_singleton_method(:split_active_pane) { |direction| direction == :vertical ? split_rights += 1 : split_downs += 1 }
      gui.define_singleton_method(:close_active_pane) { close_panes += 1 }
      gui.define_singleton_method(:toggle_search) { finds += 1 }
      gui.define_singleton_method(:search_next) { nexts += 1 }
      gui.define_singleton_method(:search_prev) { prevs += 1 }
      gui.define_singleton_method(:apply_profile_by_menu) { |_command_id| profiles += 1 }

      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_NEW_TAB)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_OPEN_FILE)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_ABOUT)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_TOGGLE_POINTER)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_COPY)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_PASTE)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_CLOSE_TAB)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_SPLIT_RIGHT)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_SPLIT_DOWN)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_CLOSE_PANE)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_FIND)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_FIND_NEXT)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_FIND_PREVIOUS)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_PROFILE_BASE)
      assert_true gui.send(:dispatch_menu_command, Echoes::GUI::MENU_EXIT)
      assert_false gui.send(:dispatch_menu_command, 999_999)

      assert_equal [nil, "C:/tmp/demo.txt"], created
      assert_equal 11, invalidations
      assert_equal 1, about
      assert_equal 1, toggles
      assert_equal 1, copies
      assert_equal 1, pastes
      assert_equal 1, close_tabs
      assert_equal 1, split_rights
      assert_equal 1, split_downs
      assert_equal 1, close_panes
      assert_equal 1, finds
      assert_equal 1, nexts
      assert_equal 1, prevs
      assert_equal 1, profiles
      assert_false gui.instance_variable_get(:@running)
    end

    test "Windows profile menu applies profile colors and marks panes dirty" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      pane = StubInputPane.new(screen, [], 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])

      assert_true gui.send(:apply_profile, "Solarized Dark")

      profile = Echoes.config.all_profiles["Solarized Dark"]
      assert_same profile, gui.instance_variable_get(:@active_profile)
      assert_equal gui.send(:make_color, *profile.foreground), gui.instance_variable_get(:@default_fg)
      assert_equal gui.send(:make_color, *profile.background), gui.instance_variable_get(:@default_bg)
      assert_equal Set.new([0, 1]), screen.dirty_rows
    end

    test "Windows completion popup applies selected candidate" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.cursor.row = 2
      screen.cursor.col = 3
      req = {word_start: 4, candidates: ["alpha", "alpine", "alto"]}
      pane = StubEmbeddedPane.new(screen, req, [])
      pane_tree = StubPaneTree.new(pane, [{x: 5, y: 1, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, 99)
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cols, 20)
      gui.instance_variable_set(:@rows, 8)
      gui.instance_variable_set(:@cell_width, 10)
      gui.instance_variable_set(:@cell_height, 20)
      calls = []

      with_win32_const(:CreatePopupMenu, -> { calls << [:create]; 500 }) do
        with_win32_const(:AppendMenuW, ->(menu, flags, id, _label) { calls << [:append, menu, flags, id]; 1 }) do
          with_win32_const(:ClientToScreen, ->(_hwnd, point) {
            x, y = point[0, Echoes::Win32::POINT_SIZE].unpack("l2")
            point[0, Echoes::Win32::POINT_SIZE] = [x + 100, y + 200].pack("l2")
            calls << [:client_to_screen, x, y]
            1
          }) do
            with_win32_const(:TrackPopupMenu, ->(menu, flags, x, y, _reserved, hwnd, _rect) {
              calls << [:track, menu, flags, x, y, hwnd]
              Echoes::GUI::MENU_COMPLETION_BASE + 1
            }) do
              with_win32_const(:DestroyMenu, ->(menu) { calls << [:destroy, menu]; 1 }) do
                assert_true gui.send(:show_completion_popup, pane, req)
              end
            end
          end
        end
      end

      assert_include calls, [:append, 500, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_COMPLETION_BASE]
      assert_include calls, [:append, 500, Echoes::Win32::MF_STRING, Echoes::GUI::MENU_COMPLETION_BASE + 1]
      assert_include calls, [:client_to_screen, 80, 80]
      assert_include calls, [:track, 500, Echoes::Win32::TPM_RETURNCMD | Echoes::Win32::TPM_RIGHTBUTTON, 180, 280, 99]
      assert_include calls, [:destroy, 500]
      assert_equal [[4, "alpine"]], pane.applied
      assert_nil gui.instance_variable_get(:@completion_state)
    end

    test "Windows embedded tab key uses completion popup for multiple candidates" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      req = {word_start: 0, candidates: ["cat", "cd"]}
      pane = StubEmbeddedPane.new(screen, req, [])
      gui = Echoes::GUI.allocate
      shown = []
      gui.define_singleton_method(:show_completion_popup) { |shown_pane, shown_req| shown << [shown_pane, shown_req]; true }

      assert_true gui.send(:handle_completion_tab, pane)
      assert_equal [[pane, req]], shown
    end

    test "Windows accelerator table encodes menu shortcuts" do
      gui = Echoes::GUI.allocate

      bytes = gui.send(:accelerator_table_bytes, Echoes::GUI::ACCELERATORS)
      entries = bytes.bytes.each_slice(6).map { |chunk| chunk.pack("C*").unpack("Cxvv") }

      assert_equal Echoes::GUI::ACCELERATORS.size, entries.size
      assert_equal [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x54, Echoes::GUI::MENU_NEW_TAB], entries[0]
      assert_equal [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x46, Echoes::GUI::MENU_FIND], entries[2]
      assert_equal [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x57, Echoes::GUI::MENU_CLOSE_TAB], entries[5]
      assert_equal [Echoes::Win32::FCONTROL | Echoes::Win32::FSHIFT | Echoes::Win32::FVIRTKEY, 0x50, Echoes::GUI::MENU_TOGGLE_POINTER], entries[8]
      assert_equal [Echoes::Win32::FVIRTKEY | 0x80, 0x70, Echoes::GUI::MENU_ABOUT], entries[-1]
    end

    test "Windows pointer visibility toggles through ShowCursor and clears cursor while hidden" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@cursor_handle, 4321)
      calls = []
      show_returns = [-1, 0]

      with_win32_const(:ShowCursor, ->(visible) {
        calls << [:show_cursor, visible]
        show_returns.shift || 0
      }) do
        with_win32_const(:SetCursor, ->(cursor) {
          calls << [:set_cursor, cursor]
          cursor
        }) do
          assert_true gui.send(:toggle_pointer_hidden)
          assert_true gui.instance_variable_get(:@pointer_hidden)
          assert_true gui.send(:toggle_pointer_hidden)
          assert_false gui.instance_variable_get(:@pointer_hidden)
        end
      end

      assert_equal [
        [:show_cursor, 0],
        [:set_cursor, 0],
        [:show_cursor, 1],
        [:set_cursor, 4321]
      ], calls
    end

    test "Windows hidden pointer is restored by shake detection" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@pointer_hidden, true)
      gui.instance_variable_set(:@shake_detector, Echoes::ShakeDetector.new)
      gui.instance_variable_set(:@mouse_button_down, nil)
      calls = []

      with_win32_const(:ShowCursor, ->(visible) {
        calls << [:show_cursor, visible]
        0
      }) do
        with_win32_const(:SetCursor, ->(cursor) {
          calls << [:set_cursor, cursor]
          cursor
        }) do
          [[0, 0], [70, 0], [0, 0], [80, 0], [0, 0]].each do |x, y|
            lparam = ((y & 0xFFFF) << 16) | (x & 0xFFFF)
            gui.send(:handle_mouse_move, lparam)
          end
        end
      end

      assert_false gui.instance_variable_get(:@pointer_hidden)
      assert_include calls, [:show_cursor, 1]
    end

    test "Windows setup and destroy accelerators use native accelerator table" do
      gui = Echoes::GUI.allocate
      calls = []

      with_win32_const(:CreateAcceleratorTableW, ->(_table, count) {
        calls << [:create, count]
        1234
      }) do
        assert_true gui.send(:setup_accelerators)
      end
      assert_equal 1234, gui.instance_variable_get(:@accelerators)

      with_win32_const(:DestroyAcceleratorTable, ->(handle) {
        calls << [:destroy, handle]
        1
      }) do
        gui.send(:destroy_accelerators)
      end

      assert_equal [[:create, Echoes::GUI::ACCELERATORS.size], [:destroy, 1234]], calls
      assert_nil gui.instance_variable_get(:@accelerators)
    end

    test "Windows prompt for file opens dialog at the pane local cwd" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      screen.current_directory = "file://localhost/C:/Users"
      pane = StubInputPane.new(screen, [], 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, :hwnd)
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.define_singleton_method(:current_tab) { @tabs[@active_tab] }

      calls = []
      with_win32_singleton_method(:open_file_dialog, ->(**kwargs) {
        calls << kwargs
        "C:/Users/demo.txt"
      }) do
        assert_equal "C:/Users/demo.txt", gui.send(:prompt_for_file_to_edit)
      end

      assert_equal [{hwnd: :hwnd, initial_dir: "C:/Users", title: "Open File"}], calls
    end

    test "Windows about panel text includes runtime and curated environment only" do
      gui = Echoes::GUI.allocate
      old_path = ENV["PATH"]
      old_secret = ENV["AWS_SECRET_ACCESS_KEY"]
      ENV["PATH"] = "C:\\bin"
      ENV["AWS_SECRET_ACCESS_KEY"] = "secret"

      text = gui.send(:about_panel_text)

      assert_include text, "Echoes #{Echoes::VERSION}"
      assert_include text, "Ruby #{RUBY_VERSION}"
      assert_include text, "PATH=C:\\bin"
      assert_not_include text, "AWS_SECRET_ACCESS_KEY"
    ensure
      ENV["PATH"] = old_path
      if old_secret
        ENV["AWS_SECRET_ACCESS_KEY"] = old_secret
      else
        ENV.delete("AWS_SECRET_ACCESS_KEY")
      end
    end

    test "Windows about panel uses MessageBox helper" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, :hwnd)
      gui.define_singleton_method(:about_panel_text) { "about text" }
      calls = []

      with_win32_singleton_method(:show_message_box, ->(hwnd, title, message) {
        calls << [hwnd, title, message]
        true
      }) do
        assert_true gui.send(:show_about_panel)
      end

      assert_equal [[:hwnd, "About Echoes", "about text"]], calls
    end

    test "Windows IME composition updates marked text when composition string is present" do
      gui = Echoes::GUI.allocate
      gui.define_singleton_method(:read_ime_composition_string) do |hwnd, flag|
        [hwnd, flag] == [:hwnd, Echoes::Win32::GCS_COMPSTR] ? "かな" : nil
      end

      assert_true gui.send(:update_ime_composition, :hwnd, Echoes::Win32::GCS_COMPSTR)
      assert_equal "かな", gui.instance_variable_get(:@marked_text)
    end

    test "Windows IME composition clears marked text when composition string is empty" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@marked_text, "かな")
      gui.define_singleton_method(:read_ime_composition_string) { |_hwnd, _flag| "" }

      assert_true gui.send(:update_ime_composition, :hwnd, Echoes::Win32::GCS_COMPSTR)
      assert_nil gui.instance_variable_get(:@marked_text)
    end

    test "Windows IME composition ignores updates without composition string flag" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@marked_text, "かな")
      gui.define_singleton_method(:read_ime_composition_string) { |_hwnd, _flag| flunk("should not read IME composition") }

      assert_false gui.send(:update_ime_composition, :hwnd, 0)
      assert_equal "かな", gui.instance_variable_get(:@marked_text)
    end

    test "Windows IME composition commits result string when result flag is present" do
      gui = Echoes::GUI.allocate
      pane = StubInputPane.new(Echoes::Screen.new(rows: 2, cols: 10), [], 0, 0.0)
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.instance_variable_set(:@marked_text, "にほんご")
      gui.define_singleton_method(:read_ime_composition_string) do |_hwnd, flag|
        flag == Echoes::Win32::GCS_RESULTSTR ? "日本語" : nil
      end

      assert_true gui.send(:update_ime_composition, :hwnd, Echoes::Win32::GCS_RESULTSTR)
      assert_equal ["日本語"], pane.writes
      assert_nil gui.instance_variable_get(:@marked_text)
    end

    test "Windows IME commit sends result string to active pane" do
      gui = Echoes::GUI.allocate
      pane = StubInputPane.new(Echoes::Screen.new(rows: 2, cols: 10), [], 0, 0.0)
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.define_singleton_method(:read_ime_composition_string) do |hwnd, flag|
        if flag == Echoes::Win32::GCS_RESULTSTR
          "日本語"
        else
          nil
        end
      end

      gui.send(:commit_ime_composition, :hwnd)

      assert_equal ["日本語"], pane.writes
    end

    test "Windows IME commit ignores empty result strings" do
      gui = Echoes::GUI.allocate
      pane = StubInputPane.new(Echoes::Screen.new(rows: 2, cols: 10), [], 0, 0.0)
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.define_singleton_method(:read_ime_composition_string) { |_hwnd, _flag| "" }

      gui.send(:commit_ime_composition, :hwnd)

      assert_equal [], pane.writes
    end

    test "Windows IME candidate origin follows active pane cursor" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.cursor.row = 2
      screen.cursor.col = 3
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 5, y: 1, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 20)
      gui.instance_variable_set(:@rows, 8)

      assert_equal [64, 64], gui.send(:ime_candidate_origin)
    end

    test "Windows IME candidate window is positioned through IMM" do
      screen = Echoes::Screen.new(rows: 4, cols: 10)
      screen.cursor.row = 1
      screen.cursor.col = 2
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 1, y: 2, w: 10, h: 4, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 10)
      gui.instance_variable_set(:@cell_height, 20)
      gui.instance_variable_set(:@cols, 20)
      gui.instance_variable_set(:@rows, 8)
      calls = []

      with_win32_const(:ImmGetContext, ->(hwnd) { calls << [:get, hwnd]; 1234 }) do
        with_win32_const(:ImmReleaseContext, ->(hwnd, himc) { calls << [:release, hwnd, himc]; 1 }) do
          with_win32_const(:ImmSetCompositionWindow, ->(himc, form) {
            calls << [:composition, himc, form[0, 28].unpack('Lllllll')]
            1
          }) do
            with_win32_const(:ImmSetCandidateWindow, ->(himc, form) {
              calls << [:candidate, himc, form[0, 32].unpack('LLllllll')]
              1
            }) do
              assert_true gui.send(:update_ime_candidate_window, :hwnd)
            end
          end
        end
      end

      assert_include calls, [:composition, 1234, [Echoes::Win32::CFS_CANDIDATEPOS, 30, 80, 0, 0, 0, 0]]
      assert_include calls, [:candidate, 1234, [0, Echoes::Win32::CFS_CANDIDATEPOS, 30, 80, 0, 0, 0, 0]]
      assert_include calls, [:release, :hwnd, 1234]
    end

    test "Windows I/O polling feeds active pane output to its parser" do
      parser = StubParser.new([])
      pane = StubPollingPane.new(true, ["hello"], parser)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.instance_variable_set(:@hwnd, nil)

      assert_true gui.send(:poll_active_pane_output)
      assert_equal ["hello"], parser.fed
    end

    test "Windows I/O polling ignores empty output and inactive panes" do
      parser = StubParser.new([])
      empty_pane = StubPollingPane.new(true, [""], parser)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(empty_pane)])
      gui.instance_variable_set(:@hwnd, nil)

      assert_false gui.send(:poll_active_pane_output)
      assert_equal [], parser.fed

      dead_pane = StubPollingPane.new(false, ["unread"], parser)
      gui.instance_variable_set(:@tabs, [StubTab.new(dead_pane)])

      assert_false gui.send(:poll_active_pane_output)
      assert_equal ["unread"], dead_pane.outputs
      assert_equal [], parser.fed
    end

    test "Windows search finds grid and scrollback matches" do
      screen = Echoes::Screen.new(rows: 2, cols: 12)
      "foo here".chars.each_with_index { |char, i| screen.grid[0][i].char = char }
      "bar foo".chars.each_with_index { |char, i| screen.grid[1][i].char = char }
      scroll_row = Array.new(12) { Echoes::Cell.new }
      "old foo".chars.each_with_index { |char, i| scroll_row[i].char = char }
      screen.scrollback << scroll_row
      pane = StubInputPane.new(screen, [], 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.instance_variable_set(:@rows, 2)
      gui.instance_variable_set(:@search_query, "foo")
      gui.instance_variable_set(:@search_matches, [])
      gui.instance_variable_set(:@search_index, -1)
      gui.instance_variable_set(:@search_regex_mode, false)
      gui.instance_variable_set(:@search_case_insensitive, false)

      gui.send(:perform_search)

      assert_equal [[0, 4, 3], [1, 0, 3], [2, 4, 3]], gui.instance_variable_get(:@search_matches)
      assert_equal 2, gui.instance_variable_get(:@search_index)
      assert_equal 0, pane.scroll_offset
    end

    test "Windows search key handling updates query and modes" do
      screen = Echoes::Screen.new(rows: 1, cols: 12)
      "Foo foo".chars.each_with_index { |char, i| screen.grid[0][i].char = char }
      pane = StubInputPane.new(screen, [], 0, 0.0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.instance_variable_set(:@rows, 1)
      gui.instance_variable_set(:@search_mode, true)
      gui.instance_variable_set(:@search_query, +"")
      gui.instance_variable_set(:@search_matches, [])
      gui.instance_variable_set(:@search_index, -1)
      gui.instance_variable_set(:@search_regex_mode, false)
      gui.instance_variable_set(:@search_case_insensitive, false)

      assert_true gui.send(:handle_search_char, "f")
      assert_equal "f", gui.instance_variable_get(:@search_query)
      assert_equal [[0, 4, 1]], gui.instance_variable_get(:@search_matches)
      assert_true gui.send(:handle_search_keydown, 0x49, ctrl_pressed: true, shift_pressed: false)
      assert_equal [[0, 0, 1], [0, 4, 1]], gui.instance_variable_get(:@search_matches)
      assert_true gui.send(:handle_search_keydown, 0x08, ctrl_pressed: false, shift_pressed: false)
      assert_equal "", gui.instance_variable_get(:@search_query)
      assert_true gui.send(:handle_search_keydown, 0x1B, ctrl_pressed: false, shift_pressed: false)
      assert_false gui.instance_variable_get(:@search_mode)
    end

    test "Windows resize updates rows and cols from pixel dimensions" do
      tab = StubResizableTab.new([])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@tabs, [tab])
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 80)
      gui.instance_variable_set(:@rows, 24)

      assert_true gui.send(:handle_window_resize_pixels, 1_000, 600)

      assert_equal 125, gui.instance_variable_get(:@cols)
      assert_equal 37, gui.instance_variable_get(:@rows)
      assert_equal [[37, 125]], tab.resizes
    end

    test "Windows resize ignores missing cell metrics and unchanged sizes" do
      tab = StubResizableTab.new([])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@tabs, [tab])
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@cols, 80)
      gui.instance_variable_set(:@rows, 24)

      assert_false gui.send(:handle_window_resize_pixels, 640, 384)

      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      assert_false gui.send(:handle_window_resize_pixels, 640, 384)

      assert_equal 80, gui.instance_variable_get(:@cols)
      assert_equal 24, gui.instance_variable_get(:@rows)
      assert_equal [], tab.resizes
    end

    test "Windows paint size sync updates rows after cell metrics become available" do
      tab = StubResizableTab.new([])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@tabs, [tab])
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@cols, 80)
      gui.instance_variable_set(:@rows, 24)
      gui.define_singleton_method(:client_size) { [1_000, 560] }

      assert_true gui.send(:sync_window_size_from_client_rect)

      assert_equal 125, gui.instance_variable_get(:@cols)
      assert_equal 35, gui.instance_variable_get(:@rows)
      assert_equal [[35, 125]], tab.resizes
    end

    test "Windows double buffered paint renders into memory DC then blits" do
      gui = Echoes::GUI.allocate
      calls = []
      gui.define_singleton_method(:create_compatible_dc) { |hdc| calls << [:create_dc, hdc]; :mem_dc }
      gui.define_singleton_method(:create_compatible_bitmap) { |hdc, width, height| calls << [:create_bitmap, hdc, width, height]; :bitmap }
      gui.define_singleton_method(:select_gdi_object) { |hdc, object| calls << [:select, hdc, object]; :old_bitmap }
      gui.define_singleton_method(:bit_blt) { |dst, x, y, width, height, src, sx, sy| calls << [:bit_blt, dst, x, y, width, height, src, sx, sy] }
      gui.define_singleton_method(:delete_gdi_object) { |object| calls << [:delete_object, object] }
      gui.define_singleton_method(:delete_dc) { |hdc| calls << [:delete_dc, hdc] }

      yielded = nil
      gui.send(:with_double_buffered_paint, :target_dc, 100, 50) do |paint_dc|
        yielded = paint_dc
        calls << [:paint, paint_dc]
      end

      assert_equal :mem_dc, yielded
      assert_equal [
        [:create_dc, :target_dc],
        [:create_bitmap, :target_dc, 100, 50],
        [:select, :mem_dc, :bitmap],
        [:paint, :mem_dc],
        [:bit_blt, :target_dc, 0, 0, 100, 50, :mem_dc, 0, 0],
        [:select, :mem_dc, :old_bitmap],
        [:delete_object, :bitmap],
        [:delete_dc, :mem_dc]
      ], calls
    end

    test "Windows GUI cleanup closes tabs once and clears the tab list" do
      tab1 = StubClosableTab.new(0)
      tab2 = StubClosableTab.new(0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@tabs, [tab1, tab2])
      gui.instance_variable_set(:@active_tab, 1)

      gui.send(:close_tabs)
      gui.send(:close_tabs)

      assert_equal 1, tab1.closed
      assert_equal 1, tab2.closed
      assert_equal [], gui.instance_variable_get(:@tabs)
      assert_equal 0, gui.instance_variable_get(:@active_tab)
    end

    test "Windows native timer starts and stops on the window handle" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, 99)
      calls = []

      with_win32_const(:SetTimer, ->(hwnd, id, interval, callback) {
        calls << [:set, hwnd, id, interval, callback]
        123
      }) do
        assert_true gui.send(:start_native_timer)
      end
      gui.instance_variable_set(:@native_timer_enabled, true)
      with_win32_const(:KillTimer, ->(hwnd, id) {
        calls << [:kill, hwnd, id]
        1
      }) do
        assert_true gui.send(:stop_native_timer)
      end

      assert_equal [
        [:set, 99, Echoes::GUI::TIMER_ID, Echoes::GUI::TIMER_INTERVAL_MS, nil],
        [:kill, 99, Echoes::GUI::TIMER_ID]
      ], calls
      assert_false gui.instance_variable_get(:@native_timer_enabled)
    end

    test "Windows timer tick polls output and refreshes window menu periodically" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@window_menu_update_counter, 0)
      calls = []
      gui.define_singleton_method(:poll_active_pane_output) { calls << :poll }
      gui.define_singleton_method(:update_window_menu_periodic) { calls << :window_menu }

      assert_true gui.send(:handle_timer_tick)

      assert_equal [:poll, :window_menu], calls
      assert_equal 1, gui.instance_variable_get(:@window_menu_update_counter)
    end

    test "Windows copy writes selected text to the clipboard" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      "hello".chars.each_with_index do |char, index|
        screen.grid[0][index].char = char
      end
      copy_mode = StubCopyMode.new([0, 1], [0, 3])
      pane = StubPane.new(screen, [], copy_mode)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubTab.new(pane)])
      gui.instance_variable_set(:@cols, 10)
      gui.instance_variable_set(:@hwnd, nil)

      captured = nil
      with_win32_clipboard_setter(->(_hwnd, text) { captured = text }) do
        gui.send(:copy_to_clipboard)
      end

      assert_equal "ell", captured
    end

    test "Windows image blit converts RGBA bytes to BGRA for GDI" do
      gui = Echoes::GUI.allocate
      rgba = "\x01\x02\x03\x04\x10\x20\x30\x40".b

      assert_equal "\x03\x02\x01\x04\x30\x20\x10\x40".b,
                   gui.send(:rgba_to_bgra, rgba, 2, 1)
    end

    test "Windows bitmap info uses a negative height for top-down pixels" do
      gui = Echoes::GUI.allocate
      header = gui.send(:bitmap_info_header, 2, 3, 24)

      assert_equal 40, header[0, 4].unpack1('L')
      assert_equal 2, header[4, 4].unpack1('l')
      assert_equal(-3, header[8, 4].unpack1('l'))
      assert_equal 32, header[14, 2].unpack1('v')
      assert_equal 24, header[20, 4].unpack1('L')
    end

    test "Windows text style selects bold and italic fonts" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hfont, 1)
      gui.instance_variable_set(:@bold_hfont, 2)
      gui.instance_variable_set(:@italic_hfont, 3)
      gui.instance_variable_set(:@bold_italic_hfont, 4)

      assert_equal 1, gui.send(:font_for_cell, StubCellStyle.new(false, false))
      assert_equal 2, gui.send(:font_for_cell, StubCellStyle.new(true, false))
      assert_equal 3, gui.send(:font_for_cell, StubCellStyle.new(false, true))
      assert_equal 4, gui.send(:font_for_cell, StubCellStyle.new(true, true))
    end

    test "Windows font fallback selects a candidate that has the glyph" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hfont, :base)
      gui.instance_variable_set(:@font_fallback_candidates, ["Yu Gothic UI", "Segoe UI Emoji"])

      created = []
      gui.define_singleton_method(:create_font) do |family: nil, **_kwargs|
        created << family
        :"font:#{family}"
      end
      gui.define_singleton_method(:font_has_glyph?) do |font, char|
        font == :"font:Segoe UI Emoji" && char == "😀"
      end

      assert_equal :"font:Segoe UI Emoji", gui.send(:font_for_text, :base, "😀")
      assert_equal ["Yu Gothic UI", "Segoe UI Emoji"], created
    end

    test "Windows font fallback prefers emoji font when GDI cannot confirm emoji glyphs" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hfont, :base)
      gui.instance_variable_set(:@font_fallback_candidates, ["Segoe UI Emoji"])

      gui.define_singleton_method(:create_font) { |family: nil, **_kwargs| :"font:#{family}" }
      gui.define_singleton_method(:font_has_glyph?) { |_font, _char| false }

      assert_equal :"font:Segoe UI Emoji", gui.send(:font_for_text, :base, "😀")
    end

    test "Windows font fallback splits text runs by fallback font" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hfont, :base)
      gui.instance_variable_set(:@font_fallback_candidates, ["Yu Gothic UI"])

      gui.define_singleton_method(:create_font) { |family: nil, **_kwargs| :"font:#{family}" }
      gui.define_singleton_method(:font_has_glyph?) do |font, char|
        font == :base ? char.ascii_only? : char == "漢"
      end

      assert_equal(
        [
          ["A", :base],
          ["漢", :"font:Yu Gothic UI"],
          ["B", :base]
        ],
        gui.send(:font_runs_for_text, :base, "A漢B")
      )
    end

    test "Windows text decoration rects cover underline and strikethrough" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@cell_height, 16)

      assert_equal [[10, 24, 34, 25], [10, 18, 34, 19]],
                   gui.send(:decoration_rects, 10, 10, 24, underline: true, strikethrough: true)
      assert_equal [[10, 38, 34, 39]],
                   gui.send(:decoration_rects, 10, 10, 24, height: 30, underline: true, strikethrough: false)
      assert_equal [], gui.send(:decoration_rects, 10, 10, 24, underline: false, strikethrough: false)
    end

    test "Windows multicell helpers scale and align text inside the reserved block" do
      gui = Echoes::GUI.allocate

      assert_equal 1.5, gui.send(:effective_multicell_scale, {scale: 3, frac_n: 1, frac_d: 2})
      assert_equal [25, 18],
                   gui.send(:aligned_text_origin, 10, 10, 60, 24, 30, 8, halign: 2, valign: 2)
      assert_equal [40, 26],
                   gui.send(:aligned_text_origin, 10, 10, 60, 24, 30, 8, halign: 1, valign: 1)
    end

    test "Windows pane drawing clears the pane background before cell drawing" do
      screen = StubDrawScreen.new([], 0, 0, [], [], StubCursor.new(0, 0, false), nil, [])
      pane = StubDrawPane.new(screen, 0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@default_bg, 0x112233)
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)

      fills = []
      gui.define_singleton_method(:fill_rect_color) do |_hdc, left, top, right, bottom, color|
        fills << [left, top, right, bottom, color]
      end

      gui.send(:draw_pane_content, :hdc, pane, 10, 20, 80, 48, true)

      assert_equal [[10, 20, 90, 68, 0x112233]], fills
    end

    test "Windows pane drawing paints flat background and bg fills under cells" do
      screen = StubDrawScreen.new(
        [], 2, 4, [], [], StubCursor.new(0, 0, false),
        {type: :flat, colors: [[1.0, 0.0, 0.0, 1.0]]},
        [{rect: [1, 1, 5, 9], color: [0.0, 1.0, 0.0, 1.0]}]
      )
      pane = StubDrawPane.new(screen, 0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@default_bg, 0x112233)
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)

      fills = []
      gui.define_singleton_method(:fill_rect_color) do |_hdc, left, top, right, bottom, color|
        fills << [left, top, right, bottom, color]
      end

      gui.send(:draw_pane_content, :hdc, pane, 10, 20, 32, 32, true)

      assert_equal [
        [10, 20, 42, 52, 0x112233],
        [10, 20, 42, 52, 0x0000ff],
        [18, 36, 42, 52, 0x00ff00]
      ], fills
    end

    test "Windows linear gradient draws vertical scanlines for 90 degrees" do
      gui = Echoes::GUI.allocate
      fills = []
      gui.define_singleton_method(:fill_rect_color) do |_hdc, left, top, right, bottom, color|
        fills << [left, top, right, bottom, color]
      end

      gui.send(:draw_linear_gradient, :hdc, 1, 2, 3, 2, [[0, 0, 0, 1.0], [255, 255, 255, 1.0]], 90)

      assert_equal [
        [1, 2, 4, 3, 0x000000],
        [1, 3, 4, 4, 0xffffff]
      ], fills
    end

    test "Windows linear gradient supports multiple color stops" do
      gui = Echoes::GUI.allocate
      fills = []
      gui.define_singleton_method(:fill_rect_color) do |_hdc, left, top, right, bottom, color|
        fills << [left, top, right, bottom, color]
      end

      gui.send(:draw_linear_gradient, :hdc, 1, 2, 5, 1, [[0, 0, 0, 1.0], [255, 0, 0, 1.0], [255, 255, 255, 1.0]], 0)

      assert_equal [
        [1, 2, 2, 3, 0x000000],
        [2, 2, 3, 3, 0x000080],
        [3, 2, 4, 3, 0x0000ff],
        [4, 2, 5, 3, 0x8080ff],
        [5, 2, 6, 3, 0xffffff]
      ], fills
    end

    test "Windows RGBA colors are blended against the default background" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@default_bg, 0x000000)

      assert_equal [128, 0, 0], gui.send(:rgba_to_rgb, [255, 0, 0, 0.5])
      assert_equal 0x000080, gui.send(:rgba_to_color, [255, 0, 0, 0.5])
    end

    test "Windows pane drawing skips wide-char continuation cells" do
      row = [
        Echoes::Cell.new("日", width: 2),
        Echoes::Cell.new(" ", width: 0),
        Echoes::Cell.new("本", width: 2),
        Echoes::Cell.new(" ", width: 0),
        Echoes::Cell.new("語", width: 2),
        Echoes::Cell.new(" ", width: 0)
      ]
      screen = StubDrawScreen.new([], 1, 6, [row], [], StubCursor.new(0, 0, false), nil, [])
      pane = StubDrawPane.new(screen, 0)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@colors, [])
      gui.instance_variable_set(:@default_fg, 0xeeeeee)
      gui.instance_variable_set(:@default_bg, 0x000000)
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@hfont, :base)

      drawn = []
      gui.define_singleton_method(:clear_pane_background) { |_hdc, _px, _py, _pw, _ph| }
      gui.define_singleton_method(:font_runs_for_text) { |_font, text, **_kwargs| [[text, :base]] }
      gui.define_singleton_method(:draw_text_run) do |_hdc, x, y, text, font|
        drawn << [x, y, text, font]
      end
      gui.define_singleton_method(:draw_text_decorations) do |_hdc, _x, _y, _width, _color, **_kwargs|
      end

      gui.send(:draw_pane_content, 0, pane, 10, 20, 48, 16, false)

      assert_equal [[10, 20, "日本語", :base]], drawn
    end

    test "Windows IME marked text draws with fallback font runs" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.instance_variable_set(:@hfont, :base)
      gui.instance_variable_set(:@marked_text, "A漢")

      runs = []
      gui.define_singleton_method(:font_runs_for_text) do |base_font, text, **_kwargs|
        runs << [base_font, text]
        [["A", :base], ["漢", :fallback]]
      end

      drawn = []
      gui.define_singleton_method(:draw_text_run) do |_hdc, x, y, text, font|
        drawn << [x, y, text, font]
      end
      gui.define_singleton_method(:draw_ime_underline) { |_hdc, _x, _y, _width, _height| }

      gui.send(:draw_ime_marked_text, :hdc, 10, 20, "A漢", 16)

      assert_equal [[:base, "A漢"]], runs
      assert_equal [[10, 20, "A", :base], [18, 20, "漢", :fallback]], drawn
    end

    test "Windows screen handlers wire OSC notifications" do
      screen = StubHandlerScreen.new
      pane = StubHandlerPane.new(screen)
      gui = Echoes::GUI.allocate
      delivered = []
      gui.define_singleton_method(:post_notification) do |source_pane, title, message|
        delivered << [source_pane, title, message]
      end

      gui.send(:wire_screen_handlers, pane)
      screen.notification_handler.call("Build", "Done")

      assert_equal [[pane, "Build", "Done"]], delivered
    end

    test "Windows screen handlers wire OSC capture" do
      screen = StubHandlerScreen.new
      pane = StubHandlerPane.new(screen)
      gui = Echoes::GUI.allocate
      captured = []
      gui.define_singleton_method(:capture_pane_to_png) do |source_pane, path|
        captured << [source_pane, path]
      end

      gui.send(:wire_screen_handlers, pane)
      screen.capture_handler.call("C:/tmp/snap.png")

      assert_equal [[pane, "C:/tmp/snap.png"]], captured
    end

    test "Windows screen handlers wire OSC display info" do
      screen = StubHandlerScreen.new
      pane = StubHandlerPane.new(screen)
      gui = Echoes::GUI.allocate
      gui.define_singleton_method(:display_info_json) { |source_pane| "json:#{source_pane.object_id}" }

      gui.send(:wire_screen_handlers, pane)

      assert_equal "json:#{pane.object_id}", screen.display_info_handler.call
    end

    test "Windows screen handlers wire OSC open-window" do
      screen = StubHandlerScreen.new
      pane = StubHandlerPane.new(screen)
      gui = Echoes::GUI.allocate
      seen = []
      gui.define_singleton_method(:open_window_from_osc) do |source_pane, args|
        seen << [source_pane, args]
      end

      gui.send(:wire_screen_handlers, pane)
      screen.open_window_handler.call("display=1")

      assert_equal [[pane, "display=1"]], seen
    end

    test "Windows notification title falls back to window title" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, :hwnd)
      titles = []
      gui.define_singleton_method(:set_window_title) { |title| titles << title }

      gui.send(:post_notification, nil, nil, "Build complete")

      assert_equal ["Echoes - Build complete"], titles
    end

    test "Windows display info JSON includes monitor geometry and current monitor" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, 99)
      monitors = [
        {handle: 10, x: 0, y: 0, w: 1920, h: 1080, work_x: 0, work_y: 0, work_w: 1920, work_h: 1040, primary: true, dpi_x: 96, dpi_y: 96, scale: 1.0},
        {handle: 20, x: 1920, y: 0, w: 1280, h: 720, work_x: 1920, work_y: 0, work_w: 1280, work_h: 680, primary: false, dpi_x: 144, dpi_y: 144, scale: 1.5}
      ]
      seen_hwnd = nil

      with_win32_singleton_method(:display_monitors, -> { monitors }) do
        with_win32_singleton_method(:monitor_from_window, ->(hwnd) {
          seen_hwnd = hwnd
          20
        }) do
          entries = JSON.parse(gui.send(:display_info_json, nil))

          assert_equal 2, entries.size
          assert_equal({"index" => 0, "x" => 0, "y" => 0, "w" => 1920, "h" => 1080,
                        "work_x" => 0, "work_y" => 0, "work_w" => 1920, "work_h" => 1040,
                        "dpi_x" => 96, "dpi_y" => 96, "backing_scale_factor" => 1.0,
                        "primary" => true, "current" => false}, entries[0])
          assert_equal 1.5, entries[1]["backing_scale_factor"]
          assert_equal true, entries[1]["current"]
        end
      end
      assert_equal 99, seen_hwnd
    end

    test "Windows monitor DPI converts to backing scale factor" do
      with_win32_const(:GetDpiForMonitor, ->(_monitor, mode, x_ptr, y_ptr) {
        assert_equal Echoes::Win32::MDT_EFFECTIVE_DPI, mode
        x_ptr[0, 4] = [144].pack("L")
        y_ptr[0, 4] = [144].pack("L")
        0
      }) do
        assert_equal [144, 144], Echoes::Win32.monitor_dpi(55)
        assert_equal 1.5, Echoes::Win32.monitor_scale_factor(55)
      end
    end

    test "Windows monitor DPI falls back to 96 DPI when unavailable" do
      with_win32_const(:GetDpiForMonitor, nil) do
        assert_equal [96, 96], Echoes::Win32.monitor_dpi(55)
        assert_equal 1.0, Echoes::Win32.monitor_scale_factor(55)
      end
    end

    test "Windows open-window decodes argv and launches child Echoes on requested monitor" do
      monitors = [
        {handle: 11, x: 0, y: 0, w: 800, h: 600, work_x: 0, work_y: 0, work_w: 800, work_h: 560, primary: true},
        {handle: 22, x: 800, y: 0, w: 1024, h: 768, work_x: 800, work_y: 20, work_w: 1024, work_h: 728, primary: false}
      ]
      argv = ["C:/Program Files/Demo/demo.exe", "--show"]
      args = "display=1:program=#{[JSON.generate(argv)].pack('m0')}:fullscreen=no"
      spawned = []
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      gui.define_singleton_method(:child_env_for_open_window) { {"PATH" => "C:\\Windows"} }
      gui.define_singleton_method(:spawn_external_echoes) do |env|
        spawned << env
        12345
      end

      with_win32_singleton_method(:display_monitors, -> { monitors }) do
        with_process_detach(->(pid) { spawned << [:detach, pid] }) do
          assert_true gui.send(:open_window_from_osc, nil, args)
        end
      end

      env = spawned.first
      assert_equal argv, JSON.parse(env["ECHOES_OPEN_WINDOW_PROGRAM"].unpack1("m0"))
      assert_equal "800", env["ECHOES_WINDOW_X"]
      assert_equal "20", env["ECHOES_WINDOW_Y"]
      assert_equal "1024", env["ECHOES_WINDOW_W"]
      assert_equal "728", env["ECHOES_WINDOW_H"]
      assert_equal "45", env["ECHOES_ROWS"]
      assert_equal "128", env["ECHOES_COLS"]
      assert_equal [:detach, 12345], spawned.last
    end

    test "Windows open-window uses full monitor rect for fullscreen" do
      monitors = [
        {handle: 11, x: 50, y: 60, w: 900, h: 700, work_x: 70, work_y: 80, work_w: 860, work_h: 640, primary: true}
      ]
      argv = ["demo.exe"]
      args = "display=0:program=#{[JSON.generate(argv)].pack('m0')}:fullscreen=yes"
      envs = []
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@cell_width, 10)
      gui.instance_variable_set(:@cell_height, 20)
      gui.define_singleton_method(:child_env_for_open_window) { {} }
      gui.define_singleton_method(:spawn_external_echoes) { |env| envs << env; nil }

      with_win32_singleton_method(:display_monitors, -> { monitors }) do
        assert_false gui.send(:open_window_from_osc, nil, args)
      end

      assert_equal "50", envs.first["ECHOES_WINDOW_X"]
      assert_equal "60", envs.first["ECHOES_WINDOW_Y"]
      assert_equal "900", envs.first["ECHOES_WINDOW_W"]
      assert_equal "700", envs.first["ECHOES_WINDOW_H"]
    end

    test "Windows open-window env can seed command and initial window rect" do
      gui = Echoes::GUI.allocate
      argv = ["demo.exe", "--arg"]
      env = {
        "ECHOES_OPEN_WINDOW_PROGRAM" => [JSON.generate(argv)].pack("m0"),
        "ECHOES_ROWS" => "33",
        "ECHOES_COLS" => "120",
        "ECHOES_WINDOW_X" => "10",
        "ECHOES_WINDOW_Y" => "20",
        "ECHOES_WINDOW_W" => "640",
        "ECHOES_WINDOW_H" => "480"
      }

      assert_equal argv, gui.send(:command_from_env, env)
      assert_equal 33, gui.send(:positive_env_integer, "ECHOES_ROWS", env)
      assert_equal({x: 10, y: 20, w: 640, h: 480}, gui.send(:initial_window_rect_from_env, env))
    end

    test "Windows initial window rect restores saved preferences when env is absent" do
      gui = Echoes::GUI.allocate
      prefs = {
        "window_x" => 12.0,
        "window_y" => 34.0,
        "window_w" => 900.0,
        "window_h" => 700.0
      }

      with_preferences_store(prefs) do
        assert_equal({x: 12, y: 34, w: 900, h: 700}, gui.send(:initial_window_rect_from_env, {}))
      end
    end

    test "Windows explicit window env overrides saved preferences" do
      gui = Echoes::GUI.allocate
      prefs = {
        "window_x" => 12.0,
        "window_y" => 34.0,
        "window_w" => 900.0,
        "window_h" => 700.0
      }
      env = {"ECHOES_WINDOW_X" => "1", "ECHOES_WINDOW_Y" => "2", "ECHOES_WINDOW_W" => "300", "ECHOES_WINDOW_H" => "400"}

      with_preferences_store(prefs) do
        assert_equal({x: 1, y: 2, w: 300, h: 400}, gui.send(:initial_window_rect_from_env, env))
      end
    end

    test "Windows save window rect stores current frame preferences" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, 99)
      gui.instance_variable_set(:@window_rect_autosave, true)
      prefs = {}

      with_preferences_store(prefs) do
        with_win32_const(:GetWindowRect, ->(_hwnd, rect) {
          rect[0, Echoes::Win32::RECT_SIZE] = [10, 20, 810, 620].pack("l4")
          1
        }) do
          assert_true gui.send(:save_window_rect)
        end
      end

      assert_equal 10.0, prefs["window_x"]
      assert_equal 20.0, prefs["window_y"]
      assert_equal 800.0, prefs["window_w"]
      assert_equal 600.0, prefs["window_h"]
    end

    test "Windows save window rect skips explicit env windows" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, 99)
      gui.instance_variable_set(:@window_rect_autosave, false)
      prefs = {}

      with_preferences_store(prefs) do
        assert_false gui.send(:save_window_rect)
      end

      assert_empty prefs
    end

    test "Windows PNG encoder writes a valid RGBA PNG container" do
      gui = Echoes::GUI.allocate
      rgba = "\xFF\x00\x00\xFF\x00\xFF\x00\xFF".b

      png = gui.send(:encode_png_rgba, 2, 1, rgba)

      assert_equal "\x89PNG\r\n\x1A\n".b, png.byteslice(0, 8)
      assert_equal "IHDR", png.byteslice(12, 4)
      assert_equal [2, 1, 8, 6], png.byteslice(16, 10).unpack("NNCC")
      assert_include png, "IDAT"
      assert_equal "IEND", png.byteslice(-8, 4)
    end

    test "Windows PDF encoder wraps RGB pixels in an image PDF" do
      gui = Echoes::GUI.allocate
      rgb = "\xFF\x00\x00\x00\xFF\x00".b

      pdf = gui.send(:encode_pdf_rgb_image, 2, 1, rgb)

      assert_equal "%PDF-1.4", pdf.byteslice(0, 8)
      assert_include pdf, "/Subtype /Image"
      assert_include pdf, "/Width 2"
      assert_include pdf, "/Height 1"
      assert_include pdf, "/ColorSpace /DeviceRGB"
      assert_include pdf, "xref"
      assert_include pdf, "%%EOF"
    end

    test "Windows capture writes PNG bytes for pane rect" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 2, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      args = nil
      gui.define_singleton_method(:png_bytes_for_pane_capture) do |source_pane, width, height, is_active|
        args = [source_pane, width, height, is_active]
        "PNG".b
      end

      Dir.mktmpdir do |dir|
        path = File.join(dir, "snap.png")
        assert_true gui.send(:capture_pane_to_png, pane, path)
        assert_equal [pane, 80, 32, true], args
        assert_equal "PNG".b, File.binread(path)
      end
    end

    test "Windows capture writes PDF bytes for non-PNG paths" do
      screen = Echoes::Screen.new(rows: 2, cols: 10)
      pane = StubInputPane.new(screen, [], 0, 0.0)
      pane_tree = StubPaneTree.new(pane, [{x: 0, y: 0, w: 10, h: 2, pane: pane}])
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@active_tab, 0)
      gui.instance_variable_set(:@tabs, [StubLayoutTab.new(pane_tree)])
      gui.instance_variable_set(:@cell_width, 8)
      gui.instance_variable_set(:@cell_height, 16)
      args = nil
      gui.define_singleton_method(:pdf_bytes_for_pane_capture) do |source_pane, width, height, is_active|
        args = [source_pane, width, height, is_active]
        "%PDF".b
      end

      Dir.mktmpdir do |dir|
        path = File.join(dir, "snap.pdf")
        assert_true gui.send(:capture_pane_to_png, pane, path)
        assert_equal [pane, 80, 32, true], args
        assert_equal "%PDF".b, File.binread(path)
      end
    end

    private

    def with_win32_clipboard_text(text)
      singleton = class << Echoes::Win32; self; end
      original = Echoes::Win32.method(:get_clipboard_text)
      singleton.send(:remove_method, :get_clipboard_text)
      singleton.define_method(:get_clipboard_text) { |_hwnd| text }
      yield
    ensure
      singleton.send(:remove_method, :get_clipboard_text)
      singleton.define_method(:get_clipboard_text) { |hwnd| original.call(hwnd) }
    end

    def with_win32_clipboard_setter(setter)
      singleton = class << Echoes::Win32; self; end
      original = Echoes::Win32.method(:set_clipboard_text)
      singleton.send(:remove_method, :set_clipboard_text)
      singleton.define_method(:set_clipboard_text) { |hwnd, text| setter.call(hwnd, text) }
      yield
    ensure
      singleton.send(:remove_method, :set_clipboard_text)
      singleton.define_method(:set_clipboard_text) { |hwnd, text| original.call(hwnd, text) }
    end

    def with_win32_const(name, value)
      original = Echoes::Win32.const_get(name)
      Echoes::Win32.send(:remove_const, name)
      Echoes::Win32.const_set(name, value)
      yield
    ensure
      Echoes::Win32.send(:remove_const, name)
      Echoes::Win32.const_set(name, original)
    end

    def with_window_registry_windows(windows)
      singleton = class << Echoes::WindowRegistry; self; end
      original = Echoes::WindowRegistry.method(:list_windows)
      singleton.send(:remove_method, :list_windows)
      singleton.define_method(:list_windows) { windows }
      yield
    ensure
      singleton.send(:remove_method, :list_windows)
      singleton.define_method(:list_windows) { original.call }
    end

    def with_win32_singleton_method(name, replacement)
      singleton = class << Echoes::Win32; self; end
      original = Echoes::Win32.method(name)
      singleton.send(:remove_method, name)
      singleton.define_method(name, &replacement)
      yield
    ensure
      singleton.send(:remove_method, name)
      singleton.define_method(name) { |*args, **kwargs| original.call(*args, **kwargs) }
    end

    def with_preferences_store(store)
      singleton = class << Echoes::Preferences; self; end
      original_fetch = Echoes::Preferences.method(:fetch_double)
      original_set = Echoes::Preferences.method(:set_double)
      singleton.send(:remove_method, :fetch_double)
      singleton.send(:remove_method, :set_double)
      singleton.define_method(:fetch_double) { |key, default:| store.fetch(key.to_s, default) }
      singleton.define_method(:set_double) { |key, value| store[key.to_s] = value.to_f }
      yield
    ensure
      singleton.send(:remove_method, :fetch_double)
      singleton.send(:remove_method, :set_double)
      singleton.define_method(:fetch_double) { |key, default:| original_fetch.call(key, default: default) }
      singleton.define_method(:set_double) { |key, value| original_set.call(key, value) }
    end

    def with_process_detach(replacement)
      singleton = class << Process; self; end
      original = Process.method(:detach)
      singleton.send(:remove_method, :detach)
      singleton.define_method(:detach) { |pid| replacement.call(pid) }
      yield
    ensure
      singleton.send(:remove_method, :detach)
      singleton.define_method(:detach) { |pid| original.call(pid) }
    end
  end
end

if Echoes::Platform.macos?
  class Echoes::GUIFileDropTest < Test::Unit::TestCase
    def create_pasteboard_with_file_urls(*paths)
      pb = ObjC::MSG_PTR_1.call(
        ObjC.cls('NSPasteboard'),
        ObjC.sel('pasteboardWithName:'),
        ObjC.nsstring("com.echoes.test.#{object_id}")
      )

      urls = paths.map do |path|
        ObjC::MSG_PTR_1.call(
          ObjC.cls('NSURL'),
          ObjC.sel('fileURLWithPath:'),
          ObjC.nsstring(path)
        )
      end

      ns_array = ObjC::MSG_PTR.call(ObjC.cls('NSMutableArray'), ObjC.sel('array'))
      urls.each do |url|
        ObjC::MSG_VOID_1.call(ns_array, ObjC.sel('addObject:'), url)
      end

      ObjC::MSG_VOID.call(pb, ObjC.sel('clearContents'))
      ObjC::MSG_PTR_1.call(pb, ObjC.sel('writeObjects:'), ns_array)

      pb
    end

    ObjC = Echoes::ObjC

    test "file_paths_from_pasteboard returns shell-escaped path for a single file" do
      pb = create_pasteboard_with_file_urls("/tmp/hello.txt")
      result = Echoes::GUI.file_paths_from_pasteboard(pb)
      assert_equal("/tmp/hello.txt", result)
    end

    test "file_paths_from_pasteboard escapes spaces in paths" do
      pb = create_pasteboard_with_file_urls("/tmp/my file.txt")
      result = Echoes::GUI.file_paths_from_pasteboard(pb)
      assert_equal("/tmp/my\\ file.txt", result)
    end

    test "file_paths_from_pasteboard joins multiple files with spaces" do
      pb = create_pasteboard_with_file_urls("/tmp/a.txt", "/tmp/b.txt")
      result = Echoes::GUI.file_paths_from_pasteboard(pb)
      assert_equal("/tmp/a.txt /tmp/b.txt", result)
    end

    test "file_paths_from_pasteboard handles multiple files with spaces" do
      pb = create_pasteboard_with_file_urls("/tmp/my file.txt", "/tmp/other file.txt")
      result = Echoes::GUI.file_paths_from_pasteboard(pb)
      assert_equal("/tmp/my\\ file.txt /tmp/other\\ file.txt", result)
    end

    test "file_paths_from_pasteboard returns nil for empty pasteboard" do
      pb = ObjC::MSG_PTR_1.call(
        ObjC.cls('NSPasteboard'),
        ObjC.sel('pasteboardWithName:'),
        ObjC.nsstring("com.echoes.test.empty.#{object_id}")
      )
      ObjC::MSG_VOID.call(pb, ObjC.sel('clearContents'))
      result = Echoes::GUI.file_paths_from_pasteboard(pb)
      assert_nil(result)
    end

    test "file_paths_from_pasteboard escapes special shell characters" do
      pb = create_pasteboard_with_file_urls("/tmp/file(1).txt")
      result = Echoes::GUI.file_paths_from_pasteboard(pb)
      assert_equal("/tmp/file\\(1\\).txt", result)
    end
  end

  class Echoes::GUIOpenNewWindowTest < Test::Unit::TestCase
    # Regression: pressing cmd+n used to open a blank window with no shell
    # rendering. makeKeyAndOrderFront: on the new window synchronously fires
    # NSWindowDidResignKeyNotification on the previously-key window, whose
    # observer is its NSView. That handler called activate_for_view, which
    # reset @view back to the old window's view mid-construction. The new ws
    # then got registered under the OLD view's pointer, overwriting the
    # existing mapping; the new view was never invalidated, so the window
    # stayed blank.
    test "open_new_window: each new window's view is uniquely registered in @view_to_ws" do
      gui = Echoes::GUI.new(command: '/bin/cat', rows: 24, cols: 80, font_size: 12.0)
      gui.setup_app
      gui.create_fonts
      gui.create_view_class
      gui.send(:open_new_window)
      gui.send(:open_new_window)

      window_states = gui.instance_variable_get(:@window_states)
      view_to_ws = gui.instance_variable_get(:@view_to_ws)

      assert_equal(2, window_states.size, "two open_new_window calls should produce two ws entries")
      assert_equal(2, view_to_ws.size, "two open_new_window calls should produce two view->ws mappings")

      view_ptrs = window_states.map { |ws| ws[:nsview].to_i }
      assert_equal(view_ptrs.size, view_ptrs.uniq.size, "windows must have distinct view pointers")

      window_states.each do |ws|
        assert_equal(ws, view_to_ws[ws[:nsview].to_i],
                     "each ws[:nsview] must map back to the same ws via @view_to_ws")
      end
    ensure
      # Hide windows and reap shell processes so the test doesn't leak PTYs or
      # leave windows on screen.
      if defined?(window_states) && window_states
        window_states.each do |ws|
          ws[:tabs]&.each(&:close)
          if ws[:nswindow]
            Echoes::ObjC::MSG_VOID_1.call(ws[:nswindow], Echoes::ObjC.sel('orderOut:'),
                                           Fiddle::Pointer.new(0)) rescue nil
          end
        end
      end
    end
  end
end

if defined?(Echoes::GUI)
class Echoes::GUICwdFromOsc7UriTest < Test::Unit::TestCase
  def file_uri(path, host: nil)
    normalized = path.tr('\\', '/')
    uri_path = normalized.start_with?('/') ? normalized : "/#{normalized}"
    "file://#{host}#{uri_path.gsub(' ', '%20')}"
  end

  test "returns nil for nil or empty input" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri(nil))
    assert_nil(Echoes::GUI.cwd_from_osc7_uri(""))
  end

  test "returns the path for file://localhost/<existing path>" do
    path = Dir.tmpdir
    assert_equal(path, Echoes::GUI.cwd_from_osc7_uri(file_uri(path, host: 'localhost')))
  end

  test "returns the path for file:///<existing path> (empty host)" do
    path = Dir.tmpdir
    assert_equal(path, Echoes::GUI.cwd_from_osc7_uri(file_uri(path)))
  end

  test "URL-decodes percent-encoded path components" do
    Dir.mktmpdir("echoes test ") do |dir|
      encoded = file_uri(dir, host: 'localhost')
      assert_equal(dir, Echoes::GUI.cwd_from_osc7_uri(encoded))
    end
  end

  test "returns nil for non-file scheme" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri("http://localhost/tmp"))
  end

  test "returns nil for a remote host" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri("file://other-host.example.com/tmp"))
  end

  test "returns nil for a path that does not exist locally" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri("file:///nonexistent-#{rand(1 << 30)}"))
  end

  test "returns nil for a malformed URI" do
    assert_nil(Echoes::GUI.cwd_from_osc7_uri("file://[bad"))
  end
end
end

class Echoes::GUISelectedTextTest < Test::Unit::TestCase
  # Regression: copying a region that contained an OSC 66 multicell
  # character (or a wide CJK / emoji glyph) used to include a literal
  # space for each continuation cell. Selecting "Text" rendered via
  # OSC 66 produced "T e x t" in the clipboard. Continuation cells
  # have either width == 0 (CJK second-half) or multicell == :cont
  # (OSC 66 follow-up cells); both must be skipped during extraction.
  #
  # Bypass GUI.new (AppKit setup is unstable when multiple GUIs exist
  # in the same process); set up just the state selected_text_from_buffer
  # actually reads — current_tab.screen and @cols.

  StubTab = Struct.new(:screen)

  def make_gui_with_screen(rows: 5, cols: 30)
    screen = Echoes::Screen.new(rows: rows, cols: cols)
    gui = Echoes::GUI.allocate
    gui.instance_variable_set(:@cols, cols)
    gui.instance_variable_set(:@rows, rows)
    gui.instance_variable_set(:@active_tab, 0)
    gui.instance_variable_set(:@tabs, [StubTab.new(screen)])
    [gui, screen]
  end

  def write(screen, row, col, char, **attrs)
    cell = screen.grid[row][col]
    cell.char = char
    attrs.each { |k, v| cell.send("#{k}=", v) }
  end

  test "skips OSC 66 continuation cells (multicell == :cont)" do
    gui, screen = make_gui_with_screen
    write(screen, 0, 0, 'T', multicell: {cols: 2, rows: 1})
    write(screen, 0, 1, ' ', multicell: :cont)
    write(screen, 0, 2, 'e', multicell: {cols: 2, rows: 1})
    write(screen, 0, 3, ' ', multicell: :cont)
    write(screen, 0, 4, 'x', multicell: {cols: 2, rows: 1})
    write(screen, 0, 5, ' ', multicell: :cont)
    write(screen, 0, 6, 't', multicell: {cols: 2, rows: 1})
    write(screen, 0, 7, ' ', multicell: :cont)
    assert_equal "Text", gui.send(:selected_text_from_buffer, 0, 0, 0, 7)
  end

  test "skips wide-char continuation cells (width == 0)" do
    gui, screen = make_gui_with_screen
    write(screen, 0, 0, '漢', width: 2)
    write(screen, 0, 1, ' ', width: 0)
    write(screen, 0, 2, '字', width: 2)
    write(screen, 0, 3, ' ', width: 0)
    assert_equal "漢字", gui.send(:selected_text_from_buffer, 0, 0, 0, 3)
  end

  test "regular single-cell text still extracts unchanged" do
    gui, screen = make_gui_with_screen
    "hello".chars.each_with_index { |c, i| write(screen, 0, i, c) }
    assert_equal "hello", gui.send(:selected_text_from_buffer, 0, 0, 0, 4)
  end
end

class Echoes::GUICaptureFormatTest < Test::Unit::TestCase
  test ".png paths capture as raster PNG" do
    assert_equal :png, Echoes::GUI.capture_format_for('/tmp/snap.png')
  end

  test ".pdf paths capture as vector PDF" do
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap.pdf')
  end

  test "extension dispatch is case-insensitive" do
    assert_equal :png, Echoes::GUI.capture_format_for('/tmp/snap.PNG')
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap.PDF')
  end

  test "unknown or missing extensions default to PDF" do
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap')
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap.jpg')
    assert_equal :pdf, Echoes::GUI.capture_format_for('/tmp/snap.tiff')
  end
end

class Echoes::GUISearchMatcherTest < Test::Unit::TestCase
  def make_gui(regex: false, case_insensitive: false)
    gui = Echoes::GUI.allocate
    gui.instance_variable_set(:@search_regex_mode, regex)
    gui.instance_variable_set(:@search_case_insensitive, case_insensitive)
    gui
  end

  def find_all(gui, query, text)
    matcher = gui.send(:build_search_matcher, query)
    return nil if matcher.nil?
    hits = []
    pos = 0
    while pos <= text.length && (hit = matcher.call(text, pos))
      idx, len = hit
      break if idx < pos     # regex returned a stale match — done
      hits << [idx, len]
      pos = idx + [len, 1].max
    end
    hits
  end

  test "substring mode case-sensitive finds every occurrence" do
    gui = make_gui
    assert_equal [[0, 3], [12, 3], [25, 3]],
                 find_all(gui, 'foo', 'foo bar baz foo qux quux foo')
  end

  test "substring mode case-sensitive skips wrong-case matches" do
    gui = make_gui
    assert_equal [[0, 3]],
                 find_all(gui, 'foo', 'foo Foo FOO')
  end

  test "case-insensitive substring mode matches all cases" do
    gui = make_gui(case_insensitive: true)
    assert_equal [[0, 3], [4, 3], [8, 3]],
                 find_all(gui, 'foo', 'foo Foo FOO')
  end

  test "regex mode finds pattern matches" do
    gui = make_gui(regex: true)
    assert_equal [[0, 3], [4, 4], [9, 5]],
                 find_all(gui, '\d+', '123 4567 89012 abc')
  end

  test "regex + case-insensitive folds the regex" do
    gui = make_gui(regex: true, case_insensitive: true)
    hits = find_all(gui, 'foo', 'foo Foo FOO')
    assert_equal [[0, 3], [4, 3], [8, 3]], hits
  end

  test "regex mode returns nil for invalid pattern (no crash)" do
    gui = make_gui(regex: true)
    matcher = gui.send(:build_search_matcher, '[unclosed')
    assert_nil matcher
  end

  test "regex mode with a zero-width match still advances" do
    gui = make_gui(regex: true)
    # `\b` is zero-width — the loop must not infinite-loop on it.
    hits = find_all(gui, '\b', 'hello world')
    assert hits.size <= 'hello world'.length + 1
  end
end

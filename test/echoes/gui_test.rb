# frozen_string_literal: true

require "test_helper"
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
    StubTab = Struct.new(:active_pane) do
      def screen
        active_pane.screen
      end
    end
    StubScreenOnlyPane = Struct.new(:screen) do
      def refresh_pty_pixel_size; end
    end
    StubCopyMode = Struct.new(:selection_start, :selection_end) do
      def active = true
      def selecting? = true
    end
    StubCellStyle = Struct.new(:bold, :italic, :char)

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

    test "Windows font fallback selects fonts by Unicode range" do
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hfont, 1)
      gui.instance_variable_set(:@font_cache, {})
      gui.define_singleton_method(:create_font) do |weight: 400, italic: false, height: nil, family: nil|
        "font:#{family}:#{weight}:#{italic}"
      end

      assert_equal 1, gui.send(:font_for_cell, StubCellStyle.new(false, false, "A"))
      assert_equal "font:Yu Gothic UI:400:false",
                   gui.send(:font_for_cell, StubCellStyle.new(false, false, "漢"))
      assert_equal "font:Segoe UI Emoji:400:false",
                   gui.send(:font_for_cell, StubCellStyle.new(false, false, "\u{1F600}"))
      assert_equal "font:Segoe UI Symbol:700:true",
                   gui.send(:font_for_cell, StubCellStyle.new(true, true, "▶"))
    end

    test "Windows text runs split when fallback font family changes" do
      gui = Echoes::GUI.allocate

      assert_equal [0, 2],
                   gui.send(:same_font_run_range, [StubCellStyle.new(false, false, "a"),
                                                    StubCellStyle.new(false, false, "b"),
                                                    StubCellStyle.new(false, false, "漢")], 0)
      assert_equal [2, 1],
                   gui.send(:same_font_run_range, [StubCellStyle.new(false, false, "a"),
                                                    StubCellStyle.new(false, false, "b"),
                                                    StubCellStyle.new(false, false, "漢")], 2)
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

    test "Windows screen handlers include notifications" do
      screen = Echoes::Screen.new(rows: 1, cols: 1)
      pane = StubScreenOnlyPane.new(screen)
      gui = Echoes::GUI.allocate
      gui.instance_variable_set(:@hwnd, 123)

      gui.send(:wire_screen_handlers, pane)

      captured = nil
      with_win32_notification(->(hwnd, title, message) { captured = [hwnd, title, message] }) do
        screen.notification_handler.call("Build", "Finished")
      end

      assert_equal [123, "Build", "Finished"], captured
    end

    test "Windows open_url delegates http urls to ShellExecute" do
      gui = Echoes::GUI.allocate

      opened = nil
      with_win32_url_opener(->(url) { opened = url }) do
        assert_true gui.send(:open_url, "https://example.com/a")
      end

      assert_equal "https://example.com/a", opened
    end

    test "Windows open_url rejects unsupported schemes" do
      gui = Echoes::GUI.allocate

      opened = nil
      with_win32_url_opener(->(url) { opened = url }) do
        assert_false gui.send(:open_url, "file:///C:/secret.txt")
      end

      assert_nil opened
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

    def with_win32_notification(setter)
      singleton = class << Echoes::Win32; self; end
      original = Echoes::Win32.method(:show_notification)
      singleton.send(:remove_method, :show_notification)
      singleton.define_method(:show_notification) { |hwnd, title, message| setter.call(hwnd, title, message) }
      yield
    ensure
      singleton.send(:remove_method, :show_notification)
      singleton.define_method(:show_notification) { |hwnd, title, message| original.call(hwnd, title, message) }
    end

    def with_win32_url_opener(opener)
      singleton = class << Echoes::Win32; self; end
      original = Echoes::Win32.method(:open_url)
      singleton.send(:remove_method, :open_url)
      singleton.define_method(:open_url) { |url| opener.call(url) }
      yield
    ensure
      singleton.send(:remove_method, :open_url)
      singleton.define_method(:open_url) { |url| original.call(url) }
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

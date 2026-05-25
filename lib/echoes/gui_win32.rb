# frozen_string_literal: true

require_relative 'win32'
require_relative 'tab'
require_relative 'pane'
require_relative 'preferences'
require_relative 'profile'
require_relative 'configuration'
require 'socket'
require 'uri'

module Echoes
  class GUI
    def self.pane_local_cwd(pane)
      uri_str = pane&.screen&.current_directory
      cwd_from_osc7_uri(uri_str)
    end

    def self.cwd_from_osc7_uri(uri_str)
      return nil if uri_str.nil? || uri_str.empty?
      uri = URI.parse(uri_str) rescue nil
      return nil unless uri && uri.scheme == 'file'
      host = uri.host.to_s
      local_host = Socket.gethostname
      unless host.empty? || host == 'localhost' ||
             host == local_host || host == local_host.split('.').first
        return nil
      end
      path = URI.decode_www_form_component(uri.path) rescue nil
      path = path[1..] if path && path.match?(/\A\/[A-Za-z]:\//)
      path if path && !path.empty? && Dir.exist?(path)
    end

    def initialize(command: Echoes.config.shell, rows: Echoes.config.rows, cols: Echoes.config.cols, font_size: nil)
      if ENV['ECHOES_EMBED'] == '1'
        raise Error, 'Embedded rubish mode is not supported on Windows yet'
      end

      ENV['TERM_PROGRAM']         = 'Echoes'
      ENV['TERM_PROGRAM_VERSION'] = Echoes::VERSION
      @rows = rows
      @cols = cols
      @font_size = font_size || Preferences.fetch_double(:font_size, default: Echoes.config.font_size)
      @command = command
      @tabs = []
      @active_tab = 0
      @font_cache = {}
      @hwnd = nil
      @hfont = nil
      @bold_hfont = nil
      @italic_hfont = nil
      @bold_italic_hfont = nil
      @fallback_font_cache = {}
      @font_fallback_candidates = [
        "Yu Gothic UI",
        "Meiryo",
        "Segoe UI Emoji",
        "Segoe UI Symbol",
        "MS Gothic"
      ]
      @cell_width = nil
      @cell_height = nil
      @running = false
      @marked_text = nil # IME inline composition string

      # カラーテーマの初期化
      @active_profile = Echoes.config.active_profile rescue nil
      @colors = build_color_table
      @default_fg = make_color(*default_fg_rgb)
      @default_bg = make_color(*default_bg_rgb)

      # 境界線・デバイダー用ブラシの作成
      @active_border_brush = Win32::CreateSolidBrush.call(make_color(0.2, 0.4, 0.8))
      @inactive_border_brush = Win32::CreateSolidBrush.call(make_color(0.3, 0.3, 0.3))

      # 初期タブの起動
      create_tab
    end

    def current_tab
      @tabs[@active_tab]
    end

    def create_tab(editor_file: nil)
      tab = Tab.new(command: @command, rows: @rows, cols: @cols, editor_file: editor_file)
      tab.panes.each { |pane| wire_screen_handlers(pane) }
      @tabs << tab
      @active_tab = @tabs.size - 1
      tab
    end

    def run
      # 1. Register the window class
      wnd_class = Fiddle::Pointer.malloc(Win32::WNDCLASSEXW_SIZE, Fiddle::RUBY_FREE)
      wnd_class[0, Win32::WNDCLASSEXW_SIZE] = "\x00" * Win32::WNDCLASSEXW_SIZE
      wnd_class[0, 4] = [Win32::WNDCLASSEXW_SIZE].pack('L')
      wnd_class[4, 4] = [Win32::CS_HREDRAW | Win32::CS_VREDRAW].pack('L')

      # WndProc の定義
      wnd_proc = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_LONG_LONG, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_LONG_LONG]) do |hwnd, msg, wparam, lparam|
        case msg
        when Win32::WM_DESTROY
          @running = false
          close_tabs
          delete_font_handles
          if @active_border_brush
            Win32::DeleteObject.call(@active_border_brush)
          end
          if @inactive_border_brush
            Win32::DeleteObject.call(@inactive_border_brush)
          end
          Win32::PostQuitMessage.call(0)
          0

        when Win32::WM_PAINT
          ps = Fiddle::Pointer.malloc(Win32::PAINTSTRUCT_SIZE, Fiddle::RUBY_FREE)
          ps[0, Win32::PAINTSTRUCT_SIZE] = "\x00" * Win32::PAINTSTRUCT_SIZE
          hdc = Win32::BeginPaint.call(hwnd, ps)
          begin
            old_font = Win32::SelectObject.call(hdc, @hfont)
            Win32::SetBkMode.call(hdc, Win32::OPAQUE)

            if (tab = current_tab)
              # セルサイズを動的に測定
              if !@cell_width || @cell_width == 0
                size_ptr = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
                size_ptr[0, 8] = "\x00" * 8
                test_str = Win32.to_wstring("A")
                Win32::GetTextExtentPoint32W.call(hdc, Fiddle::Pointer[test_str], 1, size_ptr)
                @cell_width = size_ptr[0, 4].unpack1('L')
                @cell_height = size_ptr[4, 4].unpack1('L')
                @cell_width = 8 if @cell_width == 0
                @cell_height = 16 if @cell_height == 0
              end

              # 全ペインのレイアウトを取得して描画
              layout = tab.pane_tree.layout(0, 0, @cols, @rows)
              layout.each do |rect|
                pane = rect[:pane]
                gx = rect[:x]
                gy = rect[:y]
                gw = rect[:w]
                gh = rect[:h]

                px = gx * @cell_width
                py = gy * @cell_height
                pw = gw * @cell_width
                ph = gh * @cell_height

                is_active = (pane == tab.active_pane)

                # ペインのピクセルサイズを更新
                pane.screen.cell_pixel_width = @cell_width.to_f
                pane.screen.cell_pixel_height = @cell_height.to_f

                # ペインの内容描画
                draw_pane_content(hdc, pane, px, py, pw, ph, is_active)

                # ペイン境界線（デバイダーおよびアクティブ強調）の描画
                if layout.size > 1
                  border_rect = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
                  border_rect[0, Win32::RECT_SIZE] = [px, py, px + pw, py + ph].pack('l4')
                  if is_active
                    # アクティブなペインは明るい枠線
                    Win32::FrameRect.call(hdc, border_rect, @active_border_brush)
                  else
                    # 非アクティブなペインは暗い枠線
                    Win32::FrameRect.call(hdc, border_rect, @inactive_border_brush)
                  end
                end
              end
            end

            Win32::SelectObject.call(hdc, old_font)
          ensure
            Win32::EndPaint.call(hwnd, ps)
          end
          0

        when Win32::WM_LBUTTONDOWN
          Win32::SetFocus.call(hwnd)
          x_pos = lparam.to_i & 0xFFFF
          y_pos = (lparam.to_i >> 16) & 0xFFFF

          if @cell_width && @cell_width > 0 && @cell_height && @cell_height > 0 && (tab = current_tab)
            cell_x = x_pos / @cell_width
            cell_y = y_pos / @cell_height

            layout = tab.pane_tree.layout(0, 0, @cols, @rows)
            target_rect = layout.find do |rect|
              cell_x >= rect[:x] && cell_x < (rect[:x] + rect[:w]) &&
              cell_y >= rect[:y] && cell_y < (rect[:y] + rect[:h])
            end

            if target_rect && target_rect[:pane] != tab.active_pane
              tab.pane_tree.active_pane = target_rect[:pane]
              Win32::InvalidateRect.call(hwnd, nil, 1)
            end
          end
          0

        when Win32::WM_IME_STARTCOMPOSITION
          @marked_text = ""
          0

        when Win32::WM_IME_ENDCOMPOSITION
          @marked_text = nil
          Win32::InvalidateRect.call(hwnd, nil, 1)
          0

        when Win32::WM_IME_COMPOSITION
          if (lparam.to_i & Win32::GCS_COMPSTR) != 0
            himc = Win32::ImmGetContext.call(hwnd)
            if himc && himc.to_i != 0
              len = Win32::ImmGetCompositionStringW.call(himc, Win32::GCS_COMPSTR, nil, 0)
              if len > 0
                buf = Fiddle::Pointer.malloc(len + 2, Fiddle::RUBY_FREE)
                buf[0, len + 2] = "\x00" * (len + 2)
                Win32::ImmGetCompositionStringW.call(himc, Win32::GCS_COMPSTR, buf, len)
                @marked_text = buf.to_str(len).force_encoding('UTF-16LE').encode('UTF-8') rescue nil
              else
                @marked_text = nil
              end
              Win32::ImmReleaseContext.call(hwnd, himc)
            end
            Win32::InvalidateRect.call(hwnd, nil, 1)
          end
          0

        when Win32::WM_CHAR
          char_code = wparam.to_i
          unless [0x08, 0x09, 0x0D, 0x1B].include?(char_code)
            utf8_char = [char_code].pack('S').force_encoding('UTF-16LE').encode('UTF-8') rescue nil
            if utf8_char && (tab = current_tab) && (pane = tab.active_pane)
              pane.write_input(utf8_char)
            end
          end
          0

        when Win32::WM_KEYDOWN
          vk = wparam.to_i
          ctrl_pressed = (Win32::GetKeyState.call(0x11) & 0x8000) != 0
          shift_pressed = (Win32::GetKeyState.call(0x10) & 0x8000) != 0

          handled_key = false
          if ctrl_pressed && shift_pressed
            case vk
            when 0x43 # C
              copy_to_clipboard
              handled_key = true
            when 0x56 # V
              paste_from_clipboard
              handled_key = true
            end
          end

          escape_sequence = nil
          unless handled_key
            escape_sequence = windows_key_sequence(vk, ctrl_pressed: ctrl_pressed)
            if escape_sequence && (tab = current_tab) && (pane = tab.active_pane)
              pane.write_input(escape_sequence)
            end
          end
          0

        when Win32::WM_SIZE
          width = lparam.to_i & 0xFFFF
          height = (lparam.to_i >> 16) & 0xFFFF
          handle_window_resize_pixels(width, height)
          0

        else
          Win32::DefWindowProcW.call(hwnd, msg, wparam, lparam)
        end
      end

      # GC対策の参照保持
      @wnd_proc_callback = wnd_proc

      wnd_class[8, 8] = [wnd_proc.to_i].pack('Q') # lpfnWndProc
      wnd_class[16, 4] = [0].pack('L') # cbClsExtra
      wnd_class[20, 4] = [0].pack('L') # cbWndExtra
      wnd_class[24, 8] = [0].pack('Q') # hInstance

      icon = 0
      cursor = 0
      bg_brush = Win32::CreateSolidBrush.call(@default_bg) # バックグラウンド色で塗り潰すブラシ

      wnd_class[32, 8] = [icon].pack('Q')      # hIcon
      wnd_class[40, 8] = [cursor].pack('Q')    # hCursor
      wnd_class[48, 8] = [bg_brush].pack('Q')  # hbrBackground
      wnd_class[56, 8] = [0].pack('Q')         # lpszMenuName

      class_name = Win32.to_wstring("EchoesWindowClass")
      wnd_class[64, 8] = [Fiddle::Pointer[class_name].to_i].pack('Q') # lpszClassName
      wnd_class[72, 8] = [0].pack('Q')         # hIconSm

      Win32::RegisterClassExW.call(wnd_class)

      # Font の作成
      @hfont = create_font
      @bold_hfont = create_font(weight: 700)
      @italic_hfont = create_font(italic: true)
      @bold_italic_hfont = create_font(weight: 700, italic: true)

      # 2. Create the window
      window_title = Win32.to_wstring(Echoes.config.window_title)
      @hwnd = Win32::CreateWindowExW.call(
        0,                                     # dwExStyle
        Fiddle::Pointer[class_name],           # lpClassName
        Fiddle::Pointer[window_title],         # lpWindowName
        Win32::WS_OVERLAPPEDWINDOW | Win32::WS_VISIBLE, # dwStyle
        100, 100,                              # x, y
        800, 600,                              # nWidth, nHeight
        0, 0, 0, 0                             # hWndParent, hMenu, hInstance, lpParam
      )

      raise "echoes win32: failed to create window" if @hwnd.null?

      Win32::ShowWindow.call(@hwnd, Win32::SW_SHOWNORMAL)
      Win32::UpdateWindow.call(@hwnd)
      Win32::SetFocus.call(@hwnd)

      # 3. Message Loop & I/O 同期ポーリング
      @running = true
      pm_remove = 1
      msg_struct = Fiddle::Pointer.malloc(Win32::MSG_SIZE, Fiddle::RUBY_FREE)
      msg_struct[0, Win32::MSG_SIZE] = "\x00" * Win32::MSG_SIZE

      while @running
        # A. Windows メッセージがある間すべてディスパッチする (ノンブロッキング)
        while Win32::PeekMessageW.call(msg_struct, 0, 0, 0, pm_remove) != 0
          message = msg_struct[8, 4].unpack1('L')
          if message == 0x0012 # WM_QUIT
            @running = false
            break
          end
          Win32::TranslateMessage.call(msg_struct)
          Win32::DispatchMessageW.call(msg_struct)
        end

        break unless @running

        # B. 同期的にシェルプロセスの出力をポーリング
        begin
          poll_active_pane_output
        rescue => e
          warn "echoes win32: I/O polling error: #{e.message}"
        end

        # C. CPU負荷低減と Ruby の GVL 解放のため、適度にスリープ
        sleep 0.015
      end

      # Cleanup
      close_tabs
      delete_font_handles
      Win32::DeleteObject.call(bg_brush)
    end

    private

    private def windows_key_sequence(vk, ctrl_pressed: false)
      if ctrl_pressed && vk >= 0x41 && vk <= 0x5A
        return (vk - 0x40).chr
      end

      case vk
      when 0x26 then "\e[A"  # VK_UP
      when 0x28 then "\e[B"  # VK_DOWN
      when 0x27 then "\e[C"  # VK_RIGHT
      when 0x25 then "\e[D"  # VK_LEFT
      when 0x24 then "\e[H"  # VK_HOME
      when 0x23 then "\e[F"  # VK_END
      when 0x21 then "\e[5~" # VK_PRIOR (PgUp)
      when 0x22 then "\e[6~" # VK_NEXT (PgDn)
      when 0x2E then "\e[3~" # VK_DELETE
      when 0x08 then "\x7F"  # VK_BACK; cmd.exe expects DEL for normal erase
      when 0x09 then "\t"    # VK_TAB
      when 0x0D then "\r"    # VK_RETURN
      when 0x1B then "\e"    # VK_ESCAPE
      end
    end

    private def poll_active_pane_output
      tab = current_tab
      pane = tab&.active_pane
      return false unless pane&.alive?

      output = pane.read_available_output
      return false if output.nil? || output.empty?

      pane.parser.feed(output)
      if @hwnd && !Win32.null_pointer?(@hwnd)
        Win32::InvalidateRect.call(@hwnd, nil, 1)
        Win32::UpdateWindow.call(@hwnd)
      end
      true
    end

    private def close_tabs
      tabs = @tabs || []
      @tabs = []
      tabs.each { |tab| tab.close rescue nil }
      @active_tab = 0
    end

    private def handle_window_resize_pixels(width, height)
      return false unless @cell_width && @cell_width > 0 && @cell_height && @cell_height > 0

      cols = (width / @cell_width).to_i
      rows = (height / @cell_height).to_i
      return false if cols <= 0 || rows <= 0
      return false if cols == @cols && rows == @rows

      @cols = cols
      @rows = rows
      current_tab&.resize(rows, cols)
      true
    end

    private def create_font(weight: 400, italic: false, height: nil, family: nil)
      font_height = height || (@font_size ? @font_size.to_i : 16)
      font_name = Win32.to_wstring(family || Echoes.config.font_family || "Consolas")
      Win32::CreateFontW.call(
        font_height, 0, 0, 0,
        weight, italic ? 1 : 0, 0, 0,
        1, 0, 0, 0,
        0x01 | 0x10,
        Fiddle::Pointer[font_name]
      )
    end

    private def delete_font_handles
      [:@hfont, :@bold_hfont, :@italic_hfont, :@bold_italic_hfont].each do |ivar|
        handle = instance_variable_get(ivar)
        next unless handle

        Win32::DeleteObject.call(handle)
        instance_variable_set(ivar, nil)
      end
      (@fallback_font_cache || {}).each_value { |handle| Win32::DeleteObject.call(handle) if handle }
      @fallback_font_cache = {}
    end

    private def font_for_cell(cell)
      if cell.bold && cell.italic
        @bold_italic_hfont || @bold_hfont || @italic_hfont || @hfont
      elsif cell.bold
        @bold_hfont || @hfont
      elsif cell.italic
        @italic_hfont || @hfont
      else
        @hfont
      end
    end

    private def font_for_text(base_font, text, bold: false, italic: false)
      return base_font if text.to_s.each_char.all? { |char| font_has_glyph?(base_font, char) }

      (@font_fallback_candidates || []).each do |family|
        font = fallback_font(family, bold: bold, italic: italic)
        return font if text.to_s.each_char.all? { |char| font_has_glyph?(font, char) }
      end

      if text.to_s.each_char.any? { |char| emoji_codepoint?(char.ord) }
        return fallback_font("Segoe UI Emoji", bold: bold, italic: italic)
      end

      base_font
    end

    private def emoji_codepoint?(codepoint)
      (0x1F000..0x1FAFF).cover?(codepoint) ||
        (0x2600..0x27BF).cover?(codepoint)
    end

    private def font_runs_for_text(base_font, text, bold: false, italic: false)
      runs = []
      text.to_s.each_char do |char|
        font = font_for_text(base_font, char, bold: bold, italic: italic)
        if runs.last && runs.last[1] == font
          runs.last[0] << char
        else
          runs << [char.dup, font]
        end
      end
      runs
    end

    private def fallback_font(family, bold: false, italic: false)
      @fallback_font_cache ||= {}
      key = [family, bold, italic]
      @fallback_font_cache[key] ||= create_font(
        family: family,
        weight: bold ? 700 : 400,
        italic: italic
      )
    end

    private def font_has_glyph?(font, char)
      return true unless Win32::GetGlyphIndicesW

      hdc = Win32::GetDC.call(@hwnd || 0)
      return true if !hdc || Win32.null_pointer?(hdc)

      previous_font = Win32::SelectObject.call(hdc, font)
      begin
        wstr = Win32.to_wstring(char)
        glyph_count = wstr.bytesize / 2 - 1
        glyph = Fiddle::Pointer.malloc(glyph_count * 2, Fiddle::RUBY_FREE)
        glyph[0, glyph_count * 2] = "\x00" * (glyph_count * 2)
        result = Win32::GetGlyphIndicesW.call(
          hdc,
          Fiddle::Pointer[wstr],
          glyph_count,
          glyph,
          Win32::GGI_MARK_NONEXISTING_GLYPHS
        )
        result != -1 &&
          result != 0xFFFFFFFF &&
          glyph[0, glyph_count * 2].unpack('v*').all? { |index| index != 0xFFFF }
      ensure
        Win32::SelectObject.call(hdc, previous_font) if previous_font
        Win32::ReleaseDC.call(@hwnd || 0, hdc)
      end
    end

    def build_color_table
      ansi_rgb = [
        [0.0,  0.0,  0.0],   # 0: black
        [0.8,  0.0,  0.0],   # 1: red
        [0.0,  0.8,  0.0],   # 2: green
        [0.8,  0.8,  0.0],   # 3: yellow
        [0.0,  0.0,  0.8],   # 4: blue
        [0.8,  0.0,  0.8],   # 5: magenta
        [0.0,  0.8,  0.8],   # 6: cyan
        [0.75, 0.75, 0.75],  # 7: white
        [0.5,  0.5,  0.5],   # 8: bright black
        [1.0,  0.0,  0.0],   # 9: bright red
        [0.0,  1.0,  0.0],   # 10: bright green
        [1.0,  1.0,  0.0],   # 11: bright yellow
        [0.0,  0.0,  1.0],   # 12: bright blue
        [1.0,  0.0,  1.0],   # 13: bright magenta
        [0.0,  1.0,  1.0],   # 14: bright cyan
        [1.0,  1.0,  1.0],   # 15: bright white
      ]

      if (palette = @active_profile&.color_palette)
        palette.each_with_index do |rgb, i|
          ansi_rgb[i] = rgb if i < 16 && rgb
        end
      end

      colors = {}
      ansi_rgb.each_with_index do |(r, g, b), i|
        colors[i] = make_color(r, g, b)
      end

      216.times do |i|
        idx = 16 + i
        b_val = (i % 6) * 51
        g_val = ((i / 6) % 6) * 51
        r_val = (i / 36) * 51
        colors[idx] = make_color(r_val / 255.0, g_val / 255.0, b_val / 255.0)
      end

      24.times do |i|
        idx = 232 + i
        v = (8 + 10 * i) / 255.0
        colors[idx] = make_color(v, v, v)
      end

      colors
    end

    def default_fg_rgb
      if @active_profile
        @active_profile.foreground
      else
        Echoes.config.foreground
      end
    end

    def default_bg_rgb
      if @active_profile
        @active_profile.background
      else
        Echoes.config.background
      end
    end

    def make_color(r, g, b)
      ir = (r * 255).round
      ig = (g * 255).round
      ib = (b * 255).round
      (ib << 16) | (ig << 8) | ir
    end

    def resolve_color(val, default)
      case val
      when nil then default
      when Integer then @colors[val] || default
      when Array
        (val[2] << 16) | (val[1] << 8) | val[0]
      else default
      end
    end

    private def wire_screen_handlers(pane)
      pane.screen.clipboard_handler = method(:handle_clipboard)
      pane.screen.glyph_measurer = method(:measure_glyph)
      pane.screen.cell_pixel_width = @cell_width if @cell_width
      pane.screen.cell_pixel_height = @cell_height if @cell_height
      pane.refresh_pty_pixel_size if @cell_width && @cell_height
    end

    private def handle_clipboard(action, text)
      case action
      when :set
        Win32.set_clipboard_text(@hwnd, text)
        nil
      when :get
        Win32.get_clipboard_text(@hwnd)
      end
    end

    private def paste_from_clipboard
      str = Win32.get_clipboard_text(@hwnd)
      return if str.nil? || str.empty?

      pane = current_tab&.active_pane
      return unless pane

      if pane.screen.bracketed_paste_mode?
        pane.write_input("\e[200~")
        pane.write_input(str)
        pane.write_input("\e[201~")
      else
        pane.write_input(str)
      end
    rescue Errno::EIO, IOError
    end

    private def copy_to_clipboard
      sr, sc, er, ec = selection_range
      return unless sr

      text = selected_text_from_buffer(sr, sc, er, ec)
      return if text.empty?

      Win32.set_clipboard_text(@hwnd, text)
    end

    private def selection_range
      pane = current_tab&.active_pane
      copy_mode = pane&.copy_mode
      return nil unless copy_mode && copy_mode.active && copy_mode.selecting?

      (sr, sc), (er, ec) = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
      [sr, sc, er, ec]
    end

    private def measure_glyph(text, family, scale, frac_n, frac_d)
      hdc = Win32::GetDC.call(@hwnd || 0)
      return 0.0 if !hdc || Win32.null_pointer?(hdc)

      font = create_multicell_font({scale: scale, frac_n: frac_n, frac_d: frac_d, family: family}, bold: false, italic: false)
      old_font = Win32::SelectObject.call(hdc, font)
      begin
        text_extent(hdc, text).first.to_f
      ensure
        Win32::SelectObject.call(hdc, old_font) if old_font
        Win32::DeleteObject.call(font) if font
        Win32::ReleaseDC.call(@hwnd || 0, hdc)
      end
    end

    private def draw_pane_content(hdc, pane, px, py, pw, ph, is_active)
      screen = pane.screen
      scrollback = screen.scrollback
      visible_start = scrollback.size - pane.scroll_offset
      pane_rows = screen.rows
      pane_cols = screen.cols

      clear_pane_background(hdc, px, py, pw, ph)

      pane_rows.times do |r|
        y = py + r * @cell_height
        src = visible_start + r
        row = if src < scrollback.size
                scrollback[src]
              elsif src - scrollback.size < screen.grid.size
                screen.grid[src - scrollback.size]
              end
        next unless row

        c = 0
        while c < pane_cols
          cell = row[c]
          unless cell
            c += 1
            next
          end
          if cell.multicell == :cont
            c += 1
            next
          end

          fg_val = cell.fg
          bg_val = cell.bg
          default_fg = @default_fg
          default_bg = @default_bg

          if cell.inverse
            fg_val, bg_val = bg_val, fg_val
            default_fg, default_bg = default_bg, default_fg
          end

          fg_color = resolve_color(fg_val, default_fg)
          bg_color = resolve_color(bg_val, default_bg)

          if cell.bold && fg_val.is_a?(Integer) && fg_val < 8
            fg_color = @colors[fg_val + 8] || fg_color
          end

          selected = is_active && cell_selected?(src, c)
          if selected
            fg_color, bg_color = bg_color, fg_color
          end

          if cell.multicell.is_a?(Hash)
            draw_multicell_text(hdc, cell, px + c * @cell_width, y, fg_color, bg_color)
            c += cell.multicell[:cols].to_i.clamp(1, pane_cols - c)
            next
          end

          run_length = 1
          run_str = cell.char || " "

          while (c + run_length) < pane_cols
            next_cell = row[c + run_length]
            break unless next_cell
            break if next_cell.multicell

            n_fg_val = next_cell.fg
            n_bg_val = next_cell.bg
            n_inverse = next_cell.inverse
            n_bold = next_cell.bold
            n_italic = next_cell.italic
            n_underline = next_cell.underline
            n_strikethrough = next_cell.strikethrough

            if n_inverse
              n_fg_val, n_bg_val = n_bg_val, n_fg_val
            end

            n_fg_color = resolve_color(n_fg_val, n_inverse ? default_bg : default_fg)
            n_bg_color = resolve_color(n_bg_val, n_inverse ? default_fg : default_bg)

            if n_bold && n_fg_val.is_a?(Integer) && n_fg_val < 8
              n_fg_color = @colors[n_fg_val + 8] || n_fg_color
            end

            n_selected = is_active && cell_selected?(src, c + run_length)
            if n_selected
              n_fg_color, n_bg_color = n_bg_color, n_fg_color
            end

            break if n_fg_color != fg_color ||
                     n_bg_color != bg_color ||
                     n_bold != cell.bold ||
                     n_italic != cell.italic ||
                     n_underline != cell.underline ||
                     n_strikethrough != cell.strikethrough

            run_str += next_cell.char || " "
            run_length += 1
          end

          Win32::SetTextColor.call(hdc, fg_color)
          Win32::SetBkColor.call(hdc, bg_color)

          cx = px + c * @cell_width
          run_font = font_for_cell(cell)
          run_x = cx
          font_runs_for_text(run_font, run_str, bold: cell.bold, italic: cell.italic).each do |text, font|
            wstr = Win32.to_wstring(text)
            wlen = wstr.bytesize / 2 - 1
            previous_font = Win32::SelectObject.call(hdc, font)
            begin
              Win32::TextOutW.call(hdc, run_x, y, Fiddle::Pointer[wstr], wlen)
            ensure
              Win32::SelectObject.call(hdc, previous_font)
            end
            run_x += text.length * @cell_width
          end
          draw_text_decorations(
            hdc,
            cx,
            y,
            run_length * @cell_width,
            fg_color,
            underline: cell.underline,
            strikethrough: cell.strikethrough
          )

          c += run_length
        end
      end

      screen.placements.each do |pl|
        blit_kitty_placement(hdc, pl, px, py, pane_rows)
      end

      # IMEインライン変換の描画
      if is_active && @marked_text && pane.scroll_offset == 0
        mx = px + screen.cursor.col * @cell_width
        my = py + screen.cursor.row * @cell_height

        marked_cells_width = @marked_text.each_char.sum { |ch| ch.ord > 0x7F ? 2 : 1 }
        marked_px_width = marked_cells_width * @cell_width

        ime_bg = (130 << 16) | (65 << 8) | 30
        ime_fg = 0xFFFFFF

        Win32::SetTextColor.call(hdc, ime_fg)
        Win32::SetBkColor.call(hdc, ime_bg)

        wstr = Win32.to_wstring(@marked_text)
        wlen = wstr.bytesize / 2 - 1
        Win32::TextOutW.call(hdc, mx, my, Fiddle::Pointer[wstr], wlen)

        # アンダーライン（下線）の描画
        rect_ptr = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
        rect_ptr[0, Win32::RECT_SIZE] = [mx, my + @cell_height - 2, mx + marked_px_width, my + @cell_height - 1].pack('l4')
        Win32::InvertRect.call(hdc, rect_ptr)
      end

      # カーソルの描画
      if pane.scroll_offset == 0 && screen.cursor.visible
        cx = screen.cursor.col
        cy = screen.cursor.row
        if cx >= 0 && cx < pane_cols && cy >= 0 && cy < pane_rows
          style = screen.cursor_style rescue 0
          cursor_rect = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)

          case style
          when 3, 4 # underline
            cursor_rect[0, Win32::RECT_SIZE] = [px + cx * @cell_width, py + cy * @cell_height + @cell_height - 2, px + (cx + 1) * @cell_width, py + (cy + 1) * @cell_height].pack('l4')
          when 5, 6 # bar
            cursor_rect[0, Win32::RECT_SIZE] = [px + cx * @cell_width, py + cy * @cell_height, px + cx * @cell_width + 2, py + (cy + 1) * @cell_height].pack('l4')
          else # block (0, 1, 2)
            cursor_rect[0, Win32::RECT_SIZE] = [px + cx * @cell_width, py + cy * @cell_height, px + (cx + 1) * @cell_width, py + (cy + 1) * @cell_height].pack('l4')
          end

          if is_active
            Win32::InvertRect.call(hdc, cursor_rect)
          else
            Win32::FrameRect.call(hdc, cursor_rect, @inactive_border_brush)
          end
        end
      end
    end

    private def clear_pane_background(hdc, px, py, pw, ph)
      fill_rect_color(hdc, px, py, px + pw, py + ph, @default_bg)
    end

    private def draw_multicell_text(hdc, cell, x, y, fg_color, bg_color)
      mc = cell.multicell
      return if mc[:sixel]

      block_w = mc[:cols].to_i * @cell_width
      block_h = mc[:rows].to_i * @cell_height
      fill_rect_color(hdc, x, y, x + block_w, y + block_h, bg_color)

      text = cell.char.to_s
      return if text.empty? || text == " "

      font = create_multicell_font(mc, bold: cell.bold, italic: cell.italic)
      old_font = Win32::SelectObject.call(hdc, font)
      old_bk_mode = Win32::SetBkMode.call(hdc, Win32::TRANSPARENT)
      begin
        text_w, text_h = text_extent(hdc, text)
        draw_x, draw_y = aligned_text_origin(
          x, y, block_w, block_h, text_w, text_h,
          halign: mc[:halign],
          valign: mc[:valign]
        )
        Win32::SetTextColor.call(hdc, fg_color)
        wstr = Win32.to_wstring(text)
        Win32::TextOutW.call(hdc, draw_x, draw_y, Fiddle::Pointer[wstr], wstr.bytesize / 2 - 1)
        draw_text_decorations(
          hdc,
          draw_x,
          draw_y,
          text_w,
          fg_color,
          underline: cell.underline,
          strikethrough: cell.strikethrough,
          height: text_h
        )
      ensure
        Win32::SetBkMode.call(hdc, old_bk_mode)
        Win32::SelectObject.call(hdc, old_font) if old_font
        Win32::DeleteObject.call(font) if font
      end
    end

    private def create_multicell_font(mc, bold:, italic:)
      scale = effective_multicell_scale(mc)
      base_height = @font_size ? @font_size.to_i : 16
      create_font(
        weight: bold ? 700 : 400,
        italic: italic,
        height: [(base_height * scale).round, 1].max,
        family: mc[:family]
      )
    end

    private def effective_multicell_scale(mc)
      scale = mc[:scale].to_f
      if mc[:frac_d].to_i > 0 && mc[:frac_n].to_i > 0
        scale *= mc[:frac_n].to_f / mc[:frac_d].to_f
      end
      scale
    end

    private def text_extent(hdc, text)
      size_ptr = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      size_ptr[0, 8] = "\x00" * 8
      wstr = Win32.to_wstring(text)
      Win32::GetTextExtentPoint32W.call(hdc, Fiddle::Pointer[wstr], wstr.bytesize / 2 - 1, size_ptr)
      [size_ptr[0, 4].unpack1('L'), size_ptr[4, 4].unpack1('L')]
    end

    private def aligned_text_origin(x, y, block_w, block_h, text_w, text_h, halign:, valign:)
      draw_x = case halign
               when 1 then x + block_w - text_w
               when 2 then x + (block_w - text_w) / 2
               else x
               end
      draw_y = case valign
               when 1 then y + block_h - text_h
               when 2 then y + (block_h - text_h) / 2
               else y
               end
      [draw_x, draw_y]
    end

    private def fill_rect_color(hdc, left, top, right, bottom, color)
      brush = Win32::CreateSolidBrush.call(color)
      begin
        rect_ptr = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
        rect_ptr[0, Win32::RECT_SIZE] = [left, top, right, bottom].pack('l4')
        Win32::FillRect.call(hdc, rect_ptr, brush)
      ensure
        Win32::DeleteObject.call(brush) if brush
      end
    end

    private def draw_text_decorations(hdc, x, y, width, color, underline:, strikethrough:, height: @cell_height)
      rects = decoration_rects(x, y, width, height: height, underline: underline, strikethrough: strikethrough)
      return if rects.empty?

      brush = Win32::CreateSolidBrush.call(color)
      begin
        rects.each do |rect|
          rect_ptr = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
          rect_ptr[0, Win32::RECT_SIZE] = rect.pack('l4')
          Win32::FillRect.call(hdc, rect_ptr, brush)
        end
      ensure
        Win32::DeleteObject.call(brush) if brush
      end
    end

    private def decoration_rects(x, y, width, height: @cell_height, underline:, strikethrough:)
      rects = []
      rects << [x, y + height - 2, x + width, y + height - 1] if underline
      rects << [x, y + (height / 2), x + width, y + (height / 2) + 1] if strikethrough
      rects
    end

    private def blit_kitty_placement(hdc, pl, px, py, pane_rows)
      return unless Win32::StretchDIBits

      img = pl[:image]
      return unless img && img[:rgba] && img[:width].to_i > 0 && img[:height].to_i > 0
      return if pl[:anchor_row] + pl[:cell_rows] <= 0
      return if pl[:anchor_row] >= pane_rows

      width = img[:width].to_i
      height = img[:height].to_i
      bitmap = rgba_to_bgra(img[:rgba], width, height)
      return unless bitmap

      bitmap_info = bitmap_info_header(width, height, bitmap.bytesize)
      x = px + pl[:anchor_col] * @cell_width + pl[:x_off].to_i
      y = py + pl[:anchor_row] * @cell_height + pl[:y_off].to_i
      draw_w = pl[:cell_cols] * @cell_width
      draw_h = pl[:cell_rows] * @cell_height

      Win32::StretchDIBits.call(
        hdc,
        x, y, draw_w, draw_h,
        0, 0, width, height,
        Fiddle::Pointer[bitmap],
        Fiddle::Pointer[bitmap_info],
        Win32::DIB_RGB_COLORS,
        Win32::SRCCOPY
      )
    end

    private def bitmap_info_header(width, height, image_size)
      [
        40, width, -height, 1, 32, Win32::BI_RGB, image_size, 0, 0, 0, 0
      ].pack('LllvvLLllLL')
    end

    private def rgba_to_bgra(rgba, width, height)
      return nil unless rgba && rgba.bytesize == width * height * 4

      bgra = String.new(capacity: rgba.bytesize, encoding: Encoding::BINARY)
      rgba.scan(/.{4}/m) do |px|
        bgra << px.getbyte(2) << px.getbyte(1) << px.getbyte(0) << px.getbyte(3)
      end
      bgra
    end

    def self.capture_format_for(path)
      File.extname(path).downcase == '.png' ? :png : :pdf
    end

    private def cell_selected?(src_row, col)
      if (tab = current_tab) && (pane = tab.active_pane)
        copy_mode = pane.copy_mode
        if copy_mode && copy_mode.active && copy_mode.selecting?
          sel_start, sel_end = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
          cm_row = src_row - pane.screen.scrollback.size
          if cm_row >= sel_start[0] && cm_row <= sel_end[0]
            if cm_row == sel_start[0] && cm_row == sel_end[0]
              return col >= sel_start[1] && col <= sel_end[1]
            elsif cm_row == sel_start[0]
              return col >= sel_start[1]
            elsif cm_row == sel_end[0]
              return col <= sel_end[1]
            else
              return true
            end
          end
        end
      end
      false
    end

    private def build_search_matcher(query)
      if @search_regex_mode
        flags = @search_case_insensitive ? Regexp::IGNORECASE : 0
        re = Regexp.new(query, flags) rescue nil
        return nil unless re
        ->(text, pos) {
          m = re.match(text, pos)
          m && [m.begin(0), m.end(0) - m.begin(0)]
        }
      elsif @search_case_insensitive
        needle = query.downcase
        len = needle.length
        ->(text, pos) {
          idx = text.downcase.index(needle, pos)
          idx && [idx, len]
        }
      else
        len = query.length
        ->(text, pos) {
          idx = text.index(query, pos)
          idx && [idx, len]
        }
      end
    end

    private def selected_text_from_buffer(sr, sc, er, ec)
      screen = current_tab.screen
      scrollback = screen.scrollback
      lines = []
      (sr..er).each do |abs_row|
        row = if abs_row < scrollback.size
                scrollback[abs_row]
              else
                screen.grid[abs_row - scrollback.size]
              end
        next unless row

        from = (abs_row == sr) ? sc : 0
        to = (abs_row == er) ? ec : @cols - 1
        chars = row[from..to].reject { |c| c.width == 0 || c.multicell == :cont }.map(&:char)
        lines << chars.join.rstrip
      end
      lines.join("\n")
    end
  end
end

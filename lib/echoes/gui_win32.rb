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
          if @hfont
            Win32::DeleteObject.call(@hfont)
            @hfont = nil
          end
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
          warn "echoes debug: WM_CHAR char_code=#{char_code}"
          unless [0x08, 0x09, 0x0D, 0x1B].include?(char_code)
            utf8_char = [char_code].pack('S').force_encoding('UTF-16LE').encode('UTF-8') rescue nil
            warn "echoes debug: WM_CHAR utf8_char=#{utf8_char.inspect}"
            if utf8_char && (tab = current_tab) && (pane = tab.active_pane)
              pane.write_input(utf8_char)
            end
          end
          0

        when Win32::WM_KEYDOWN
          vk = wparam.to_i
          warn "echoes debug: WM_KEYDOWN vk=#{vk}"
          ctrl_pressed = (Win32::GetKeyState.call(0x11) & 0x8000) != 0

          escape_sequence = nil
          case vk
          when 0x26 # VK_UP
            escape_sequence = "\e[A"
          when 0x28 # VK_DOWN
            escape_sequence = "\e[B"
          when 0x27 # VK_RIGHT
            escape_sequence = "\e[C"
          when 0x25 # VK_LEFT
            escape_sequence = "\e[D"
          when 0x24 # VK_HOME
            escape_sequence = "\e[H"
          when 0x23 # VK_END
            escape_sequence = "\e[F"
          when 0x21 # VK_PRIOR (PgUp)
            escape_sequence = "\e[5~"
          when 0x22 # VK_NEXT (PgDn)
            escape_sequence = "\e[6~"
          when 0x2E # VK_DELETE
            escape_sequence = "\e[3~"
          when 0x08 # VK_BACK
            escape_sequence = "\x7F"
          when 0x09 # VK_TAB
            escape_sequence = "\t"
          when 0x0D # VK_RETURN
            escape_sequence = "\r"
          when 0x1B # VK_ESCAPE
            escape_sequence = "\e"
          end

          if ctrl_pressed && vk >= 0x41 && vk <= 0x5A
            escape_sequence = (vk - 0x40).chr
          end

          if escape_sequence && (tab = current_tab) && (pane = tab.active_pane)
            pane.write_input(escape_sequence)
          end
          0

        when Win32::WM_SIZE
          width = lparam.to_i & 0xFFFF
          height = (lparam.to_i >> 16) & 0xFFFF

          if @cell_width && @cell_width > 0 && @cell_height && @cell_height > 0
            cols = (width / @cell_width).to_i
            rows = (height / @cell_height).to_i

            if cols > 0 && rows > 0 && (cols != @cols || rows != @rows)
              @cols = cols
              @rows = rows
              if (tab = current_tab)
                tab.resize(rows, cols)
              end
            end
          end
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
      font_height = @font_size ? @font_size.to_i : 16
      font_name = Win32.to_wstring("Consolas")
      @hfont = Win32::CreateFontW.call(
        font_height, 0, 0, 0,
        400, 0, 0, 0,
        1, 0, 0, 0,
        0x01 | 0x10,
        Fiddle::Pointer[font_name]
      )

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
          if (tab = current_tab) && (pane = tab.active_pane)
            if pane.alive?
              output = pane.read_available_output
              if output && !output.empty?
                pane.parser.feed(output)
                if @hwnd && !@hwnd.null?
                  Win32::InvalidateRect.call(@hwnd, nil, 1)
                  Win32::UpdateWindow.call(@hwnd)
                end
              end
            end
          end
        rescue => e
          warn "echoes win32: I/O polling error: #{e.message}"
        end

        # C. CPU負荷低減と Ruby の GVL 解放のため、適度にスリープ
        sleep 0.015
      end

      # Cleanup
      if @hfont
        Win32::DeleteObject.call(@hfont)
      end
      Win32::DeleteObject.call(bg_brush)
    end

    private

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

    private def draw_pane_content(hdc, pane, px, py, pw, ph, is_active)
      screen = pane.screen
      scrollback = screen.scrollback
      visible_start = scrollback.size - pane.scroll_offset
      pane_rows = screen.rows
      pane_cols = screen.cols

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
          next unless cell

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

          run_length = 1
          run_str = cell.char || " "

          while (c + run_length) < pane_cols
            next_cell = row[c + run_length]
            break unless next_cell

            n_fg_val = next_cell.fg
            n_bg_val = next_cell.bg
            n_inverse = next_cell.inverse
            n_bold = next_cell.bold

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

            break if n_fg_color != fg_color || n_bg_color != bg_color || n_bold != cell.bold

            run_str += next_cell.char || " "
            run_length += 1
          end

          Win32::SetTextColor.call(hdc, fg_color)
          Win32::SetBkColor.call(hdc, bg_color)

          cx = px + c * @cell_width
          wstr = Win32.to_wstring(run_str)
          wlen = wstr.bytesize / 2 - 1
          Win32::TextOutW.call(hdc, cx, y, Fiddle::Pointer[wstr], wlen)

          c += run_length
        end
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

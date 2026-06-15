# frozen_string_literal: true

require_relative "../gui/layout"

module Echoes
  class GUI::Backend::Win32
    private

    private def draw_text_run(hdc, x, y, text, font)
      wstr = Win32.to_wstring(text)
      wlen = wstr.bytesize / 2 - 1
      previous_font = Win32::SelectObject.call(hdc, font)
      begin
        Win32::TextOutW.call(hdc, x, y, Fiddle::Pointer[wstr], wlen)
      ensure
        Win32::SelectObject.call(hdc, previous_font)
      end
    end

    private def draw_ime_marked_text(hdc, x, y, text, height)
      run_x = x
      font_runs_for_text(@hfont, text).each do |run_text, font|
        draw_text_run(hdc, run_x, y, run_text, font)
        run_x += run_text.each_char.sum { |char| char.ord > 0x7F ? 2 : 1 } * @cell_width
      end

      marked_cells_width = text.each_char.sum { |char| char.ord > 0x7F ? 2 : 1 }
      marked_px_width = marked_cells_width * @cell_width

      # Draw underline across the entire marked text
      draw_ime_underline(hdc, x, y, marked_px_width, height)

      # Highlight target clause if we have attribute information
      if @hwnd && !Win32.null_pointer?(@hwnd)
        attrs = read_ime_composition_attributes(@hwnd)
        draw_ime_attribute_highlights(hdc, x, y, text, height, attrs) if attrs.any?
      end
    end

    private def draw_ime_attribute_highlights(hdc, x, y, text, height, attrs)
      return if attrs.empty?

      # Find target clause ranges (ATTR_TARGET_CONVERTED or ATTR_TARGET_NOTCONVERTED)
      target_ranges = []
      current_start = nil

      attrs.each_with_index do |attr, idx|
        is_target = attr == Win32::ATTR_TARGET_CONVERTED || attr == Win32::ATTR_TARGET_NOTCONVERTED

        if is_target && current_start.nil?
          current_start = idx
        elsif !is_target && current_start
          target_ranges << (current_start...idx)
          current_start = nil
        end
      end

      # Add the last range if we were in a target clause
      target_ranges << (current_start...attrs.length) if current_start

      # Highlight each target clause
      chars = text.chars.to_a
      offset = 0
      target_ranges.each do |range|
        next if range.begin >= chars.length

        end_idx = [range.end, chars.length].min
        target_text = chars[range.begin...end_idx].join

        target_px_offset = offset * @cell_width
        target_px_width = target_text.each_char.sum { |char| char.ord > 0x7F ? 2 : 1 } * @cell_width

        # Draw a subtle background highlight for the target clause
        draw_ime_target_highlight(hdc, x + target_px_offset, y, target_px_width, height)

        offset += target_text.each_char.sum { |char| char.ord > 0x7F ? 2 : 1 }
      end
    end

    private def draw_ime_target_highlight(hdc, x, y, width, height)
      rect_ptr = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
      # Subtle background highlight for target clause
      highlight_color = (0x66 << 16) | (0x66 << 8) | 0xCC

      brush = Win32::CreateSolidBrush.call(highlight_color)
      return unless brush

      begin
        old_bk_mode = Win32::SetBkMode.call(hdc, Win32::TRANSPARENT)
        rect_ptr[0, Win32::RECT_SIZE] = [x, y, x + width, y + height].pack('l4')
        Win32::FillRect.call(hdc, rect_ptr, brush)
        Win32::SetBkMode.call(hdc, old_bk_mode) if old_bk_mode
      ensure
        Win32::DeleteObject.call(brush)
      end
    end

    private def draw_ime_underline(hdc, x, y, width, height)
      # Draw a dotted underline in a distinctive color (similar to macOS IME style)
      rect_ptr = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
      # IME composition underline - typically a thin line at the bottom
      underline_y = y + height - 2
      underline_height = 2

      # Use a distinctive color for IME composition (blue/cyan tint)
      ime_underline_color = (0x33 << 16) | (0x99 << 8) | 0xFF

      brush = Win32::CreateSolidBrush.call(ime_underline_color)
      return unless brush

      begin
        rect_ptr[0, Win32::RECT_SIZE] = [x, underline_y, x + width, underline_y + underline_height].pack('l4')
        Win32::FillRect.call(hdc, rect_ptr, brush)
      ensure
        Win32::DeleteObject.call(brush)
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

    private def close_dead_tabs
      tabs = @tabs || []
      dead_indices = tabs.each_index.select { |i| !tabs[i].alive? }
      return false if dead_indices.empty?

      dead_indices.reverse_each do |index|
        tab = tabs[index]
        tab&.close rescue nil
        tabs.delete_at(index)
      end

      if tabs.empty?
        request_window_close
      else
        @active_tab = [@active_tab.to_i, tabs.size - 1].min
        invalidate_window
      end

      true
    end

    private def request_window_close
      if @hwnd && !Win32.null_pointer?(@hwnd)
        Win32::DestroyWindow.call(@hwnd)
        true
      else
        @running = false
        false
      end
    end

    private def start_native_timer
      return false unless Win32::SetTimer && @hwnd && !Win32.null_pointer?(@hwnd)

      Win32::SetTimer.call(@hwnd, TIMER_ID, TIMER_INTERVAL_MS, nil) != 0
    end

    # Block until a new window message (keystroke, paint, timer, ...) arrives
    # or `timeout_ms` elapses, then return so the loop can drain it. This
    # replaces a fixed `sleep`, which delayed keystrokes by up to the sleep
    # duration before they reached ConPTY. The timeout still bounds how long we
    # wait so ConPTY output (not a window message) is polled at a steady rate.
    private def wait_for_messages(timeout_ms)
      fn = Win32::MsgWaitForMultipleObjectsEx
      unless fn
        sleep(timeout_ms / 1000.0)
        return
      end

      fn.call(0, nil, timeout_ms, Win32::QS_ALLINPUT, Win32::MWMO_INPUTAVAILABLE)
    end

    private def stop_native_timer
      return false unless @native_timer_enabled
      return false unless Win32::KillTimer && @hwnd && !Win32.null_pointer?(@hwnd)

      @native_timer_enabled = false
      Win32::KillTimer.call(@hwnd, TIMER_ID) != 0
    end

    private def handle_timer_tick
      begin
        poll_active_pane_output
      rescue => e
        warn "echoes win32: I/O polling error: #{e.message}"
      end

      begin
        close_dead_tabs
      rescue => e
        warn "echoes win32: tab close error: #{e.message}"
      end

      @window_menu_update_counter = @window_menu_update_counter.to_i + 1
      update_window_menu_periodic
      true
    end

    private def handle_window_resize_pixels(width, height)
      return false unless @cell_width && @cell_width > 0 && @cell_height && @cell_height > 0

      tbh = tab_bar_height
      rows, cols = Echoes::GUI::Layout.rows_cols_for(width.to_f, height.to_f, @cell_width, @cell_height, tbh)
      return false if cols == @cols && rows == @rows

      @cols = cols
      @rows = rows
      current_tab&.resize(rows, cols)
      true
    end

    private def paint_window(hdc)
      old_font = Win32::SelectObject.call(hdc, @hfont)
      Win32::SetBkMode.call(hdc, Win32::OPAQUE)

      tbh = tab_bar_height
      tby = tab_bar_y
      draw_tab_bar(hdc, tbh, tby) if tbh > 0

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
          sync_window_size_from_client_rect
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
          py = gy * @cell_height + tbh  # Offset by tab bar height
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
    ensure
      Win32::SelectObject.call(hdc, old_font) if old_font
    end

    private def paint_target_size
      width, height = client_size || []
      width ||= @cell_width && @cols ? @cell_width * @cols : 0
      height ||= @cell_height && @rows ? @cell_height * @rows : 0
      [width.to_i, height.to_i]
    end

    private def with_double_buffered_paint(target_hdc, width, height)
      return yield(target_hdc) if width <= 0 || height <= 0

      mem_dc = nil
      bitmap = nil
      old_bitmap = nil
      mem_dc = create_compatible_dc(target_hdc)
      return yield(target_hdc) unless mem_dc && mem_dc != 0

      bitmap = create_compatible_bitmap(target_hdc, width, height)
      return yield(target_hdc) unless bitmap && bitmap != 0

      old_bitmap = select_gdi_object(mem_dc, bitmap)
      yield(mem_dc)
      bit_blt(target_hdc, 0, 0, width, height, mem_dc, 0, 0)
    ensure
      select_gdi_object(mem_dc, old_bitmap) if mem_dc && old_bitmap
      delete_gdi_object(bitmap) if bitmap && bitmap != 0
      delete_dc(mem_dc) if mem_dc && mem_dc != 0
    end

    private def create_compatible_dc(hdc)
      Win32::CreateCompatibleDC.call(hdc)
    end

    private def create_compatible_bitmap(hdc, width, height)
      Win32::CreateCompatibleBitmap.call(hdc, width, height)
    end

    private def select_gdi_object(hdc, object)
      Win32::SelectObject.call(hdc, object)
    end

    private def bit_blt(dst, x, y, width, height, src, sx, sy)
      Win32::BitBlt.call(dst, x, y, width, height, src, sx, sy, Win32::SRCCOPY)
    end

    private def delete_gdi_object(object)
      Win32::DeleteObject.call(object)
    end

    private def delete_dc(hdc)
      Win32::DeleteDC.call(hdc)
    end

    private def sync_window_size_from_client_rect
      width, height = client_size
      return false unless width && height

      handle_window_resize_pixels(width, height)
    end

    private def client_size
      return nil unless @hwnd

      rect = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
      rect[0, Win32::RECT_SIZE] = "\x00" * Win32::RECT_SIZE
      return nil if Win32::GetClientRect.call(@hwnd, rect) == 0

      left, top, right, bottom = rect[0, Win32::RECT_SIZE].unpack("l4")
      [right - left, bottom - top]
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
      (@gradient_brush_cache || {}).each_value { |handle| Win32::DeleteObject.call(handle) if handle }
      @gradient_brush_cache = {}
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
  end
end

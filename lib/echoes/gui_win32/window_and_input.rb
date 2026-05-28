# frozen_string_literal: true

module Echoes
  class GUI
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

    private def update_window_list
      return unless @window_menu_handle

      clear_window_menu_entries

      windows = WindowRegistry.list_windows
      windows.each_with_index do |win, i|
        break if i >= 9
        menu_id = MENU_WINDOW_BASE + i
        label = "#{i + 1}. #{win[:title]}"
        append_menu_item(@window_menu_handle, menu_id, label)
        @window_menu_dynamic_count += 1
      end

      Win32::DrawMenuBar.call(@hwnd) if Win32::DrawMenuBar
    end

    private def clear_window_menu_entries
      return unless @window_menu_handle
      return unless Win32::DeleteMenu

      (@window_menu_dynamic_count || 0).times do
        Win32::DeleteMenu.call(@window_menu_handle, 10, Win32::MF_BYPOSITION)
      end
      @window_menu_dynamic_count = 0
    end

    private def update_window_menu_periodic
      return unless @window_menu_handle
      return if (@window_menu_update_counter || 0) < 120

      current_windows = WindowRegistry.list_windows
      @window_menu_update_counter = 0
      return if current_windows.empty?

      # Rebuild window list periodically
      update_window_list
    end

    private def focus_window_by_menu(menu_id)
      window_index = menu_id - MENU_WINDOW_BASE
      windows = WindowRegistry.list_windows

      if (target = windows[window_index])
        WindowRegistry.focus_window(target[:hwnd])
      end
    end

    private def minimize_window
      return false unless @hwnd && Win32::ShowWindow
      Win32::ShowWindow.call(@hwnd, Win32::SW_MINIMIZE)
      true
    end

    private def hide_current_window
      return false unless @hwnd && Win32::ShowWindow
      Win32::ShowWindow.call(@hwnd, Win32::SW_HIDE)
      true
    end

    private def hide_other_windows
      return false unless Win32::ShowWindow
      windows = WindowRegistry.list_windows
      windows.each do |win|
        next if @hwnd && win[:hwnd] == @hwnd.to_i
        Win32::ShowWindow.call(win[:hwnd], Win32::SW_HIDE) if win[:hwnd] && win[:hwnd] != 0
      end
      true
    end

    private def show_all_windows
      return false unless Win32::ShowWindow
      windows = WindowRegistry.list_windows
      windows.each do |win|
        next unless win[:hwnd] && win[:hwnd] != 0
        Win32::ShowWindow.call(win[:hwnd], Win32::SW_SHOW)
      end
      true
    end

    private def maximize_window
      return false unless @hwnd && Win32::ShowWindow
      Win32::ShowWindow.call(@hwnd, Win32::SW_MAXIMIZE)
      true
    end

    private def toggle_fullscreen
      return false unless @hwnd && Win32::ShowWindow

      if @fullscreen_state
        restore_window
      else
        maximize_window
        @fullscreen_state = true
      end
      true
    end

    private def restore_window
      return false unless @hwnd && Win32::ShowWindow
      Win32::ShowWindow.call(@hwnd, Win32::SW_RESTORE)
      @fullscreen_state = false
      true
    end

    private def invalidate_window
      return false unless @hwnd && !Win32.null_pointer?(@hwnd)

      Win32::InvalidateRect.call(@hwnd, nil, 1)
      true
    end

    private def signed_word(value)
      value >= 0x8000 ? value - 0x10000 : value
    end

    private def handle_mouse_wheel_delta(delta)
      pane = current_tab&.active_pane
      return false unless pane
      return false if pane.screen.respond_to?(:mouse_tracking) && pane.screen.mouse_tracking != :off

      pane.scroll_accum ||= 0.0
      pane.scroll_accum += (delta.to_f / Win32::WHEEL_DELTA) * Win32::WHEEL_SCROLL_LINES
      return false if pane.scroll_accum.abs < 1.0

      lines = pane.scroll_accum.to_i
      pane.scroll_offset = (pane.scroll_offset + lines).clamp(0, pane.screen.scrollback.size)
      pane.scroll_accum -= lines
      true
    end

    private def load_terminal_cursor
      return 0 unless Win32::LoadCursorW

      @cursor_handle ||= Win32::LoadCursorW.call(0, Win32::IDC_IBEAM)
    end

    private def load_arrow_cursor
      return 0 unless Win32::LoadCursorW

      @arrow_cursor ||= Win32::LoadCursorW.call(0, Win32::IDC_ARROW)
    end

    private def load_hand_cursor
      return 0 unless Win32::LoadCursorW

      @hand_cursor ||= Win32::LoadCursorW.call(0, Win32::IDC_HAND)
    end

    private def load_crosshair_cursor
      return 0 unless Win32::LoadCursorW

      @crosshair_cursor ||= Win32::LoadCursorW.call(0, Win32::IDC_CROSS)
    end

    private def set_terminal_cursor
      if @pointer_hidden
        return false unless Win32::SetCursor

        Win32::SetCursor.call(0)
        return true
      end

      cursor = load_terminal_cursor
      return false if !cursor || Win32.null_pointer?(cursor)
      return false unless Win32::SetCursor

      Win32::SetCursor.call(cursor)
      true
    end

    private def handle_set_cursor(hwnd, msg, wparam, lparam)
      hit_test = lparam.to_i & 0xFFFF
      if hit_test != Win32::HTCLIENT
        return Win32::DefWindowProcW.call(hwnd, msg, wparam, lparam)
      end

      cursor = cursor_for_mouse_position(hwnd)
      if cursor && Win32::SetCursor
        Win32::SetCursor.call(cursor)
        1
      else
        # Fall back to the old behavior for backward compatibility
        set_terminal_cursor ? 1 : Win32::DefWindowProcW.call(hwnd, msg, wparam, lparam)
      end
    end

    private def cursor_for_mouse_position(hwnd)
      if @pointer_hidden
        return 0
      end

      # Return nil if Win32 functions are not available or we're in a test environment
      return nil unless Win32::GetCursorPos && Win32::ScreenToClient

      # Try to get the mouse position
      begin
        point = Fiddle::Pointer.malloc(Win32::POINT_SIZE, Fiddle::RUBY_FREE)
        result = Win32::GetCursorPos.call(point)
        return nil if !result || result == 0

        # Convert screen to client coordinates
        result = Win32::ScreenToClient.call(hwnd, point)
        return nil if !result || result == 0

        x_pos, y_pos = point[0, Win32::POINT_SIZE].unpack('l2')
      rescue TypeError, ArgumentError, RangeError, NoMethodError
        return nil
      end

      # Check if we're in the terminal area
      return nil unless @cell_width && @cell_width > 0 && @cell_height && @cell_height > 0

      cell_x = x_pos / @cell_width
      cell_y = y_pos / @cell_height

      tab = current_tab
      return nil unless tab

      # Find which pane we're over
      begin
        target_rect = tab.pane_tree.layout(0, 0, @cols, @rows).find do |rect|
          cell_x >= rect[:x] && cell_x < (rect[:x] + rect[:w]) &&
            cell_y >= rect[:y] && cell_y < (rect[:y] + rect[:h])
        end
      rescue
        return nil
      end

      return nil unless target_rect

      pane = target_rect[:pane]
      local_row = cell_y - target_rect[:y]
      col = cell_x - target_rect[:x]

      # Check for hyperlink cursor
      if hyperlink_at?(pane, local_row, col)
        return load_hand_cursor
      end

      # Check for copy mode cursor
      if pane.copy_mode&.active
        return load_crosshair_cursor
      end

      # Default text cursor for terminal area
      load_terminal_cursor
    end

    private def toggle_pointer_hidden
      @pointer_hidden ? show_pointer : hide_pointer
    end

    private def toggle_copy_mode
      pane = current_tab&.active_pane
      return false unless pane

      require 'echoes/copy_mode'
      if pane.copy_mode&.active
        pane.copy_mode.exit
        pane.copy_mode = nil
      else
        pane.copy_mode = CopyMode.new(pane.screen)
        pane.copy_mode.enter
      end
      true
    end

    private def select_all
      pane = current_tab&.active_pane
      return false unless pane

      require 'echoes/copy_mode'
      pane.copy_mode ||= CopyMode.new(pane.screen)
      pane.copy_mode.enter unless pane.copy_mode.active

      screen = pane.screen
      scrollback_size = screen.scrollback.size

      # Select from the very beginning of scrollback to the end of the visible grid
      pane.copy_mode.selection_start = [-scrollback_size, 0]
      pane.copy_mode.selection_end = [screen.rows - 1, screen.cols - 1]
      true
    end

    private def update_font(new_size, persist: true)
      @font_size = new_size
      Preferences.set_double(:font_size, new_size) if persist

      # Delete old fonts
      delete_font_handles

      # Create new fonts
      @hfont = create_font
      @bold_hfont = create_font(weight: 700)
      @italic_hfont = create_font(italic: true)
      @bold_italic_hfont = create_font(weight: 700, italic: true)

      # Clear font caches
      @font_cache = {}
      @fallback_font_cache = {}

      # Force remeasurement in next paint
      @cell_width = nil
      @cell_height = nil

      # Resize window to fit new font while keeping same cols/rows
      if @hwnd && !Win32.null_pointer?(@hwnd)
        # We need an HDC to measure the new font
        hdc = Win32::GetDC.call(@hwnd)
        begin
          old_f = Win32::SelectObject.call(hdc, @hfont)
          size_ptr = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
          test_str = Win32.to_wstring("A")
          Win32::GetTextExtentPoint32W.call(hdc, Fiddle::Pointer[test_str], 1, size_ptr)
          new_cw = size_ptr[0, 4].unpack1('L')
          new_ch = size_ptr[4, 4].unpack1('L')
          new_cw = 8 if new_cw == 0
          new_ch = 16 if new_ch == 0
          Win32::SelectObject.call(hdc, old_f)

          client_w = new_cw * @cols
          client_h = new_ch * @rows

          # Adjust window rect to include borders/titlebar/menu
          rect = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
          rect[0, Win32::RECT_SIZE] = [0, 0, client_w, client_h].pack('l4')
          style = Win32::GetWindowLongW.call(@hwnd, Win32::GWL_STYLE)
          ex_style = Win32::GetWindowLongW.call(@hwnd, Win32::GWL_EXSTYLE)
          has_menu = Win32::GetMenu.call(@hwnd).to_i != 0

          Win32::AdjustWindowRectEx.call(rect, style, has_menu ? 1 : 0, ex_style)
          l, t, r, b = rect[0, Win32::RECT_SIZE].unpack('l4')
          win_w = r - l
          win_h = b - t

          # Resize window maintaining top-left position
          Win32::SetWindowPos.call(@hwnd, 0, 0, 0, win_w, win_h, Win32::SWP_NOMOVE | Win32::SWP_NOZORDER)
        ensure
          Win32::ReleaseDC.call(@hwnd, hdc)
        end
      end

      invalidate_window
      true
    end

    private def copy_mode_key_for_keydown(vk, ctrl_pressed:)
      return "\e" if vk == 0x1B
      return "\x08" if vk == 0x08
      return "\r" if vk == 0x0D
      return "\t" if vk == 0x09
      return "h" if vk == 0x25
      return "j" if vk == 0x28
      return "k" if vk == 0x26
      return "l" if vk == 0x27
      return "0" if vk == 0x24
      return "$" if vk == 0x23
      return "\x02" if vk == 0x21
      return "\x06" if vk == 0x22

      if ctrl_pressed && vk >= 0x41 && vk <= 0x5A
        return (vk - 0x40).chr
      end

      nil
    end

    private def handle_copy_mode_key(pane, key)
      result = pane.copy_mode.handle_key(key)
      case result
      when :exit
        pane.copy_mode = nil
      when :yank
        copy_to_clipboard
        pane.copy_mode.exit
        pane.copy_mode = nil
      else
        pane.scroll_offset = pane.copy_mode.scroll_offset_for_cursor if pane.respond_to?(:scroll_offset=)
        pane.scroll_accum = 0.0 if pane.respond_to?(:scroll_accum=)
      end
      true
    end

    private def hide_pointer
      return false unless Win32::ShowCursor

      Win32::ShowCursor.call(0) while Win32::ShowCursor.call(0) >= 0
      @pointer_hidden = true
      @shake_detector = ShakeDetector.new
      set_terminal_cursor
      true
    end

    private def show_pointer
      return false unless Win32::ShowCursor

      Win32::ShowCursor.call(1) while Win32::ShowCursor.call(1) < 0
      @pointer_hidden = false
      @shake_detector&.reset
      set_terminal_cursor
      true
    end

    URL_REGEX = /https?:\/\/\S+/

    private def handle_left_button_down(hwnd, lparam)
      Win32::SetFocus.call(hwnd) if hwnd && !Win32.null_pointer?(hwnd)
      return false unless @cell_width && @cell_width > 0 && @cell_height && @cell_height > 0

      x_pos = lparam.to_i & 0xFFFF
      y_pos = (lparam.to_i >> 16) & 0xFFFF

      # タブバーのクリック判定
      tbh = tab_bar_height
      tby = tab_bar_y
      if tbh > 0 && y_pos >= tby && y_pos < (tby + tbh)
        tab_count = @tabs.size
        width, = client_size
        if width && width > 0 && tab_count > 0
          tab_w = width / tab_count
          index = x_pos / tab_w
          if index >= 0 && index < tab_count
            @active_tab = index
            invalidate_window
            return true
          end
        end
      end

      tab = current_tab
      return false unless tab

      cell_x = x_pos / @cell_width
      cell_y = (y_pos - tbh).to_i / @cell_height

      target_rect = tab.pane_tree.layout(0, 0, @cols, @rows).find do |rect|
        cell_x >= rect[:x] && cell_x < (rect[:x] + rect[:w]) &&
          cell_y >= rect[:y] && cell_y < (rect[:y] + rect[:h])
      end
      return false unless target_rect

      pane = target_rect[:pane]
      local_row = cell_y - target_rect[:y]
      col = cell_x - target_rect[:x]

      if pane.screen.mouse_tracking != :off
        tab.pane_tree.active_pane = pane if pane != tab.active_pane
        @mouse_button_down = :left
        send_mouse_event(tab, 0, col, local_row)
        return true
      end

      if control_pressed?
        abs_row = pane.screen.scrollback.size - pane.scroll_offset.to_i + local_row
        url = hyperlink_at(pane, abs_row, col)
        return true if url && open_url(url)
      end

      if pane != tab.active_pane
        tab.pane_tree.active_pane = pane
        invalidate_window
        return true
      end

      false
    end

    private def handle_mouse_button_down(hwnd, lparam, button, name)
      Win32::SetFocus.call(hwnd) if hwnd && !Win32.null_pointer?(hwnd)
      target = mouse_target_from_lparam(lparam)
      return false unless target

      tab, pane, row, col = target.values_at(:tab, :pane, :row, :col)
      return false if pane.screen.mouse_tracking == :off

      tab.pane_tree.active_pane = pane if pane != tab.active_pane
      @mouse_button_down = name
      send_mouse_event(tab, button, col, row)
      true
    end

    private def handle_xbutton_down(hwnd, wparam, lparam)
      case (wparam.to_i >> 16) & 0xFFFF
      when Win32::XBUTTON1
        handle_mouse_button_down(hwnd, lparam, 8, :xbutton1)
      when Win32::XBUTTON2
        handle_mouse_button_down(hwnd, lparam, 9, :xbutton2)
      else
        false
      end
    end

    private def handle_mouse_button_up(lparam)
      target = mouse_target_from_lparam(lparam)
      @mouse_button_down = nil
      return false unless target

      tab, pane, row, col = target.values_at(:tab, :pane, :row, :col)
      return false if pane.screen.mouse_tracking == :off || pane.screen.mouse_tracking == :x10

      tab.pane_tree.active_pane = pane if pane != tab.active_pane
      send_mouse_event(tab, 3, col, row, release: true)
      true
    end

    private def handle_mouse_move(lparam)
      observe_pointer_shake(lparam)
      return false unless @mouse_button_down

      target = mouse_target_from_lparam(lparam)
      return false unless target

      tab, pane, row, col = target.values_at(:tab, :pane, :row, :col)
      return false unless [:button_event, :any_event].include?(pane.screen.mouse_tracking)

      tab.pane_tree.active_pane = pane if pane != tab.active_pane
      button = drag_button_code(@mouse_button_down)
      send_mouse_event(tab, button, col, row)
      true
    end

    private def drag_button_code(button)
      case button
      when :middle then 33
      when :right then 34
      when :xbutton1 then 40
      when :xbutton2 then 41
      else 32
      end
    end

    private def observe_pointer_shake(lparam)
      return false unless @pointer_hidden

      @shake_detector ||= ShakeDetector.new
      x_pos = signed_word(lparam.to_i & 0xFFFF)
      y_pos = signed_word((lparam.to_i >> 16) & 0xFFFF)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false unless @shake_detector.observe(t, x_pos, y_pos)

      show_pointer
      true
    end

    private def mouse_target_from_lparam(lparam)
      return nil unless @cell_width && @cell_width > 0 && @cell_height && @cell_height > 0

      tab = current_tab
      return nil unless tab

      x_pos = lparam.to_i & 0xFFFF
      y_pos = (lparam.to_i >> 16) & 0xFFFF
      tbh = tab_bar_height.to_i

      cell_x = x_pos / @cell_width
      cell_y = (y_pos - tbh) / @cell_height
      target_rect = tab.pane_tree.layout(0, 0, @cols, @rows).find do |rect|
        cell_x >= rect[:x] && cell_x < (rect[:x] + rect[:w]) &&
          cell_y >= rect[:y] && cell_y < (rect[:y] + rect[:h])
      end
      return nil unless target_rect

      {
        tab: tab,
        pane: target_rect[:pane],
        row: cell_y - target_rect[:y],
        col: cell_x - target_rect[:x],
        rect: target_rect
      }
    end

    private def send_mouse_event(tab, button, col, row, release: false)
      cx = col + 1
      cy = row + 1
      if tab.screen.mouse_encoding == :sgr
        final = release ? "m" : "M"
        tab.write_input("\e[<#{button};#{cx};#{cy}#{final}")
      else
        tab.write_input("\e[M#{(button + 32).chr}#{(cx + 32).chr}#{(cy + 32).chr}")
      end
    rescue Errno::EIO, IOError
      false
    end

    private def control_pressed?
      (Win32::GetKeyState.call(Win32::VK_CONTROL) & 0x8000) != 0
    end

    private def hyperlink_at?(pane, local_row, col)
      scrollback = pane.screen.scrollback
      abs_row = scrollback.size - pane.scroll_offset + local_row
      !!hyperlink_at(pane, abs_row, col)
    end

    private def hyperlink_at(pane, abs_row, col)
      row = row_at(pane, abs_row)
      return nil unless row

      cell = row[col]
      return cell.hyperlink if cell&.respond_to?(:hyperlink) && cell.hyperlink

      text = row.map { |c| c&.char.to_s }.join
      text.scan(URL_REGEX) do |url|
        start = Regexp.last_match.begin(0)
        return url if col >= start && col < start + url.length
      end
      nil
    end

    private def row_at(pane, abs_row)
      return nil if abs_row < 0

      scrollback = pane.screen.scrollback
      if abs_row < scrollback.size
        scrollback[abs_row]
      elsif abs_row - scrollback.size < pane.screen.rows
        pane.screen.grid[abs_row - scrollback.size]
      end
    end

    private def open_url(url)
      Win32.open_url(url, hwnd: @hwnd)
    end

    private def prompt_for_file_to_edit
      Win32.open_file_dialog(
        hwnd: @hwnd,
        initial_dir: self.class.pane_local_cwd(current_tab&.active_pane) || Dir.pwd,
        title: "Open File"
      )
    end

    ABOUT_PANEL_ENV_KEYS = %w[
      LANG LC_ALL LC_CTYPE
      TERM SHELL HOME USER PWD
      PATH
      RBENV_VERSION RBENV_ROOT
      BUNDLE_GEMFILE GEM_HOME GEM_PATH
      ECHOES_EMBED ECHOES_HELPER_NO_RC
    ].freeze

    private def show_about_panel
      Win32.show_message_box(@hwnd, "About Echoes", about_panel_text)
    end

    private def about_panel_text
      lines = [
        "Ruby #{RUBY_VERSION}p#{RUBY_PATCHLEVEL} (#{RUBY_PLATFORM})",
        RbConfig.ruby,
        "",
        "Echoes #{Echoes::VERSION}"
      ]
      lines << "rubish #{Rubish::VERSION}" if defined?(Rubish::VERSION)
      lines << "rvim #{Rvim::VERSION}" if defined?(Rvim::VERSION)

      env_lines = ABOUT_PANEL_ENV_KEYS.filter_map do |key|
        value = ENV[key]
        value && !value.empty? ? "#{key}=#{value}" : nil
      end
      unless env_lines.empty?
        lines << ""
        lines << "Environment:"
        lines.concat(env_lines)
      end

      lines.join("\n")
    end

    private def handle_file_drop(hdrop)
      paste_text_to_active_pane(file_paths_for_paste(Win32.dropped_file_paths(hdrop)))
    rescue Errno::EIO, IOError
      false
    end

    private def file_paths_for_paste(paths)
      clean_paths = paths.compact.map(&:to_s).reject(&:empty?)
      return nil if clean_paths.empty?

      clean_paths.map { |path| shell_quote_path(path) }.join(" ")
    end

    private def shell_quote_path(path)
      return path if path.match?(/\A[A-Za-z]:\\[^\s&()^|<>"]+\z/)

      %("#{path.gsub('"', '""')}")
    end

    private def window_focus_changed(focused)
      @window_focused = focused
      Win32::InvalidateRect.call(@hwnd, nil, 1) if @hwnd && !Win32.null_pointer?(@hwnd)

      pane = current_tab&.active_pane
      return false unless pane&.screen&.focus_reporting?

      write_pane_input(pane, focused ? "\e[I" : "\e[O")
      true
    end

    private def write_pane_input(pane, bytes)
      pane.scroll_offset = 0 if pane.respond_to?(:scroll_offset=)
      pane.scroll_accum = 0.0 if pane.respond_to?(:scroll_accum=)
      pane.write_input(bytes)
    end

    private def update_ime_composition(hwnd, lparam)
      handled = false
      update_ime_candidate_window(hwnd)

      if (lparam.to_i & Win32::GCS_RESULTSTR) != 0
        commit_ime_composition(hwnd)
        @marked_text = nil
        @marked_reading = nil
        handled = true
      end

      return handled if (lparam.to_i & Win32::GCS_COMPSTR) == 0

      text = read_ime_composition_string(hwnd, Win32::GCS_COMPSTR)
      @marked_text = text && !text.empty? ? text : nil

      # Also read reading string (furigana) if available
      if (lparam.to_i & Win32::GCS_RESULTREADSTR) != 0
        reading = read_ime_composition_string(hwnd, Win32::GCS_RESULTREADSTR)
        @marked_reading = reading && !reading.empty? ? reading : nil
      end

      true
    end

    private def commit_ime_composition(hwnd)
      result = read_ime_composition_string(hwnd, Win32::GCS_RESULTSTR)
      return unless result && !result.empty?

      if (tab = current_tab) && (pane = tab.active_pane)
        write_pane_input(pane, result)
      end
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
      warn "IME commit encoding error: #{e.message}"
    end

    private def read_ime_composition_string(hwnd, flag)
      himc = Win32::ImmGetContext.call(hwnd)
      return nil if !himc || himc.to_i == 0

      begin
        len = Win32::ImmGetCompositionStringW.call(himc, flag, nil, 0)
        return nil if len <= 0

        buf = Fiddle::Pointer.malloc(len + 2, Fiddle::RUBY_FREE)
        buf[0, len + 2] = "\x00" * (len + 2)
        Win32::ImmGetCompositionStringW.call(himc, flag, buf, len)

        binary_data = buf.to_str(len)
        binary_data.force_encoding("BINARY")

        utf8_result = binary_data.dup.force_encoding("UTF-16LE").encode("UTF-8", invalid: :replace, undef: :replace)
        utf8_result
      ensure
        Win32::ImmReleaseContext.call(hwnd, himc)
      end
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      nil
    end

    private def read_ime_composition_attributes(hwnd)
      himc = Win32::ImmGetContext.call(hwnd)
      return [] if !himc || himc.to_i == 0

      begin
        len = Win32::ImmGetCompositionStringW.call(himc, Win32::GCS_COMPATTR, nil, 0)
        return [] if len <= 0

        buf = Fiddle::Pointer.malloc(len, Fiddle::RUBY_FREE)
        Win32::ImmGetCompositionStringW.call(himc, Win32::GCS_COMPATTR, buf, len)
        buf.to_str(len).bytes.to_a
      ensure
        Win32::ImmReleaseContext.call(hwnd, himc)
      end
    rescue
      []
    end

    private def update_ime_candidate_window(hwnd)
      return false unless Win32::ImmSetCompositionWindow && Win32::ImmSetCandidateWindow
      return false unless (origin = ime_candidate_origin)

      himc = Win32::ImmGetContext.call(hwnd)
      return false if !himc || himc.to_i == 0

      x, y = origin
      composition_form = [Win32::CFS_CANDIDATEPOS, x, y, 0, 0, 0, 0].pack('Lllllll')
      candidate_form = [0, Win32::CFS_CANDIDATEPOS, x, y, 0, 0, 0, 0].pack('LLllllll')

      begin
        composition_ok = Win32::ImmSetCompositionWindow.call(himc, Fiddle::Pointer[composition_form]) != 0
        candidate_ok = Win32::ImmSetCandidateWindow.call(himc, Fiddle::Pointer[candidate_form]) != 0
        composition_ok || candidate_ok
      ensure
        Win32::ImmReleaseContext.call(hwnd, himc)
      end
    end

    private def ime_candidate_origin
      return nil unless @cell_width && @cell_height

      tab = current_tab
      pane = tab&.active_pane
      cursor = pane&.screen&.cursor
      return nil unless tab && pane && cursor
      return nil unless tab.respond_to?(:pane_tree)

      rect = tab.pane_tree.layout(0, 0, @cols, @rows).find { |entry| entry[:pane] == pane }
      return nil unless rect

      x = (rect[:x] + cursor.col) * @cell_width
      y = (rect[:y] + cursor.row + 1) * @cell_height
      [x, y]
    end
  end
end

# frozen_string_literal: true

module Echoes
  class GUI::Backend::Win32
    private

    private def setup_menu
      return false unless Win32::CreateMenu && Win32::CreatePopupMenu && Win32::AppendMenuW && Win32::SetMenu
      return false unless @hwnd && !Win32.null_pointer?(@hwnd)

      menu = Win32::CreateMenu.call
      app_menu = Win32::CreatePopupMenu.call
      file_menu = Win32::CreatePopupMenu.call
      edit_menu = Win32::CreatePopupMenu.call
      view_menu = Win32::CreatePopupMenu.call
      window_menu = Win32::CreatePopupMenu.call
      shell_menu = Win32::CreatePopupMenu.call
      help_menu = Win32::CreatePopupMenu.call
      return false if [menu, app_menu, file_menu, edit_menu, view_menu, window_menu, shell_menu, help_menu].any? { |handle| !handle || Win32.null_pointer?(handle) }

      append_menu_item(app_menu, MENU_ABOUT, "About Echoes")
      append_menu_separator(app_menu)
      append_menu_item(app_menu, MENU_HIDE, "Hide Echoes")
      append_menu_item(app_menu, MENU_HIDE_OTHERS, "Hide Others")
      append_menu_item(app_menu, MENU_SHOW_ALL, "Show All")
      append_menu_separator(app_menu)
      append_menu_item(app_menu, MENU_EXIT, "Quit Echoes")
      append_menu_item(file_menu, MENU_NEW_TAB, "New Tab")
      append_menu_item(file_menu, MENU_OPEN_FILE, "Open File...")
      append_menu_item(edit_menu, MENU_COPY, "Copy")
      append_menu_item(edit_menu, MENU_PASTE, "Paste")
      append_menu_item(edit_menu, MENU_SELECT_ALL, "Select All")
      append_menu_item(view_menu, MENU_INCREASE_FONT, "Bigger")
      append_menu_item(view_menu, MENU_DECREASE_FONT, "Smaller")
      append_menu_item(view_menu, MENU_RESET_FONT, "Reset Font Size")
      append_menu_separator(view_menu)
      append_menu_item(view_menu, MENU_FIND, "Find")
      append_menu_item(view_menu, MENU_FIND_NEXT, "Find Next")
      append_menu_item(view_menu, MENU_FIND_PREVIOUS, "Find Previous")
      append_menu_item(view_menu, MENU_TOGGLE_COPY_MODE, "Toggle Copy Mode")
      append_menu_separator(view_menu)
      build_profiles_submenu(view_menu)
      append_menu_separator(view_menu)
      append_menu_item(view_menu, MENU_TOGGLE_POINTER, "Hide Mouse Pointer")
      append_menu_item(window_menu, MENU_WINDOW_MINIMIZE, "Minimize")
      append_menu_item(window_menu, MENU_WINDOW_MAXIMIZE, "Maximize")
      append_menu_item(window_menu, MENU_WINDOW_FULLSCREEN, "Enter Full Screen")
      append_menu_separator(window_menu)
      append_menu_item(window_menu, MENU_PREVIOUS_TAB, "Show Previous Tab")
      append_menu_item(window_menu, MENU_NEXT_TAB, "Show Next Tab")
      append_menu_separator(window_menu)
      append_menu_item(window_menu, MENU_PREVIOUS_PANE, "Select Previous Pane")
      append_menu_item(window_menu, MENU_NEXT_PANE, "Select Next Pane")
      append_menu_separator(window_menu)
      append_menu_item(window_menu, MENU_BRING_ALL_TO_FRONT, "Bring All to Front")
      append_menu_separator(window_menu)
      @window_menu_handle = window_menu
      @window_menu_dynamic_count = 0
      update_window_list
      append_menu_item(shell_menu, MENU_CLOSE_TAB, "Close Tab")
      append_menu_separator(shell_menu)
      append_menu_item(shell_menu, MENU_SPLIT_RIGHT, "Split Right")
      append_menu_item(shell_menu, MENU_SPLIT_DOWN, "Split Down")
      append_menu_item(shell_menu, MENU_CLOSE_PANE, "Close Pane")
      append_menu_item(help_menu, MENU_ABOUT, "About Echoes")
      append_menu_popup(menu, app_menu, "Echoes")
      append_menu_popup(menu, file_menu, "File")
      append_menu_popup(menu, edit_menu, "Edit")
      append_menu_popup(menu, view_menu, "View")
      append_menu_popup(menu, window_menu, "Window")
      append_menu_popup(menu, shell_menu, "Shell")
      append_menu_popup(menu, help_menu, "Help")

      return false if Win32::SetMenu.call(@hwnd, menu) == 0

      Win32::DrawMenuBar.call(@hwnd) if Win32::DrawMenuBar
      setup_accelerators
      true
    end

    private def setup_accelerators
      return false unless Win32::CreateAcceleratorTableW

      table = accelerator_table_bytes(ACCELERATORS)
      handle = Win32::CreateAcceleratorTableW.call(Fiddle::Pointer[table], ACCELERATORS.size)
      return false if !handle || Win32.null_pointer?(handle)

      @accelerators = handle
      true
    end

    private def accelerator_table_bytes(entries)
      entries.each_with_index.map do |(flags, key, command_id), index|
        flags |= 0x80 if index == entries.size - 1
        [flags, key, command_id].pack("Cxvv")
      end.join
    end

    private def translate_accelerator(msg_struct)
      return false unless @hwnd && @accelerators && Win32::TranslateAcceleratorW

      Win32::TranslateAcceleratorW.call(@hwnd, @accelerators, msg_struct) != 0
    end

    private def destroy_accelerators
      return unless @accelerators && Win32::DestroyAcceleratorTable

      Win32::DestroyAcceleratorTable.call(@accelerators)
      @accelerators = nil
    end

    private def append_menu_item(menu, id, label)
      Win32::AppendMenuW.call(menu, Win32::MF_STRING, id, Fiddle::Pointer[Win32.to_wstring(label)])
    end

    private def append_menu_separator(menu)
      Win32::AppendMenuW.call(menu, Win32::MF_SEPARATOR, 0, nil)
    end

    private def append_menu_popup(menu, popup, label)
      Win32::AppendMenuW.call(menu, Win32::MF_POPUP, popup.to_i, Fiddle::Pointer[Win32.to_wstring(label)])
    end

    private def dispatch_menu_command(command_id)
      case command_id
      when MENU_NEW_TAB
        create_tab
        invalidate_window
        true
      when MENU_OPEN_FILE
        if (path = prompt_for_file_to_edit)
          create_tab(editor_file: path)
          invalidate_window
        end
        true
      when MENU_ABOUT
        show_about_panel
        true
      when MENU_HIDE
        hide_current_window
        true
      when MENU_HIDE_OTHERS
        hide_other_windows
        true
      when MENU_SHOW_ALL
        show_all_windows
        true
      when MENU_TOGGLE_POINTER
        toggle_pointer_hidden
        true
      when MENU_COPY
        copy_to_clipboard
        true
      when MENU_PASTE
        paste_from_clipboard
        invalidate_window
        true
      when MENU_SELECT_ALL
        select_all
        invalidate_window
        true
      when MENU_INCREASE_FONT
        update_font(@font_size + 1.0)
        true
      when MENU_DECREASE_FONT
        update_font(@font_size - 1.0) if @font_size > 4.0
        true
      when MENU_RESET_FONT
        Preferences.delete(:font_size)
        update_font(Echoes.config.font_size, persist: false)
        true
      when MENU_CLOSE_TAB
        close_tab(@active_tab)
        invalidate_window
        true
      when MENU_SPLIT_RIGHT
        split_active_pane(:vertical)
        invalidate_window
        true
      when MENU_SPLIT_DOWN
        split_active_pane(:horizontal)
        invalidate_window
        true
      when MENU_CLOSE_PANE
        close_active_pane
        invalidate_window
        true
      when MENU_FIND
        toggle_search
        invalidate_window
        true
      when MENU_FIND_NEXT
        search_next
        invalidate_window
        true
      when MENU_FIND_PREVIOUS
        search_prev
        invalidate_window
        true
      when MENU_TOGGLE_COPY_MODE
        toggle_copy_mode
        invalidate_window
        true
      when (MENU_PROFILE_BASE...(MENU_PROFILE_BASE + 100))
        apply_profile_by_menu(command_id)
        invalidate_window
        true
      when MENU_WINDOW_MINIMIZE
        minimize_window
        true
      when MENU_WINDOW_MAXIMIZE
        maximize_window
        true
      when MENU_WINDOW_FULLSCREEN
        toggle_fullscreen
        true
      when MENU_PREVIOUS_TAB
        select_previous_tab
        invalidate_window
        true
      when MENU_NEXT_TAB
        select_next_tab
        invalidate_window
        true
      when MENU_PREVIOUS_PANE
        current_tab&.prev_pane
        invalidate_window
        true
      when MENU_NEXT_PANE
        current_tab&.next_pane
        invalidate_window
        true
      when MENU_BRING_ALL_TO_FRONT
        show_all_windows
        true
      when (MENU_WINDOW_BASE...(MENU_WINDOW_BASE + 9))
        focus_window_by_menu(command_id)
        true
      when MENU_EXIT
        request_window_close
        true
      else
        false
      end
    end

    private def build_profiles_submenu(view_menu)
      return false unless Win32::CreatePopupMenu

      profiles = Echoes.config.all_profiles
      return false if profiles.empty?

      profile_menu = Win32::CreatePopupMenu.call
      return false if !profile_menu || Win32.null_pointer?(profile_menu)

      profiles.each_key.with_index do |name, index|
        break if index >= 100

        append_menu_item(profile_menu, MENU_PROFILE_BASE + index, name)
      end
      append_menu_popup(view_menu, profile_menu, "Profile")
      true
    end

    private def apply_profile_by_menu(command_id)
      index = command_id - MENU_PROFILE_BASE
      name = Echoes.config.all_profiles.keys[index]
      apply_profile(name)
    end

    private def apply_profile(name)
      profile = Echoes.config.all_profiles[name.to_s]
      return false unless profile

      @active_profile = profile
      @colors = build_color_table
      @default_fg = make_color(*@active_profile.foreground)
      @default_bg = make_color(*@active_profile.background)
      @tabs&.each do |tab|
        panes = tab.respond_to?(:panes) ? tab.panes : [tab.active_pane].compact
        panes.each { |pane| pane.screen.mark_all_dirty if pane.screen.respond_to?(:mark_all_dirty) }
      end
      true
    end

    private def handle_completion_tab(pane)
      return false unless pane.respond_to?(:embedded?) && pane.embedded?
      return false unless pane.respond_to?(:embedded_shell)
      return false if pane.embedded_shell.running?

      req = pane.completion_request
      return false unless req && req[:candidates].size > 1

      show_completion_popup(pane, req)
    end

    private def show_completion_popup(pane, req)
      return false unless Win32::CreatePopupMenu && Win32::TrackPopupMenu

      candidates = req[:candidates]
      return false if candidates.nil? || candidates.empty?

      menu = Win32::CreatePopupMenu.call
      return false if !menu || Win32.null_pointer?(menu)

      candidates.each_with_index do |candidate, index|
        break if index >= 100

        append_menu_item(menu, MENU_COMPLETION_BASE + index, candidate)
      end

      @completion_state = {pane: pane, word_start: req[:word_start], candidates: candidates}
      x, y = client_to_screen(*completion_anchor_point(pane))
      command_id = Win32::TrackPopupMenu.call(
        menu,
        Win32::TPM_RETURNCMD | Win32::TPM_RIGHTBUTTON,
        x,
        y,
        0,
        @hwnd || 0,
        nil
      )
      command_id.to_i > 0 ? completion_picked_by_command(command_id.to_i) : false
    ensure
      @completion_state = nil unless command_id.to_i > 0
      Win32::DestroyMenu.call(menu) if defined?(menu) && menu && Win32::DestroyMenu
    end

    private def completion_anchor_point(pane)
      return [0, 0] unless @cell_width && @cell_height

      tab = current_tab
      return [0, 0] unless tab&.respond_to?(:pane_tree)

      rect = tab.pane_tree.layout(0, 0, @cols, @rows).find { |entry| entry[:pane] == pane }
      cursor = pane&.screen&.cursor
      return [0, 0] unless rect && cursor

      [
        ((rect[:x] + cursor.col) * @cell_width).to_i,
        ((rect[:y] + cursor.row + 1) * @cell_height).to_i
      ]
    end

    private def client_to_screen(x, y)
      return [x.to_i, y.to_i] unless Win32::ClientToScreen && @hwnd && !Win32.null_pointer?(@hwnd)

      point = Fiddle::Pointer.malloc(Win32::POINT_SIZE, Fiddle::RUBY_FREE)
      point[0, Win32::POINT_SIZE] = [x.to_i, y.to_i].pack('l2')
      return [x.to_i, y.to_i] if Win32::ClientToScreen.call(@hwnd, point) == 0

      point[0, Win32::POINT_SIZE].unpack('l2')
    end

    private def completion_picked_by_command(command_id)
      state = @completion_state
      return false unless state

      index = command_id - MENU_COMPLETION_BASE
      candidate = state[:candidates][index]
      return false unless candidate

      state[:pane].apply_completion(word_start: state[:word_start], completion: candidate)
      true
    ensure
      @completion_state = nil
    end

    private def close_tab(index)
      return false if @tabs.nil? || @tabs.empty?

      index = [[index.to_i, 0].max, @tabs.size - 1].min
      tab = @tabs.delete_at(index)
      tab&.close
      if @tabs.empty?
        create_tab
      else
        @active_tab = [index, @tabs.size - 1].min
      end
      true
    end

    private def split_active_pane(direction)
      tab = current_tab
      return false unless tab

      pane = direction == :horizontal ? tab.split_horizontal : tab.split_vertical
      wire_screen_handlers(pane)
      true
    end

    private def close_active_pane
      tab = current_tab
      return false unless tab

      if tab.pane_tree.single_pane?
        close_tab(@active_tab)
      else
        tab.close_active_pane
      end
      true
    end

    private def select_previous_tab
      return false if @tabs.nil? || @tabs.empty?

      @active_tab = (@active_tab - 1) % @tabs.size
      true
    end

    private def select_next_tab
      return false if @tabs.nil? || @tabs.empty?

      @active_tab = (@active_tab + 1) % @tabs.size
      true
    end
  end
end

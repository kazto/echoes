# frozen_string_literal: true

require_relative 'win32'
require_relative 'window_registry'
require_relative 'tab'
require_relative 'pane'
require_relative 'preferences'
require_relative 'profile'
require_relative 'configuration'
require_relative 'shake_detector'
require 'json'
require 'rbconfig'
require 'socket'
require 'uri'
require 'zlib'

module Echoes
  class GUI
    MENU_NEW_TAB = 10_001
    MENU_OPEN_FILE = 10_002
    MENU_EXIT = 10_003
    MENU_ABOUT = 10_004
    MENU_TOGGLE_POINTER = 10_005
    MENU_COPY = 10_006
    MENU_PASTE = 10_007
    MENU_CLOSE_TAB = 10_008
    MENU_SPLIT_RIGHT = 10_009
    MENU_WINDOW_MINIMIZE = 10_010
    MENU_WINDOW_MAXIMIZE = 10_011
    MENU_WINDOW_FULLSCREEN = 10_012
    MENU_SPLIT_DOWN = 10_013
    MENU_CLOSE_PANE = 10_014
    MENU_PREVIOUS_TAB = 10_015
    MENU_NEXT_TAB = 10_016
    MENU_PREVIOUS_PANE = 10_017
    MENU_NEXT_PANE = 10_018
    MENU_FIND = 10_019
    MENU_FIND_NEXT = 10_020
    MENU_FIND_PREVIOUS = 10_021
    MENU_TOGGLE_COPY_MODE = 10_022
    MENU_HIDE = 10_023
    MENU_HIDE_OTHERS = 10_024
    MENU_SHOW_ALL = 10_025
    MENU_WINDOW_BASE = 10_100
    MENU_PROFILE_BASE = 10_200
    MENU_COMPLETION_BASE = 10_400
    TIMER_ID = 1
    TIMER_INTERVAL_MS = 15

    ACCELERATORS = [
      [Win32::FCONTROL | Win32::FVIRTKEY, 0x54, MENU_NEW_TAB],   # Ctrl+T
      [Win32::FCONTROL | Win32::FVIRTKEY, 0x4F, MENU_OPEN_FILE], # Ctrl+O
      [Win32::FCONTROL | Win32::FVIRTKEY, 0x46, MENU_FIND],      # Ctrl+F
      [Win32::FVIRTKEY, 0x72, MENU_FIND_NEXT],                   # F3
      [Win32::FSHIFT | Win32::FVIRTKEY, 0x72, MENU_FIND_PREVIOUS], # Shift+F3
      [Win32::FCONTROL | Win32::FVIRTKEY, 0x57, MENU_CLOSE_TAB], # Ctrl+W
      [Win32::FCONTROL | Win32::FSHIFT | Win32::FVIRTKEY, 0x44, MENU_SPLIT_DOWN], # Ctrl+Shift+D
      [Win32::FCONTROL | Win32::FSHIFT | Win32::FVIRTKEY, 0x57, MENU_CLOSE_PANE], # Ctrl+Shift+W
      [Win32::FCONTROL | Win32::FSHIFT | Win32::FVIRTKEY, 0x50, MENU_TOGGLE_POINTER], # Ctrl+Shift+P
      [Win32::FALT | Win32::FVIRTKEY, 0x73, MENU_EXIT],          # Alt+F4
      [Win32::FVIRTKEY, 0x70, MENU_ABOUT]                        # F1
    ].freeze

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
      @rows = positive_env_integer('ECHOES_ROWS') || rows
      @cols = positive_env_integer('ECHOES_COLS') || cols
      @font_size = font_size || Preferences.fetch_double(:font_size, default: Echoes.config.font_size)
      @window_rect_autosave = !window_rect_env?(ENV)
      @command = command_from_env || command
      @initial_window_rect = initial_window_rect_from_env
      @tabs = []
      @active_tab = 0
      @font_cache = {}
      @hwnd = nil
      @cursor_handle = nil
      @arrow_cursor = nil
      @hand_cursor = nil
      @crosshair_cursor = nil
      @accelerators = nil
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
      @window_focused = true
      @mouse_button_down = nil
      @pointer_hidden = false
      @shake_detector = nil
      @marked_text = nil # IME inline composition string
      @marked_reading = nil # IME reading string (furigana)
      @fullscreen_state = false
      @window_menu_handle = nil
      @window_menu_update_counter = 0
      @window_menu_dynamic_count = 0
      @search_mode = false
      @search_query = +""
      @search_matches = []
      @search_index = -1
      @search_regex_mode = false
      @search_case_insensitive = false

      # カラーテーマの初期化
      @active_profile = Echoes.config.active_profile rescue nil
      @colors = build_color_table
      @default_fg = make_color(*default_fg_rgb)
      @default_bg = make_color(*default_bg_rgb)
      @search_match_bg = make_color(0.45, 0.38, 0.0)
      @search_current_bg = make_color(0.1, 0.45, 0.55)

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
        when Win32::WM_CLOSE
          request_window_close
          0

        when Win32::WM_DESTROY
          @running = false
          save_window_rect
          WindowRegistry.unregister_window(Process.pid)
          close_tabs
          delete_font_handles
          if @active_border_brush
            Win32::DeleteObject.call(@active_border_brush)
          end
          if @inactive_border_brush
            Win32::DeleteObject.call(@inactive_border_brush)
          end
          WindowRegistry.cleanup
          Win32::PostQuitMessage.call(0)
          0

        when Win32::WM_ERASEBKGND
          1

        when Win32::WM_SETCURSOR
          handle_set_cursor(hwnd, msg, wparam, lparam)

        when Win32::WM_COMMAND
          dispatch_menu_command(wparam.to_i & 0xFFFF)
          0

        when Win32::WM_TIMER
          handle_timer_tick if wparam.to_i == TIMER_ID
          0

        when Win32::WM_PAINT
          ps = Fiddle::Pointer.malloc(Win32::PAINTSTRUCT_SIZE, Fiddle::RUBY_FREE)
          ps[0, Win32::PAINTSTRUCT_SIZE] = "\x00" * Win32::PAINTSTRUCT_SIZE
          hdc = Win32::BeginPaint.call(hwnd, ps)
          begin
            paint_width, paint_height = paint_target_size
            with_double_buffered_paint(hdc, paint_width, paint_height) do |paint_hdc|
              paint_window(paint_hdc)
            end
          ensure
            Win32::EndPaint.call(hwnd, ps)
          end
          0

        when Win32::WM_SETFOCUS
          window_focus_changed(true)
          0

        when Win32::WM_KILLFOCUS
          window_focus_changed(false)
          0

        when Win32::WM_LBUTTONDOWN
          handle_left_button_down(hwnd, lparam.to_i)
          0

        when Win32::WM_LBUTTONUP
          handle_mouse_button_up(lparam.to_i)
          0

        when Win32::WM_RBUTTONDOWN
          handle_mouse_button_down(hwnd, lparam.to_i, 2, :right)
          0

        when Win32::WM_RBUTTONUP
          handle_mouse_button_up(lparam.to_i)
          0

        when Win32::WM_MBUTTONDOWN
          handle_mouse_button_down(hwnd, lparam.to_i, 1, :middle)
          0

        when Win32::WM_MBUTTONUP
          handle_mouse_button_up(lparam.to_i)
          0

        when Win32::WM_XBUTTONDOWN
          handle_xbutton_down(hwnd, wparam.to_i, lparam.to_i)
          0

        when Win32::WM_XBUTTONUP
          handle_mouse_button_up(lparam.to_i)
          0

        when Win32::WM_MOUSEMOVE
          handle_mouse_move(lparam.to_i)
          0

        when Win32::WM_MOUSEWHEEL
          delta = signed_word((wparam.to_i >> 16) & 0xFFFF)
          if handle_mouse_wheel_delta(delta)
            Win32::InvalidateRect.call(hwnd, nil, 1)
          end
          0

        when Win32::WM_DROPFILES
          handle_file_drop(wparam)
          0

        when Win32::WM_IME_STARTCOMPOSITION
          @marked_text = ""
          update_ime_candidate_window(hwnd)
          0

        when Win32::WM_IME_ENDCOMPOSITION
          @marked_text = nil
          @marked_reading = nil
          Win32::InvalidateRect.call(hwnd, nil, 1)
          0

        when Win32::WM_IME_COMPOSITION
          if update_ime_composition(hwnd, lparam.to_i)
            Win32::InvalidateRect.call(hwnd, nil, 1)
          end
          0

        when Win32::WM_CHAR
          char_code = wparam.to_i
          unless [0x08, 0x09, 0x0D, 0x1B].include?(char_code)
            utf8_char = [char_code].pack('S').force_encoding('UTF-16LE').encode('UTF-8') rescue nil
            if utf8_char && (pane = current_tab&.active_pane)&.copy_mode&.active
              handle_copy_mode_key(pane, utf8_char)
              Win32::InvalidateRect.call(hwnd, nil, 1)
              return 0
            end
            if utf8_char && @search_mode
              handle_search_char(utf8_char)
              Win32::InvalidateRect.call(hwnd, nil, 1)
              return 0
            end
            if utf8_char && (tab = current_tab) && (pane = tab.active_pane)
              write_pane_input(pane, utf8_char)
            end
          end
          0

        when Win32::WM_KEYDOWN
          vk = wparam.to_i
          ctrl_pressed = (Win32::GetKeyState.call(0x11) & 0x8000) != 0
          shift_pressed = (Win32::GetKeyState.call(0x10) & 0x8000) != 0

          if (pane = current_tab&.active_pane)&.copy_mode&.active
            if (key = copy_mode_key_for_keydown(vk, ctrl_pressed: ctrl_pressed))
              handle_copy_mode_key(pane, key)
              Win32::InvalidateRect.call(hwnd, nil, 1)
            end
            return 0
          end

          if @search_mode && handle_search_keydown(vk, ctrl_pressed: ctrl_pressed, shift_pressed: shift_pressed)
            Win32::InvalidateRect.call(hwnd, nil, 1)
            return 0
          end

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
            if vk == 0x09 && !ctrl_pressed && !shift_pressed && (pane = current_tab&.active_pane) &&
               handle_completion_tab(pane)
              handled_key = true
              Win32::InvalidateRect.call(hwnd, nil, 1)
            end
            escape_sequence = windows_key_sequence(vk, ctrl_pressed: ctrl_pressed) unless handled_key
            if escape_sequence && (tab = current_tab) && (pane = tab.active_pane)
              write_pane_input(pane, escape_sequence)
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
      cursor = load_terminal_cursor
      bg_brush = 0

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
        @initial_window_rect[:x], @initial_window_rect[:y],
        @initial_window_rect[:w], @initial_window_rect[:h],
        0, 0, 0, 0                             # hWndParent, hMenu, hInstance, lpParam
      )

      raise "echoes win32: failed to create window" if @hwnd.null?

      setup_menu
      Win32::DragAcceptFiles.call(@hwnd, 1) if Win32::DragAcceptFiles
      Win32::ShowWindow.call(@hwnd, Win32::SW_SHOWNORMAL)
      Win32::UpdateWindow.call(@hwnd)
      Win32::SetFocus.call(@hwnd)

      # Register window in the registry after it's created
      WindowRegistry.register_window(@hwnd, Echoes.config.window_title)
      @window_menu_update_counter = 0
      @native_timer_enabled = start_native_timer

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
          next if translate_accelerator(msg_struct)

          Win32::TranslateMessage.call(msg_struct)
          Win32::DispatchMessageW.call(msg_struct)
        end

        break unless @running

        handle_timer_tick unless @native_timer_enabled

        # CPU負荷低減と Ruby の GVL 解放のため、適度にスリープ
        sleep 0.015
      end

      # Cleanup
      stop_native_timer
      save_window_rect
      close_tabs
      delete_font_handles
      destroy_accelerators
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

    private def copy_mode_key_for_keydown(vk, ctrl_pressed:)
      return "\e" if vk == 0x1B
      return "\x08" if vk == 0x08
      return "\r" if vk == 0x0D
      return "\t" if vk == 0x09

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

      tab = current_tab
      return false unless tab

      x_pos = lparam.to_i & 0xFFFF
      y_pos = (lparam.to_i >> 16) & 0xFFFF
      cell_x = x_pos / @cell_width
      cell_y = y_pos / @cell_height

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
        Win32::InvalidateRect.call(hwnd, nil, 1)
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
      cell_x = x_pos / @cell_width
      cell_y = y_pos / @cell_height
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

      @window_menu_update_counter = @window_menu_update_counter.to_i + 1
      update_window_menu_periodic
      true
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

    private def paint_window(hdc)
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

    private def wire_screen_handlers(pane)
      pane.screen.clipboard_handler = method(:handle_clipboard)
      pane.screen.glyph_measurer = method(:measure_glyph)
      pane.screen.capture_handler = ->(path) { capture_pane_to_png(pane, path) }
      pane.screen.display_info_handler = -> { display_info_json(pane) }
      pane.screen.open_window_handler = ->(args) { open_window_from_osc(pane, args) }
      pane.screen.notification_handler = ->(title, message) { post_notification(pane, title, message) }
      pane.screen.cell_pixel_width = @cell_width if @cell_width
      pane.screen.cell_pixel_height = @cell_height if @cell_height
      pane.refresh_pty_pixel_size if @cell_width && @cell_height
    end

    private def positive_env_integer(key, env = ENV)
      value = env[key]
      return nil if value.nil? || value.empty?

      integer = Integer(value, exception: false)
      integer if integer && integer.positive?
    end

    private def command_from_env(env = ENV)
      encoded = env['ECHOES_OPEN_WINDOW_PROGRAM']
      return nil if encoded.nil? || encoded.empty?

      decoded = encoded.delete("\r\n\t ").unpack1('m0')
      argv = JSON.parse(decoded)
      argv if argv.is_a?(Array) && !argv.empty?
    rescue StandardError
      nil
    end

    private def initial_window_rect_from_env(env = ENV)
      return explicit_window_rect_from_env(env) if window_rect_env?(env)

      saved_window_rect || default_window_rect
    end

    private def window_rect_env?(env = ENV)
      %w[ECHOES_WINDOW_X ECHOES_WINDOW_Y ECHOES_WINDOW_W ECHOES_WINDOW_H].any? { |key| env.key?(key) }
    end

    private def explicit_window_rect_from_env(env = ENV)
      {
        x: Integer(env.fetch('ECHOES_WINDOW_X', 100), exception: false) || 100,
        y: Integer(env.fetch('ECHOES_WINDOW_Y', 100), exception: false) || 100,
        w: positive_env_integer('ECHOES_WINDOW_W', env) || 800,
        h: positive_env_integer('ECHOES_WINDOW_H', env) || 600
      }
    end

    private def default_window_rect
      {x: 100, y: 100, w: 800, h: 600}
    end

    WINDOW_RECT_PREFERENCE_KEYS = {
      x: :window_x,
      y: :window_y,
      w: :window_w,
      h: :window_h
    }.freeze

    private def saved_window_rect
      defaults = default_window_rect
      rect = WINDOW_RECT_PREFERENCE_KEYS.transform_values do |key|
        Preferences.fetch_double(key, default: nil)
      end
      return nil unless rect.values.all?

      normalized = rect.transform_values(&:to_i)
      return nil unless normalized[:w].positive? && normalized[:h].positive?

      defaults.merge(normalized)
    end

    private def save_window_rect
      return false unless @window_rect_autosave
      return false unless (rect = current_window_rect)

      WINDOW_RECT_PREFERENCE_KEYS.each do |field, key|
        Preferences.set_double(key, rect[field])
      end
      true
    end

    private def current_window_rect
      return nil unless Win32::GetWindowRect && @hwnd && !Win32.null_pointer?(@hwnd)

      rect = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
      rect[0, Win32::RECT_SIZE] = "\x00" * Win32::RECT_SIZE
      return nil if Win32::GetWindowRect.call(@hwnd, rect) == 0

      left, top, right, bottom = rect[0, Win32::RECT_SIZE].unpack('l4')
      width = right - left
      height = bottom - top
      return nil if width <= 0 || height <= 0

      {x: left, y: top, w: width, h: height}
    end

    private def post_notification(pane, title, message)
      effective_title = (title && !title.empty? && title) || pane&.title || Echoes.config.window_title
      text = message.to_s.empty? ? effective_title.to_s : "#{effective_title} - #{message}"
      set_window_title(text)
    rescue StandardError => e
      warn "echoes notification: #{e.class}: #{e.message}"
    end

    private def display_info_json(_pane)
      current_handle = Win32.monitor_from_window(@hwnd)
      entries = Win32.display_monitors.each_with_index.map do |monitor, index|
        {
          "index" => index,
          "x" => monitor[:x],
          "y" => monitor[:y],
          "w" => monitor[:w],
          "h" => monitor[:h],
          "work_x" => monitor[:work_x],
          "work_y" => monitor[:work_y],
          "work_w" => monitor[:work_w],
          "work_h" => monitor[:work_h],
          "dpi_x" => monitor[:dpi_x] || Win32::DEFAULT_DPI.to_i,
          "dpi_y" => monitor[:dpi_y] || Win32::DEFAULT_DPI.to_i,
          "backing_scale_factor" => monitor[:scale] || 1.0,
          "primary" => !!monitor[:primary],
          "current" => current_handle && monitor[:handle] == current_handle
        }
      end
      JSON.generate(entries)
    rescue StandardError => e
      warn "echoes display-info: #{e.class}: #{e.message}"
      "[]"
    end

    private def open_window_from_osc(_pane, args_str)
      params = parse_open_window_args(args_str)
      program_b64 = params['program']
      return false if program_b64.nil? || program_b64.empty?

      argv = decode_open_window_argv(program_b64)
      return false unless argv

      open_external_window(
        argv: argv,
        display_index: (params['display'] || '0').to_i,
        fullscreen: params['fullscreen'] == 'yes'
      )
    rescue StandardError => e
      warn "echoes open-window: #{e.class}: #{e.message}"
      false
    end

    private def parse_open_window_args(args_str)
      params = {}
      args_str.to_s.split(':').each do |pair|
        key, value = pair.split('=', 2)
        next if key.nil? || key.empty? || value.nil?

        params[key] = value
      end
      params
    end

    private def decode_open_window_argv(program_b64)
      json = program_b64.delete("\r\n\t ").unpack1('m0')
      argv = JSON.parse(json)
      return nil unless argv.is_a?(Array) && !argv.empty?

      argv.map(&:to_s)
    rescue StandardError
      nil
    end

    private def open_external_window(argv:, display_index:, fullscreen:)
      monitor = Win32.display_monitors[display_index]
      monitor ||= Win32.display_monitors.first
      return false unless monitor

      rect = fullscreen ? monitor_rect(monitor) : monitor_work_rect(monitor)
      cell_w = @cell_width || 10
      cell_h = @cell_height || 20
      rows = [(rect[:h] / cell_h).floor, 5].max
      cols = [(rect[:w] / cell_w).floor, 20].max
      env = child_env_for_open_window.merge(
        'ECHOES_OPEN_WINDOW_PROGRAM' => [JSON.generate(argv)].pack('m0'),
        'ECHOES_ROWS' => rows.to_s,
        'ECHOES_COLS' => cols.to_s,
        'ECHOES_WINDOW_X' => rect[:x].to_i.to_s,
        'ECHOES_WINDOW_Y' => rect[:y].to_i.to_s,
        'ECHOES_WINDOW_W' => rect[:w].to_i.to_s,
        'ECHOES_WINDOW_H' => rect[:h].to_i.to_s
      )
      pid = spawn_external_echoes(env)
      Process.detach(pid) if pid
      !!pid
    end

    private def monitor_rect(monitor)
      {x: monitor[:x], y: monitor[:y], w: monitor[:w], h: monitor[:h]}
    end

    private def monitor_work_rect(monitor)
      {x: monitor[:work_x], y: monitor[:work_y], w: monitor[:work_w], h: monitor[:work_h]}
    end

    private def child_env_for_open_window
      env = ENV.to_h
      env['PATH'] = merge_windows_path(env['PATH'])
      env['USERPROFILE'] ||= Dir.home
      env['TERM'] ||= Echoes.config.term
      env
    end

    private def merge_windows_path(parent_path)
      defaults = [
        ENV['SystemRoot'] && File.join(ENV['SystemRoot'], 'System32'),
        ENV['SystemRoot']
      ].compact
      seen = {}
      (parent_path.to_s.split(';') + defaults).filter_map do |path|
        next if path.empty?
        key = path.downcase
        next if seen[key]

        seen[key] = true
        path
      end.join(';')
    end

    private def spawn_external_echoes(env)
      Process.spawn(env, *external_echoes_command)
    end

    private def external_echoes_command
      exe = File.expand_path('../../exe/echoes', __dir__)
      target = File.exist?(exe) ? exe : $PROGRAM_NAME
      [RbConfig.ruby, target]
    end

    private def set_window_title(title)
      return if !@hwnd || Win32.null_pointer?(@hwnd)

      Win32::SetWindowTextW.call(@hwnd, Fiddle::Pointer[Win32.to_wstring(title.to_s)])
      WindowRegistry.update_title(Process.pid, title.to_s)
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

      paste_text_to_active_pane(str)
    rescue Errno::EIO, IOError
    end

    private def paste_text_to_active_pane(str)
      pane = current_tab&.active_pane
      return false unless pane
      return false if str.nil? || str.empty?

      if pane.screen.bracketed_paste_mode?
        write_pane_input(pane, "\e[200~")
        write_pane_input(pane, str)
        write_pane_input(pane, "\e[201~")
      else
        write_pane_input(pane, str)
      end
      true
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
      scrollback_size = pane.screen.scrollback.size
      sr += scrollback_size
      er += scrollback_size
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
      if screen.respond_to?(:background) && screen.background
        draw_pane_background(hdc, screen.background, px, py, pane_cols, pane_rows)
      end
      if screen.respond_to?(:bg_fills) && screen.bg_fills && !screen.bg_fills.empty?
        draw_pane_fills(hdc, screen.bg_fills, px, py, pane_cols, pane_rows)
      end

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
          if cell.width.to_i == 0 || cell.multicell == :cont
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
          if (search_colors = search_colors_for_cell(is_active, src, c))
            fg_color, bg_color = search_colors
          end

          if cell.multicell.is_a?(Hash)
            draw_multicell_text(hdc, cell, px + c * @cell_width, y, fg_color, bg_color)
            c += cell.multicell[:cols].to_i.clamp(1, pane_cols - c)
            next
          end

          cell_width = [cell.width.to_i, 1].max
          run_length = cell_width
          run_str = cell.char || " "

          while (c + run_length) < pane_cols
            next_cell = row[c + run_length]
            break unless next_cell
            break if [next_cell.width.to_i, 1].max != cell_width || next_cell.multicell

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
            if (n_search_colors = search_colors_for_cell(is_active, src, c + run_length))
              n_fg_color, n_bg_color = n_search_colors
            end

            break if n_fg_color != fg_color ||
                     n_bg_color != bg_color ||
                     n_bold != cell.bold ||
                     n_italic != cell.italic ||
                     n_underline != cell.underline ||
                     n_strikethrough != cell.strikethrough

            run_str += next_cell.char || " "
            run_length += cell_width
          end

          Win32::SetTextColor.call(hdc, fg_color)
          Win32::SetBkColor.call(hdc, bg_color)

          cx = px + c * @cell_width
          run_font = font_for_cell(cell)
          run_x = cx
          font_runs_for_text(run_font, run_str, bold: cell.bold, italic: cell.italic).each do |text, font|
            draw_text_run(hdc, run_x, y, text, font)
            run_x += text.length * cell_width * @cell_width
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

        ime_bg = (130 << 16) | (65 << 8) | 30
        ime_fg = 0xFFFFFF

        Win32::SetTextColor.call(hdc, ime_fg)
        Win32::SetBkColor.call(hdc, ime_bg)
        draw_ime_marked_text(hdc, mx, my, @marked_text, @cell_height)
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

    private def draw_pane_background(hdc, spec, px, py, pane_cols, pane_rows)
      colors = spec[:colors]
      return if !colors || colors.empty?

      width = pane_cols * @cell_width
      height = pane_rows * @cell_height
      case spec[:type]
      when :flat
        fill_rect_color(hdc, px, py, px + width, py + height, rgba_to_color(colors.first))
      when :linear
        return if colors.size < 2

        draw_linear_gradient(
          hdc,
          px,
          py,
          width,
          height,
          colors,
          spec[:angle].to_f
        )
      end
    end

    private def draw_pane_fills(hdc, fills, px, py, pane_cols, pane_rows)
      fills.each do |fill|
        rect = fill[:rect]
        rgba = fill[:color]
        next unless rect && rgba && rect.size == 4

        r1, c1, r2, c2 = rect
        r1 = r1.clamp(0, pane_rows - 1)
        r2 = r2.clamp(0, pane_rows - 1)
        c1 = c1.clamp(0, pane_cols - 1)
        c2 = c2.clamp(0, pane_cols - 1)
        next if r1 > r2 || c1 > c2

        left = px + c1 * @cell_width
        top = py + r1 * @cell_height
        right = px + (c2 + 1) * @cell_width
        bottom = py + (r2 + 1) * @cell_height
        fill_rect_color(hdc, left, top, right, bottom, rgba_to_color(rgba))
      end
    end

    private def draw_linear_gradient(hdc, x, y, width, height, colors, angle)
      return if width <= 0 || height <= 0
      return if !colors || colors.empty?

      horizontal = Math.cos(angle * Math::PI / 180.0).abs >= Math.sin(angle * Math::PI / 180.0).abs
      steps = horizontal ? width : height
      steps = [steps, 1].max

      steps.times do |i|
        t = steps == 1 ? 0.0 : i.to_f / (steps - 1)
        color = gradient_color_at(colors, t)
        if horizontal
          fill_rect_color(hdc, x + i, y, x + i + 1, y + height, color)
        else
          fill_rect_color(hdc, x, y + i, x + width, y + i + 1, color)
        end
      end
    end

    private def gradient_color_at(colors, t)
      return rgba_to_color(colors.first) if colors.size == 1

      position = t.clamp(0.0, 1.0) * (colors.size - 1)
      index = position.floor
      index = colors.size - 2 if index >= colors.size - 1
      local_t = position - index
      start_rgb = rgba_to_rgb(colors[index])
      end_rgb = rgba_to_rgb(colors[index + 1])
      interpolate_color(start_rgb, end_rgb, local_t)
    end

    private def interpolate_color(start_rgb, end_rgb, t)
      r = (start_rgb[0] + (end_rgb[0] - start_rgb[0]) * t).round
      g = (start_rgb[1] + (end_rgb[1] - start_rgb[1]) * t).round
      b = (start_rgb[2] + (end_rgb[2] - start_rgb[2]) * t).round
      (b << 16) | (g << 8) | r
    end

    private def rgba_to_color(rgba)
      r, g, b = rgba_to_rgb(rgba)
      (b << 16) | (g << 8) | r
    end

    private def rgba_to_rgb(rgba)
      rgb = rgba[0, 3].map do |component|
        value = component.to_f
        value <= 1.0 ? (value * 255).round : value.round
      end
      alpha = rgba[3].nil? ? 1.0 : rgba[3].to_f
      alpha /= 255.0 if alpha > 1.0
      alpha = alpha.clamp(0.0, 1.0)
      return rgb if alpha >= 1.0

      base = colorref_to_rgb(@default_bg || 0)
      rgb.zip(base).map { |component, base_component| (component * alpha + base_component * (1.0 - alpha)).round }
    end

    private def colorref_to_rgb(color)
      value = color.to_i
      [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF]
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

    private def capture_pane_to_png(pane, path)
      return false unless @cell_width && @cell_height

      rect = pane_rect_for(pane)
      return false unless rect

      width = rect[:w] * @cell_width
      height = rect[:h] * @cell_height
      return false if width <= 0 || height <= 0

      is_active = pane == current_tab&.active_pane
      bytes = case self.class.capture_format_for(path)
              when :png
                png_bytes_for_pane_capture(pane, width, height, is_active)
              else
                pdf_bytes_for_pane_capture(pane, width, height, is_active)
              end
      return false unless bytes

      File.binwrite(path, bytes)
      true
    rescue StandardError => e
      warn "echoes capture: #{e.class}: #{e.message}"
      false
    end

    private def pane_rect_for(pane)
      tab = current_tab
      return nil unless tab

      tab.pane_tree.layout(0, 0, @cols, @rows).find { |rect| rect[:pane] == pane }
    end

    private def png_bytes_for_pane_capture(pane, width, height, is_active)
      bgra = capture_pane_bgra(pane, width, height, is_active)
      return nil unless bgra

      rgba = bgra_to_rgba_opaque(bgra, width, height)
      encode_png_rgba(width, height, rgba)
    end

    private def pdf_bytes_for_pane_capture(pane, width, height, is_active)
      bgra = capture_pane_bgra(pane, width, height, is_active)
      return nil unless bgra

      rgb = bgra_to_rgb_opaque(bgra, width, height)
      encode_pdf_rgb_image(width, height, rgb)
    end

    private def capture_pane_bgra(pane, width, height, is_active)
      return nil unless Win32::GetDIBits

      screen_dc = nil
      mem_dc = nil
      bitmap = nil
      old_bitmap = nil

      screen_dc = Win32::GetDC.call(@hwnd || 0)
      return nil if !screen_dc || Win32.null_pointer?(screen_dc)

      mem_dc = create_compatible_dc(screen_dc)
      return nil if !mem_dc || Win32.null_pointer?(mem_dc)

      bitmap = create_compatible_bitmap(screen_dc, width, height)
      return nil if !bitmap || Win32.null_pointer?(bitmap)

      old_bitmap = select_gdi_object(mem_dc, bitmap)
      draw_pane_content(mem_dc, pane, 0, 0, width, height, is_active)
      select_gdi_object(mem_dc, old_bitmap) if old_bitmap
      old_bitmap = nil

      bitmap_bgra(screen_dc, bitmap, width, height)
    ensure
      select_gdi_object(mem_dc, old_bitmap) if mem_dc && old_bitmap
      delete_gdi_object(bitmap) if bitmap && !Win32.null_pointer?(bitmap)
      delete_dc(mem_dc) if mem_dc && !Win32.null_pointer?(mem_dc)
      Win32::ReleaseDC.call(@hwnd || 0, screen_dc) if screen_dc && !Win32.null_pointer?(screen_dc)
    end

    private def bitmap_bgra(hdc, bitmap, width, height)
      bytes = width * height * 4
      pixels = Fiddle::Pointer.malloc(bytes, Fiddle::RUBY_FREE)
      pixels[0, bytes] = "\x00" * bytes
      info = bitmap_info_header(width, height, bytes)
      copied = Win32::GetDIBits.call(
        hdc,
        bitmap,
        0,
        height,
        pixels,
        Fiddle::Pointer[info],
        Win32::DIB_RGB_COLORS
      )
      return nil if copied == 0

      pixels[0, bytes]
    end

    private def bgra_to_rgba_opaque(bgra, width, height)
      return nil unless bgra && bgra.bytesize == width * height * 4

      rgba = String.new(capacity: bgra.bytesize, encoding: Encoding::BINARY)
      bgra.scan(/.{4}/m) do |px|
        alpha = px.getbyte(3)
        alpha = 255 if alpha == 0
        rgba << px.getbyte(2) << px.getbyte(1) << px.getbyte(0) << alpha
      end
      rgba
    end

    private def bgra_to_rgb_opaque(bgra, width, height)
      return nil unless bgra && bgra.bytesize == width * height * 4

      rgb = String.new(capacity: width * height * 3, encoding: Encoding::BINARY)
      bgra.scan(/.{4}/m) do |px|
        rgb << px.getbyte(2) << px.getbyte(1) << px.getbyte(0)
      end
      rgb
    end

    private def encode_pdf_rgb_image(width, height, rgb)
      return nil unless width.positive? && height.positive?
      return nil unless rgb && rgb.bytesize == width * height * 3

      image = Zlib::Deflate.deflate(rgb)
      content = "q\n#{width} 0 0 #{height} 0 0 cm\n/Im0 Do\nQ\n".b
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>\n".b,
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>\n".b,
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{width} #{height}] " \
          "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\n".b,
        "<< /Type /XObject /Subtype /Image /Width #{width} /Height #{height} " \
          "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode " \
          "/Length #{image.bytesize} >>\nstream\n".b + image + "\nendstream\n".b,
        "<< /Length #{content.bytesize} >>\nstream\n".b + content + "endstream\n".b
      ]

      pdf = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
      offsets = [0]
      objects.each_with_index do |obj, index|
        offsets << pdf.bytesize
        pdf << "#{index + 1} 0 obj\n".b << obj << "endobj\n".b
      end

      xref_offset = pdf.bytesize
      pdf << "xref\n0 #{objects.size + 1}\n".b
      pdf << "0000000000 65535 f \n".b
      offsets.drop(1).each do |offset|
        pdf << format("%010d 00000 n \n", offset).b
      end
      pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n".b
      pdf << "startxref\n#{xref_offset}\n%%EOF\n".b
      pdf
    end

    private def encode_png_rgba(width, height, rgba)
      return nil unless width.positive? && height.positive?
      return nil unless rgba && rgba.bytesize == width * height * 4

      raw = String.new(capacity: height * (1 + width * 4), encoding: Encoding::BINARY)
      row_bytes = width * 4
      height.times do |row|
        raw << 0
        raw << rgba.byteslice(row * row_bytes, row_bytes)
      end

      "\x89PNG\r\n\x1A\n".b +
        png_chunk("IHDR", [width, height, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
        png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
        png_chunk("IEND", "")
    end

    private def png_chunk(type, data)
      body = type + data
      [data.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
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

    private def search_colors_for_cell(is_active, abs_row, col)
      return nil unless is_active && @search_mode
      return [@default_fg, @search_current_bg] if current_search_match_at?(abs_row, col)
      return [@default_fg, @search_match_bg] if search_match_at?(abs_row, col)

      nil
    end

    private def toggle_search
      @search_mode = !@search_mode
      if @search_mode
        @search_query = +""
        @search_matches = []
        @search_index = -1
      end
      true
    end

    private def handle_search_char(chars)
      return false if chars.nil? || chars.empty?

      @search_query << chars
      perform_search
      true
    end

    private def handle_search_keydown(vk, ctrl_pressed:, shift_pressed:)
      case vk
      when 0x1B
        @search_mode = false
        @search_matches = []
        true
      when 0x0D
        shift_pressed ? search_prev : search_next
        true
      when 0x08
        @search_query.chop!
        perform_search
        true
      when 0x49
        return false unless ctrl_pressed

        @search_case_insensitive = !@search_case_insensitive
        perform_search
        true
      when 0x52
        return false unless ctrl_pressed

        @search_regex_mode = !@search_regex_mode
        perform_search
        true
      else
        false
      end
    end

    private def perform_search
      @search_matches = []
      @search_index = -1
      return if @search_query.empty?

      tab = current_tab
      return unless tab

      screen = tab.screen
      matcher = build_search_matcher(@search_query)
      return unless matcher

      screen.scrollback.each_with_index do |row, abs_row|
        scan_row_for_matches(row, abs_row, matcher)
      end
      screen.grid.each_with_index do |row, grid_row|
        scan_row_for_matches(row, screen.scrollback.size + grid_row, matcher)
      end

      @search_index = @search_matches.size - 1 if @search_matches.any?
      scroll_to_match if @search_index >= 0
    end

    private def scan_row_for_matches(row, abs_row, matcher)
      text = row.map { |cell| cell&.char.to_s }.join
      pos = 0
      while pos <= text.length && (hit = matcher.call(text, pos))
        idx, len = hit
        break if idx < pos

        step = [len, 1].max
        @search_matches << [abs_row, idx, step]
        pos = idx + step
      end
    end

    private def search_next
      return false if @search_matches.empty?

      @search_index = (@search_index + 1) % @search_matches.size
      scroll_to_match
      true
    end

    private def search_prev
      return false if @search_matches.empty?

      @search_index = (@search_index - 1) % @search_matches.size
      scroll_to_match
      true
    end

    private def scroll_to_match
      return false if @search_index < 0 || @search_index >= @search_matches.size

      abs_row, = @search_matches[@search_index]
      tab = current_tab
      return false unless tab

      scrollback_size = tab.screen.scrollback.size
      scroll_target = tab.respond_to?(:scroll_offset=) ? tab : tab.active_pane
      if abs_row < scrollback_size
        scroll_target.scroll_offset = (scrollback_size - abs_row - (@rows / 2)).clamp(0, scrollback_size)
      else
        scroll_target.scroll_offset = 0
      end
      true
    end

    private def search_match_at?(abs_row, col)
      @search_matches.any? { |row, start, len| row == abs_row && col >= start && col < start + len }
    end

    private def current_search_match_at?(abs_row, col)
      return false if @search_index < 0 || @search_index >= @search_matches.size

      row, start, len = @search_matches[@search_index]
      row == abs_row && col >= start && col < start + len
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

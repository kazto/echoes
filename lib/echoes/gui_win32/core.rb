# frozen_string_literal: true

require 'json'
require 'rbconfig'
require 'socket'
require 'uri'
require 'zlib'
require_relative "../gui/search_controller"
require_relative "../gui/layout"

module Echoes
  class GUI
    class Backend
      class Win32 < Backend
        require_relative "../gui/osc7"
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
        MENU_BRING_ALL_TO_FRONT = 10_026
        MENU_SELECT_ALL = 10_027
        MENU_INCREASE_FONT = 10_028
        MENU_DECREASE_FONT = 10_029
        MENU_RESET_FONT = 10_030
        MENU_WINDOW_BASE = 10_100
        MENU_PROFILE_BASE = 10_200
        MENU_COMPLETION_BASE = 10_400
        TIMER_ID = 1
        TIMER_INTERVAL_MS = 15

        ACCELERATORS = [
          [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x54, MENU_NEW_TAB],   # Ctrl+T
          [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x4F, MENU_OPEN_FILE], # Ctrl+O
          [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x46, MENU_FIND],      # Ctrl+F
          [Echoes::Win32::FVIRTKEY, 0x72, MENU_FIND_NEXT],                   # F3
          [Echoes::Win32::FSHIFT | Echoes::Win32::FVIRTKEY, 0x72, MENU_FIND_PREVIOUS], # Shift+F3
          [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x57, MENU_CLOSE_TAB], # Ctrl+W
          [Echoes::Win32::FCONTROL | Echoes::Win32::FSHIFT | Echoes::Win32::FVIRTKEY, 0x44, MENU_SPLIT_DOWN], # Ctrl+Shift+D
          [Echoes::Win32::FCONTROL | Echoes::Win32::FSHIFT | Echoes::Win32::FVIRTKEY, 0x57, MENU_CLOSE_PANE], # Ctrl+Shift+W
          [Echoes::Win32::FCONTROL | Echoes::Win32::FSHIFT | Echoes::Win32::FVIRTKEY, 0x50, MENU_TOGGLE_POINTER], # Ctrl+Shift+P
          [Echoes::Win32::FALT | Echoes::Win32::FVIRTKEY, 0x73, MENU_EXIT],          # Alt+F4
          [Echoes::Win32::FVIRTKEY, 0x70, MENU_ABOUT],                       # F1
          [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x41, MENU_SELECT_ALL], # Ctrl+A
          [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0xBB, MENU_INCREASE_FONT], # Ctrl++ (VK_OEM_PLUS)
          [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0xBD, MENU_DECREASE_FONT], # Ctrl+- (VK_OEM_MINUS)
          [Echoes::Win32::FCONTROL | Echoes::Win32::FVIRTKEY, 0x30, MENU_RESET_FONT]  # Ctrl+0
        ].freeze

        extend Echoes::GUI::Osc7

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
          @selection_anchor = nil
          @selection_end = nil
          @selection_dragged = false
          @pointer_hidden = false
          @shake_detector = nil
          @marked_text = nil # IME inline composition string
          @marked_reading = nil # IME reading string (furigana)
          @fullscreen_state = false
          @window_menu_handle = nil
          @window_menu_update_counter = 0
          @window_menu_dynamic_count = 0
          @search = Echoes::GUI::SearchController.new
          @win32_pending_vk = nil
          @win32_pending_scan = 0
          @win32_pending_ctrl_state = 0

          # カラーテーマの初期化
          @active_profile = Echoes.config.active_profile rescue nil
          @colors = build_color_table
          @default_fg = make_color(*default_fg_rgb)
          @default_bg = make_color(*default_bg_rgb)
          @search_match_bg = make_color(0.45, 0.38, 0.0)
          @search_current_bg = make_color(0.1, 0.45, 0.55)

          # タブ表示用カラー
          @tab_bg = make_color(0.15, 0.15, 0.15)
          @tab_active_bg = make_color(0.25, 0.25, 0.25)
          @tab_fg = make_color(0.8, 0.8, 0.8)

          # 境界線・デバイダー用ブラシの作成
          @active_border_brush = Win32::CreateSolidBrush.call(make_color(0.2, 0.4, 0.8))
          @inactive_border_brush = Win32::CreateSolidBrush.call(make_color(0.3, 0.3, 0.3))
          @tab_bg_brush = Win32::CreateSolidBrush.call(@tab_bg)
          @tab_active_bg_brush = Win32::CreateSolidBrush.call(@tab_active_bg)

          # GDI+ の起動
          Win32.gdiplus_startup

          # 初期タブの起動
          create_tab
        end

        def current_tab
          @tabs[@active_tab]
        end

        def tab_bar_height
          return 0.0 unless @cell_height
          Echoes::GUI::Layout.tab_bar_height(@tabs.size, @cell_height)
        end

        def tab_bar_y
          Echoes::GUI::Layout.tab_bar_y(:top, @cell_height.to_f, @rows.to_i)
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
              if @tab_bg_brush
                Win32::DeleteObject.call(@tab_bg_brush)
              end
              if @tab_active_bg_brush
                Win32::DeleteObject.call(@tab_active_bg_brush)
              end
              WindowRegistry.cleanup
              Win32.gdiplus_shutdown
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
              return 0 if handle_normal_selection_char(char_code)

              if @win32_pending_vk && (tab = current_tab) && (pane = tab.active_pane) &&
                 pane_win32_input_mode?(pane)
                deliver_win32_char(pane, char_code)
                next 0
              end

              if (utf8_char = windows_char_input(char_code))
                if utf8_char && (pane = current_tab&.active_pane)&.copy_mode&.active
                  handle_copy_mode_key(pane, utf8_char)
                  Win32::InvalidateRect.call(hwnd, nil, 1)
                  return 0
                end
                if utf8_char && @search.active
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

              if handle_normal_selection_keydown(vk, ctrl_pressed: ctrl_pressed, shift_pressed: shift_pressed)
                return 0
              end

              if (pane = current_tab&.active_pane)&.copy_mode&.active
                if (key = copy_mode_key_for_keydown(vk, ctrl_pressed: ctrl_pressed))
                  handle_copy_mode_key(pane, key)
                  Win32::InvalidateRect.call(hwnd, nil, 1)
                end
                return 0
              end

              if @search.active && handle_search_keydown(vk, ctrl_pressed: ctrl_pressed, shift_pressed: shift_pressed)
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

              unless handled_key
                if (pane = current_tab&.active_pane) && pane_win32_input_mode?(pane)
                  handle_win32_keydown(pane, vk, ctrl_pressed: ctrl_pressed, shift_pressed: shift_pressed)
                  next 0
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
              wparam = msg_struct[16, Fiddle::SIZEOF_VOIDP].unpack1(Fiddle::SIZEOF_VOIDP == 8 ? 'Q' : 'L')
              next if handle_normal_selection_key_message(message, wparam)
              # In win32_input_mode (e.g. WSL), plain Ctrl+letter keys must reach
              # the shell as control characters (^A = line-begin, ^W = kill-word,
              # etc.). Skip the accelerator table so WM_KEYDOWN dispatches to
              # handle_win32_keydown instead of firing GUI actions like select-all.
              skip_accel = message == Win32::WM_KEYDOWN &&
                           (Win32::GetKeyState.call(0x11) & 0x8000) != 0 &&
                           (Win32::GetKeyState.call(0x10) & 0x8000) == 0 &&
                           (pane = current_tab&.active_pane) &&
                           pane_win32_input_mode?(pane)
              next if !skip_accel && translate_accelerator(msg_struct)

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
      end  # class Win32
    end    # class Backend
  end      # class GUI
end        # module Echoes

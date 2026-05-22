# frozen_string_literal: true

require 'fiddle'

module Echoes
  class GUI
    class MacWindow
      ObjC = Echoes::ObjC

      NS_BITMAP_IMAGE_FILE_TYPE_PNG = 4

      MODIFIED_KEYS = {
        "\u{F700}" => ['1', 'A'],   # Up
        "\u{F701}" => ['1', 'B'],   # Down
        "\u{F702}" => ['1', 'D'],   # Left
        "\u{F703}" => ['1', 'C'],   # Right
        "\u{F728}" => ['3', '~'],   # Delete
        "\u{F729}" => ['1', 'H'],   # Home
        "\u{F72B}" => ['1', 'F'],   # End
        "\u{F72C}" => ['5', '~'],   # Page Up
        "\u{F72D}" => ['6', '~'],   # Page Down
        "\u{F704}" => ['1', 'P'],   # F1
        "\u{F705}" => ['1', 'Q'],   # F2
        "\u{F706}" => ['1', 'R'],   # F3
        "\u{F707}" => ['1', 'S'],   # F4
        "\u{F708}" => ['15', '~'],  # F5
        "\u{F709}" => ['17', '~'],  # F6
        "\u{F70A}" => ['18', '~'],  # F7
        "\u{F70B}" => ['19', '~'],  # F8
        "\u{F70C}" => ['20', '~'],  # F9
        "\u{F70D}" => ['21', '~'],  # F10
        "\u{F70E}" => ['23', '~'],  # F11
        "\u{F70F}" => ['24', '~'],  # F12
      }.freeze

      KEYPAD_APP_MAP = {
        '0' => "\eOp", '1' => "\eOq", '2' => "\eOr", '3' => "\eOs",
        '4' => "\eOt", '5' => "\eOu", '6' => "\eOv", '7' => "\eOw",
        '8' => "\eOx", '9' => "\eOy", '-' => "\eOm", '+' => "\eOk",
        '*' => "\eOj", '/' => "\eOo", '.' => "\eOn", "\r" => "\eOM",
        '=' => "\eOX",
      }.freeze

      DEFAULT_PATH_DIRS = %w[
        /opt/homebrew/bin
        /usr/local/bin
        /usr/bin
        /bin
        /usr/sbin
        /sbin
      ].freeze

      def initialize(gui, command:, rows:, cols:, font_size:)
        @gui = gui
        @command = command
        @rows = rows
        @cols = cols
        @font_size = font_size

        # Sync variables to parent GUI to maintain backwards compatibility with existing tests
        sync_to_gui(:@rows, @rows)
        sync_to_gui(:@cols, @cols)
        sync_to_gui(:@font_size, @font_size)

        @font_cache = {}
        @rgb_color_cache = {}
        @nsstring_cache = {}
        @pointer_hidden = false
      end

      # Start OS-specific event loop
      def start_event_loop
        setup_app
        create_fonts
        create_view_class
        open_new_window
        setup_timer
        start_app
      end

      def setup_app
        @app = ObjC::MSG_PTR.call(ObjC.cls('NSApplication'), ObjC.sel('sharedApplication'))
        sync_to_gui(:@app, @app)
        ObjC::MSG_VOID_I.call(@app, ObjC.sel('setActivationPolicy:'), 0)
        disable_press_and_hold
        ObjC::MSG_VOID_I.call(ObjC.cls('NSWindow'), ObjC.sel('setAllowsAutomaticWindowTabbing:'), 0)
        setup_menu_bar
      end

      def disable_press_and_hold
        std = ObjC::MSG_PTR.call(ObjC.cls('NSUserDefaults'), ObjC.sel('standardUserDefaults'))
        dict = ObjC.nsdict({
          ObjC.nsstring('ApplePressAndHoldEnabled') => ObjC.nsnumber_int(0),
        })
        ObjC::MSG_VOID_1.call(std, ObjC.sel('registerDefaults:'), dict)
      end

      def setup_menu_bar
        main_menu = create_menu('')

        # Application menu
        app_menu = create_menu('Echoes')
        add_menu_item(app_menu, "About Echoes", 'showAbout:', '')
        add_separator(app_menu)
        add_menu_item(app_menu, "Hide Echoes", 'hide:', 'h')
        add_menu_item(app_menu, "Hide Others", 'hideOtherApplications:', '')
        add_menu_item(app_menu, "Show All", 'unhideAllApplications:', '')
        add_separator(app_menu)
        add_menu_item(app_menu, "Quit Echoes", 'terminate:', 'q')
        add_submenu(main_menu, app_menu, 'Echoes')

        # Edit menu
        edit_menu = create_menu('Edit')
        add_menu_item(edit_menu, "Copy", 'copy:', 'c')
        add_menu_item(edit_menu, "Paste", 'paste:', 'v')
        add_menu_item(edit_menu, "Select All", 'selectAll:', 'a')
        add_submenu(main_menu, edit_menu, 'Edit')

        # View menu
        view_menu = create_menu('View')
        add_menu_item(view_menu, "Bigger", 'increaseFontSize:', '=', bind: :increase_font_size)
        add_menu_item(view_menu, "Bigger", 'increaseFontSize:', '+', bind: :increase_font_size_plus)
        add_menu_item(view_menu, "Smaller", 'decreaseFontSize:', '-', bind: :decrease_font_size)
        add_menu_item(view_menu, "Reset Font Size", 'resetFontSize:', '0', bind: :reset_font_size)
        add_separator(view_menu)
        add_menu_item(view_menu, "Find", 'toggleFind:', 'f', bind: :toggle_find)
        add_menu_item(view_menu, "Find Next", 'findNext:', 'g', bind: :find_next)
        add_menu_item(view_menu, "Find Previous", 'findPrevious:', 'g',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                      bind: :find_previous)
        add_separator(view_menu)
        add_menu_item(view_menu, "Hide Mouse Pointer", 'togglePointer:', 'p',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                      bind: :toggle_pointer)
        build_profiles_submenu(view_menu)
        add_submenu(main_menu, view_menu, 'View')

        # Window menu
        window_menu = create_menu('Window')
        add_menu_item(window_menu, "Minimize", 'miniaturize:', 'm')
        add_menu_item(window_menu, "Zoom", 'zoom:', '')
        add_menu_item(window_menu, "Enter Full Screen", 'toggleFullScreen:', 'f',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagControl)
        add_separator(window_menu)
        add_menu_item(window_menu, "Show Previous Tab", 'showPreviousTab:', '{',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                      bind: :show_previous_tab)
        add_menu_item(window_menu, "Show Next Tab", 'showNextTab:', '}',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                      bind: :show_next_tab)
        add_separator(window_menu)
        add_menu_item(window_menu, "Select Next Pane", 'selectNextPane:', ']', bind: :select_next_pane)
        add_menu_item(window_menu, "Select Previous Pane", 'selectPreviousPane:', '[', bind: :select_previous_pane)
        add_separator(window_menu)
        add_menu_item(window_menu, "Toggle Copy Mode", 'toggleCopyMode:', 'c',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                      bind: :toggle_copy_mode)
        add_separator(window_menu)
        ObjC::MSG_VOID_1.call(@app, ObjC.sel('setWindowsMenu:'), window_menu)
        add_submenu(main_menu, window_menu, 'Window')

        # Shell menu
        shell_menu = create_menu('Shell')
        add_menu_item(shell_menu, "New Window", 'newWindow:', 'n', bind: :new_window)
        add_menu_item(shell_menu, "New Tab", 'newTab:', 't', bind: :new_tab)
        add_menu_item(shell_menu, "Close Tab", 'closeTab:', 'w', bind: :close_tab)
        add_separator(shell_menu)
        add_menu_item(shell_menu, "Edit File…", 'editFile:', 'e',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                      bind: :edit_file)
        add_separator(shell_menu)
        add_menu_item(shell_menu, "Split Right", 'splitRight:', 'd', bind: :split_right)
        add_menu_item(shell_menu, "Split Down", 'splitDown:', 'd',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                      bind: :split_down)
        add_menu_item(shell_menu, "Close Pane", 'closePane:', 'w',
                      modifiers: ObjC::NSEventModifierFlagCommand | ObjC::NSEventModifierFlagShift,
                      bind: :close_pane)
        add_submenu(main_menu, shell_menu, 'Shell')

        ObjC::MSG_VOID_1.call(@app, ObjC.sel('setMainMenu:'), main_menu)
      end

      def create_menu(title)
        m = ObjC::MSG_PTR.call(ObjC.cls('NSMenu'), ObjC.sel('alloc'))
        ObjC::MSG_PTR_1.call(m, ObjC.sel('initWithTitle:'), ObjC.nsstring(title))
      end

      def add_menu_item(menu, title, selector, key, modifiers: ObjC::NSEventModifierFlagCommand, bind: nil)
        if bind && (over = Echoes.config.keybind_for(bind))
          key = over[:key].to_s
          modifiers = over[:modifiers]
        end

        item = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('alloc'))
        item = ObjC::MSG_PTR_3.call(item, ObjC.sel('initWithTitle:action:keyEquivalent:'),
          ObjC.nsstring(title), selector.empty? ? Fiddle::Pointer.new(0) : ObjC.sel(selector), ObjC.nsstring(key))
        if modifiers != ObjC::NSEventModifierFlagCommand && !key.empty?
          ObjC::MSG_VOID_L.call(item, ObjC.sel('setKeyEquivalentModifierMask:'), modifiers)
        end
        ObjC::MSG_VOID_1.call(menu, ObjC.sel('addItem:'), item)
        item
      end

      def add_separator(menu)
        sep = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('separatorItem'))
        ObjC::MSG_VOID_1.call(menu, ObjC.sel('addItem:'), sep)
      end

      def profile_selectors
        out = {}
        Echoes.config.all_profiles.each_key.with_index do |pname, i|
          out[profile_selector_for(pname)] = ['v@:@', @profile_closures[pname]]
        end
        out
      end

      def profile_selector_for(name)
        i = Echoes.config.all_profiles.keys.index(name)
        "applyProfile_#{i}:"
      end

      def build_profiles_submenu(view_menu)
        profiles = Echoes.config.all_profiles
        return if profiles.empty?
        add_separator(view_menu)
        submenu = create_menu('Profile')
        profiles.each_key do |pname|
          add_menu_item(submenu, pname, profile_selector_for(pname), '')
        end
        add_submenu(view_menu, submenu, 'Profile')
      end

      def add_submenu(parent, submenu, title)
        item = ObjC::MSG_PTR.call(ObjC.cls('NSMenuItem'), ObjC.sel('alloc'))
        item = ObjC::MSG_PTR_3.call(item, ObjC.sel('initWithTitle:action:keyEquivalent:'),
          ObjC.nsstring(title), Fiddle::Pointer.new(0), ObjC.nsstring(''))
        ObjC::MSG_VOID_1.call(item, ObjC.sel('setSubmenu:'), submenu)
        ObjC::MSG_VOID_1.call(parent, ObjC.sel('addItem:'), item)
      end

      def create_fonts
        @font = ObjC.retain(create_nsfont(@font_size))
        @bold_font = ObjC.retain(create_bold_nsfont(@font))
        sync_to_gui(:@font, @font)
        sync_to_gui(:@bold_font, @bold_font)
        @font_y_offset_cache = {}
        update_cell_metrics
      end

      def create_view_class
        gui = @gui
        window = self

        @draw_rect_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
           Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]
        ) do |_self, _cmd, x, y, w, h|
          gui.activate_for_view(_self)
          window.draw_rect(y, y + h)
        rescue => e
          gui.log_crash(e, context: 'draw_rect')
        end

        @key_down_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.key_down(event)
        rescue => e
          gui.log_crash(e, context: 'key_down')
        end

        @accepts_fr_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_INT,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd| 1 }

        @timer_fired_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, _timer|
          window.timer_fired
        rescue => e
          gui.log_crash(e, context: 'timer_fired')
        end

        @is_flipped_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_INT,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd| 1 }

        @reset_cursor_rects_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd|
          ibeam = ObjC::MSG_PTR.call(ObjC.cls('NSCursor'), ObjC.sel('IBeamCursor'))
          w = (@cell_width || 8.0)  * ((window.cols || 80) + 1)
          h = (@cell_height || 16.0) * ((window.rows || 24) + 1) + gui.tab_bar_height
          ObjC::MSG_VOID_RECT_1.call(_self, ObjC.sel('addCursorRect:cursor:'),
                                     0.0, 0.0, w, h, ibeam)
        rescue => e
          gui.log_crash(e, context: 'resetCursorRects')
        end

        @scroll_wheel_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.scroll_wheel(event)
        rescue => e
          gui.log_crash(e, context: 'scroll_wheel')
        end

        @mouse_down_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.mouse_down(event)
        rescue => e
          gui.log_crash(e, context: 'mouse_down')
        end

        @mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.mouse_dragged(event)
        rescue => e
          gui.log_crash(e, context: 'mouse_dragged')
        end

        @mouse_moved_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.mouse_moved(event)
        rescue => e
          gui.log_crash(e, context: 'mouse_moved')
        end

        @mouse_up_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.mouse_up(event)
        rescue => e
          gui.log_crash(e, context: 'mouse_up')
        end

        @right_mouse_down_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.right_mouse_down(event)
        rescue => e
          gui.log_crash(e, context: 'right_mouse_down')
        end

        @right_mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.right_mouse_dragged(event)
        rescue => e
          gui.log_crash(e, context: 'right_mouse_dragged')
        end

        @right_mouse_up_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.right_mouse_up(event)
        rescue => e
          gui.log_crash(e, context: 'right_mouse_up')
        end

        @other_mouse_down_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.other_mouse_down(event)
        rescue => e
          gui.log_crash(e, context: 'other_mouse_down')
        end

        @other_mouse_dragged_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.other_mouse_dragged(event)
        rescue => e
          gui.log_crash(e, context: 'other_mouse_dragged')
        end

        @other_mouse_up_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.other_mouse_up(event)
        rescue => e
          gui.log_crash(e, context: 'other_mouse_up')
        end

        @perform_key_equiv_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_INT,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, event|
          gui.activate_for_view(_self)
          window.perform_key_equivalent(event)
        end

        nsview_cls = ObjC.cls('NSView')
        super_imp = ObjC::GetMethodImpl.call(nsview_cls, ObjC.sel('setFrameSize:'))
        @super_set_frame_size = Fiddle::Function.new(super_imp, [ObjC::P, ObjC::P, ObjC::D, ObjC::D], ObjC::V)

        @set_frame_size_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]
        ) do |_self, _cmd, w, h|
          @super_set_frame_size.call(_self, _cmd, w, h)
          gui.activate_for_view(_self)
          window.handle_resize(w, h)
        rescue => e
          gui.log_crash(e, context: 'set_frame_size')
        end

        @insert_text_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG]
        ) do |_self, _cmd, text, _rep_loc, _rep_len|
          gui.activate_for_view(_self)
          window.ime_insert_text(text)
        rescue => e
          gui.log_crash(e, context: 'insert_text')
        end

        @insert_text_simple_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, text|
          gui.activate_for_view(_self)
          window.ime_insert_text(text)
        rescue => e
          gui.log_crash(e, context: 'insert_text_simple')
        end

        @do_command_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, _selector|
          gui.activate_for_view(_self)
          window.ime_do_command
        rescue => e
          gui.log_crash(e, context: 'do_command')
        end

        @set_marked_text_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
           Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG]
        ) do |_self, _cmd, text, sel_loc, sel_len, _rep_loc, _rep_len|
          gui.activate_for_view(_self)
          window.ime_set_marked_text(text, sel_loc, sel_len)
        rescue => e
          gui.log_crash(e, context: 'set_marked_text')
        end

        @unmark_text_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd|
          gui.activate_for_view(_self)
          window.ime_unmark_text
        rescue => e
          gui.log_crash(e, context: 'unmark_text')
        end

        @has_marked_text_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_INT,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd| window.ime_has_marked_text }

        @marked_range_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_LONG,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd| window.ime_marked_range_location }

        @selected_range_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_LONG,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd| 0x7FFFFFFFFFFFFFFF } # NSNotFound

        @valid_attrs_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOIDP,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd| ObjC::MSG_PTR.call(ObjC.cls('NSArray'), ObjC.sel('array')) }

        @attr_substring_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOIDP,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd, _loc, _len, _actual| Fiddle::Pointer.new(0) }

        @first_rect_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_DOUBLE,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd, _loc, _len, _actual| 0.0 }

        @char_index_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_LONG,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE]
        ) { |_self, _cmd, _x, _y| 0x7FFFFFFFFFFFFFFF } # NSNotFound

        menu_action = proc { |action_block|
          Fiddle::Closure::BlockCaller.new(
            Fiddle::TYPE_VOID,
            [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
          ) do |_self, _cmd, _sender|
            gui.activate_for_view(_self)
            action_block.call
          rescue => e
            gui.log_crash(e, context: 'menu_action')
          end
        }

        @show_about_closure = menu_action.call(-> { window.show_about_panel })

        @profile_closures = {}
        Echoes.config.all_profiles.each_key do |pname|
          @profile_closures[pname] = menu_action.call(-> { window.apply_profile(pname) })
        end
        @new_window_closure = menu_action.call(-> { window.open_new_window })
        @new_tab_closure = menu_action.call(-> {
          gui.create_tab
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @edit_file_closure = menu_action.call(-> {
          path = window.prompt_for_file_to_edit
          if path
            gui.create_tab(editor_file: path)
            ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
          end
        })
        @close_tab_closure = menu_action.call(-> {
          gui.close_tab(gui.active_tab)
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @copy_closure = menu_action.call(-> { window.copy_to_clipboard })
        @paste_closure = menu_action.call(-> { window.paste_from_clipboard })
        @select_all_closure = menu_action.call(-> { window.select_all })
        @increase_font_closure = menu_action.call(-> { window.update_font(window.font_size + 1.0) })
        @decrease_font_closure = menu_action.call(-> { window.update_font(window.font_size - 1.0) if window.font_size > 4.0 })
        @reset_font_closure = menu_action.call(-> {
          Preferences.delete(:font_size)
          window.update_font(Echoes.config.font_size, persist: false)
        })
        @toggle_find_closure = menu_action.call(-> {
          gui.toggle_search
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @find_next_closure = menu_action.call(-> {
          if gui.search_mode && !gui.search_matches.empty?
            gui.search_next
            ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
          end
        })
        @find_prev_closure = menu_action.call(-> {
          if gui.search_mode && !gui.search_matches.empty?
            gui.search_prev
            ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
          end
        })
        @prev_tab_closure = menu_action.call(-> {
          gui.instance_variable_set(:@active_tab, (gui.active_tab - 1) % gui.tabs.size)
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @next_tab_closure = menu_action.call(-> {
          gui.instance_variable_set(:@active_tab, (gui.active_tab + 1) % gui.tabs.size)
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @split_right_closure = menu_action.call(-> {
          tab = gui.current_tab
          new_pane = tab.split_vertical
          gui.wire_screen_handlers(new_pane)
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @split_down_closure = menu_action.call(-> {
          tab = gui.current_tab
          new_pane = tab.split_horizontal
          gui.wire_screen_handlers(new_pane)
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @close_pane_closure = menu_action.call(-> {
          tab = gui.current_tab
          if tab.pane_tree.single_pane?
            gui.close_tab(gui.active_tab)
          else
            tab.close_active_pane
          end
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @select_next_pane_closure = menu_action.call(-> {
          gui.current_tab.next_pane
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })
        @select_prev_pane_closure = menu_action.call(-> {
          gui.current_tab.prev_pane
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })

        @completion_picked_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, sender|
          gui.activate_for_view(_self)
          window.completion_picked(sender)
        rescue => e
          gui.log_crash(e, context: 'completionPicked')
        end

        @toggle_pointer_closure = menu_action.call(-> {
          if @pointer_hidden
            ObjC::MSG_VOID.call(ObjC.cls('NSCursor'), ObjC.sel('unhide'))
            @pointer_hidden = false
          else
            ObjC::MSG_VOID.call(ObjC.cls('NSCursor'), ObjC.sel('hide'))
            @pointer_hidden = true
          end
        })

        @toggle_copy_mode_closure = menu_action.call(-> {
          pane = gui.current_tab.active_pane
          if pane.copy_mode&.active
            pane.copy_mode.exit
            pane.copy_mode = nil
          else
            pane.copy_mode = CopyMode.new(pane.screen)
            pane.copy_mode.enter
          end
          ObjC::MSG_VOID_I.call(window.view, ObjC.sel('setNeedsDisplay:'), 1)
        })

        @dragging_entered_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_LONG,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd, _sender| 1 }  # NSDragOperationCopy

        @perform_drag_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_INT,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) do |_self, _cmd, sender|
          gui.activate_for_view(_self)
          window.perform_drag_operation(sender) ? 1 : 0
        rescue => e
          gui.log_crash(e, context: 'performDragOperation')
          0
        end

        @focus_gained_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd, _notification| gui.activate_for_view(_self); window.window_focus_changed(true) }

        @focus_lost_closure = Fiddle::Closure::BlockCaller.new(
          Fiddle::TYPE_VOID,
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
        ) { |_self, _cmd, _notification| gui.activate_for_view(_self); window.window_focus_changed(false) }

        @view_class = ObjC.define_class('EchoesTerminalView', 'NSView', {
          'drawRect:'             => ['v@:{CGRect=dddd}', @draw_rect_closure],
          'keyDown:'              => ['v@:@', @key_down_closure],
          'acceptsFirstResponder' => ['c@:', @accepts_fr_closure],
          'timerFired:'           => ['v@:@', @timer_fired_closure],
          'isFlipped'             => ['c@:', @is_flipped_closure],
          'resetCursorRects'      => ['v@:', @reset_cursor_rects_closure],
          'scrollWheel:'          => ['v@:@', @scroll_wheel_closure],
          'mouseDown:'            => ['v@:@', @mouse_down_closure],
          'mouseDragged:'         => ['v@:@', @mouse_dragged_closure],
          'mouseMoved:'           => ['v@:@', @mouse_moved_closure],
          'mouseUp:'              => ['v@:@', @mouse_up_closure],
          'rightMouseDown:'       => ['v@:@', @right_mouse_down_closure],
          'rightMouseDragged:'    => ['v@:@', @right_mouse_dragged_closure],
          'rightMouseUp:'         => ['v@:@', @right_mouse_up_closure],
          'otherMouseDown:'       => ['v@:@', @other_mouse_down_closure],
          'otherMouseDragged:'    => ['v@:@', @other_mouse_dragged_closure],
          'otherMouseUp:'         => ['v@:@', @other_mouse_up_closure],
          'performKeyEquivalent:' => ['c@:@', @perform_key_equiv_closure],
          'setFrameSize:'         => ['v@:{CGSize=dd}', @set_frame_size_closure],
          'windowDidBecomeKey:'   => ['v@:@', @focus_gained_closure],
          'windowDidResignKey:'   => ['v@:@', @focus_lost_closure],
          'showAbout:'             => ['v@:@', @show_about_closure],
          **profile_selectors,
          'newWindow:'             => ['v@:@', @new_window_closure],
          'newTab:'               => ['v@:@', @new_tab_closure],
          'editFile:'             => ['v@:@', @edit_file_closure],
          'closeTab:'             => ['v@:@', @close_tab_closure],
          'copy:'                 => ['v@:@', @copy_closure],
          'paste:'                => ['v@:@', @paste_closure],
          'selectAll:'            => ['v@:@', @select_all_closure],
          'increaseFontSize:'     => ['v@:@', @increase_font_closure],
          'decreaseFontSize:'     => ['v@:@', @decrease_font_closure],
          'resetFontSize:'        => ['v@:@', @reset_font_closure],
          'toggleFind:'           => ['v@:@', @toggle_find_closure],
          'findNext:'             => ['v@:@', @find_next_closure],
          'findPrevious:'         => ['v@:@', @find_prev_closure],
          'showPreviousTab:'      => ['v@:@', @prev_tab_closure],
          'showNextTab:'          => ['v@:@', @next_tab_closure],
          'splitRight:'           => ['v@:@', @split_right_closure],
          'splitDown:'            => ['v@:@', @split_down_closure],
          'closePane:'            => ['v@:@', @close_pane_closure],
          'selectNextPane:'       => ['v@:@', @select_next_pane_closure],
          'selectPreviousPane:'   => ['v@:@', @select_prev_pane_closure],
          'toggleCopyMode:'       => ['v@:@', @toggle_copy_mode_closure],
          'togglePointer:'        => ['v@:@', @toggle_pointer_closure],
          'completionPicked:'     => ['v@:@', @completion_picked_closure],
          # NSTextInputClient protocol methods for IME
          'insertText:replacementRange:'                      => ['v@:@{_NSRange=QQ}', @insert_text_closure],
          'insertText:'                                       => ['v@:@', @insert_text_simple_closure],
          'doCommandBySelector:'                              => ['v@::', @do_command_closure],
          'setMarkedText:selectedRange:replacementRange:'     => ['v@:@{_NSRange=QQ}{_NSRange=QQ}', @set_marked_text_closure],
          'unmarkText'                                        => ['v@:', @unmark_text_closure],
          'hasMarkedText'                                     => ['c@:', @has_marked_text_closure],
          'markedRange'                                       => ['{_NSRange=QQ}@:', @marked_range_closure],
          'selectedRange'                                     => ['{_NSRange=QQ}@:', @selected_range_closure],
          'validAttributesForMarkedText'                      => ['@@:', @valid_attrs_closure],
          'attributedSubstringForProposedRange:actualRange:'  => ['@@:{_NSRange=QQ}^{_NSRange=QQ}', @attr_substring_closure],
          'firstRectForCharacterRange:actualRange:'           => ['{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}', @first_rect_closure],
          'characterIndexForPoint:'                           => ['Q@:{CGPoint=dd}', @char_index_closure],
          'draggingEntered:'                                  => ['Q@:@', @dragging_entered_closure],
          'performDragOperation:'                             => ['c@:@', @perform_drag_closure],
        })

        protocol = ObjC::GetProtocol.call('NSTextInputClient')
        ObjC::AddProtocol.call(@view_class, protocol) unless protocol.null?
        sync_to_gui(:@view_class, @view_class)
      end

      def open_new_window
        window_states = get_from_gui(:@window_states)
        view_to_ws = get_from_gui(:@view_to_ws)

        ws = {}
        window_states << ws

        sx = 100.0 + window_states.size * 20.0
        sy = 100.0 + window_states.size * 20.0
        sw = @cell_width * (@cols + 1)
        sh = @cell_height * (@rows + 1) + @gui.tab_bar_height

        style_mask = ObjC::NSWindowStyleMaskDefault
        new_window = ObjC::MSG_PTR.call(ObjC.cls('NSWindow'), ObjC.sel('alloc'))
        new_window = ObjC::MSG_PTR_RECT_L_L_I.call(
          new_window, ObjC.sel('initWithContentRect:styleMask:backing:defer:'),
          sx, sy, sw, sh, style_mask, ObjC::NSBackingStoreBuffered, 0
        )
        ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setTitle:'), ObjC.nsstring("Echoes"))
        ObjC::MSG_VOID_L.call(new_window, ObjC.sel('setCollectionBehavior:'), 1 << 7)
        ObjC::MSG_VOID_I.call(new_window, ObjC.sel('setAcceptsMouseMovedEvents:'), 1)

        new_view = ObjC::MSG_PTR.call(@view_class, ObjC.sel('alloc'))
        new_view = ObjC::MSG_PTR_RECT.call(new_view, ObjC.sel('initWithFrame:'),
                                            0.0, 0.0, sw, sh)

        drag_types = ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'),
                                           ObjC::NSPasteboardTypeFileURL)
        ObjC::MSG_VOID_1.call(new_view, ObjC.sel('registerForDraggedTypes:'), drag_types)

        ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setContentView:'), new_view)
        ObjC::MSG_VOID_1.call(new_window, ObjC.sel('makeKeyAndOrderFront:'), @app)
        ObjC::MSG_VOID_1.call(new_window, ObjC.sel('makeFirstResponder:'), new_view)
        ObjC::MSG_VOID_I.call(@app, ObjC.sel('activateIgnoringOtherApps:'), 1)

        nc = ObjC::MSG_PTR.call(ObjC.cls('NSNotificationCenter'), ObjC.sel('defaultCenter'))
        ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
          new_view, ObjC.sel('windowDidBecomeKey:'),
          ObjC.nsstring('NSWindowDidBecomeKeyNotification'), new_window)
        ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
          new_view, ObjC.sel('windowDidResignKey:'),
          ObjC.nsstring('NSWindowDidResignKeyNotification'), new_window)

        @window = new_window
        @view = new_view
        sync_to_gui(:@window, @window)
        sync_to_gui(:@view, @view)

        gui_tabs = get_from_gui(:@tabs)
        if gui_tabs.empty?
          @gui.create_tab
          @tabs = get_from_gui(:@tabs)
        else
          @tabs = gui_tabs.dup
        end

        @active_tab = 0
        @search_mode = false
        @search_query = +""
        @search_matches = []
        @search_index = -1
        @search_regex_mode = false
        @search_case_insensitive = false
        @bell_flash = 0
        @marked_text = nil
        @current_event = nil
        @selection_anchor = nil
        @selection_end = nil
        @selection_word_anchor = nil
        @window_focused = true

        ws[:nswindow] = @window
        ws[:nsview] = @view
        ws[:tabs] = @tabs
        ws[:active_tab] = @active_tab
        ws[:search_mode] = @search_mode
        ws[:search_query] = @search_query
        ws[:search_matches] = @search_matches
        ws[:search_index] = @search_index
        ws[:bell_flash] = @bell_flash
        ws[:marked_text] = @marked_text
        ws[:current_event] = @current_event
        ws[:selection_anchor] = @selection_anchor
        ws[:selection_end] = @selection_end
        ws[:rows] = @rows
        ws[:cols] = @cols
        ws[:focused] = @window_focused

        view_to_ws[@view.to_i] = ws

        sync_to_gui(:@window_states, window_states)
        sync_to_gui(:@view_to_ws, view_to_ws)
      end

      def setup_timer
        @timer_view_id = @view.to_i
        @timer = ObjC::MSG_PTR_D_P_P_P_I.call(
          ObjC.cls('NSTimer'),
          ObjC.sel('scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:'),
          1.0 / 60.0,
          @view,
          ObjC.sel('timerFired:'),
          Fiddle::Pointer.new(0),
          1
        )
        sync_to_gui(:@timer, @timer)
        sync_to_gui(:@timer_view_id, @timer_view_id)
      end

      def start_app
        ObjC::MSG_VOID.call(@app, ObjC.sel('run'))
      end

      def refresh_screen(dirty_rows = nil)
        return unless @view
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def set_title(title)
        return unless @window
        ObjC::MSG_VOID_1.call(@window, ObjC.sel('setTitle:'), ObjC.nsstring(title))
      end

      def show_notification(title, message)
        effective_title = (title && !title.empty? && title) || 'Echoes'
        if (tn = terminal_notifier_path)
          pid = Process.spawn(tn, '-title', effective_title.to_s, '-message', message.to_s,
                              in: '/dev/null', out: '/dev/null', err: '/dev/null')
        else
          script = "display notification #{applescript_quote(message)} " \
                   "with title #{applescript_quote(effective_title)}"
          pid = Process.spawn('osascript', '-e', script,
                              in: '/dev/null', out: '/dev/null', err: '/dev/null')
        end
        Process.detach(pid)
      rescue StandardError => e
        warn "echoes notification: #{e.class}: #{e.message}"
      end

      def terminal_notifier_path
        return @terminal_notifier_path if defined?(@terminal_notifier_path)
        candidates = %w[
          /opt/homebrew/bin/terminal-notifier
          /usr/local/bin/terminal-notifier
        ]
        path = candidates.find { |p| File.executable?(p) }
        path ||= begin
          which = `command -v terminal-notifier 2>/dev/null`.strip
          which.empty? ? nil : which
        end
        @terminal_notifier_path = path
      end

      def applescript_quote(str)
        escaped = str.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
        %("#{escaped}")
      end

      def open_url(url)
        ns_url = ObjC::MSG_PTR_1.call(ObjC.cls('NSURL'), ObjC.sel('URLWithString:'), ObjC.nsstring(url))
        return false if ns_url.null?
        workspace = ObjC::MSG_PTR.call(ObjC.cls('NSWorkspace'), ObjC.sel('sharedWorkspace'))
        result = ObjC::MSG_PTR_1.call(workspace, ObjC.sel('openURL:'), ns_url)
        !result.null?
      end

      def close
        return unless @window
        ObjC::MSG_VOID_1.call(@window, ObjC.sel('orderOut:'), Fiddle::Pointer.new(0))
      end

      def set_clipboard(text)
        pb = ObjC::MSG_PTR.call(ObjC.cls('NSPasteboard'), ObjC.sel('generalPasteboard'))
        ObjC::MSG_VOID.call(pb, ObjC.sel('clearContents'))
        types = ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'), ObjC::NSPasteboardTypeString)
        ObjC::MSG_VOID_1.call(pb, ObjC.sel('declareTypes:owner:'), types, Fiddle::Pointer.new(0))
        ObjC::MSG_PTR_2.call(pb, ObjC.sel('setString:forType:'), ObjC.nsstring(text), ObjC::NSPasteboardTypeString)
      end

      def get_clipboard
        pb = ObjC::MSG_PTR.call(ObjC.cls('NSPasteboard'), ObjC.sel('generalPasteboard'))
        ns_str = ObjC::MSG_PTR_1.call(pb, ObjC.sel('stringForType:'), ObjC::NSPasteboardTypeString)
        return "" if ns_str.nil? || ns_str.null?
        ObjC.to_ruby_string(ns_str)
      end

      def draw_rect(dirty_min_y = 0.0, dirty_max_y = Float::INFINITY)
        pool = ObjC::MSG_PTR.call(ObjC.cls('NSAutoreleasePool'), ObjC.sel('alloc'))
        pool = ObjC::MSG_PTR.call(pool, ObjC.sel('init'))

        tab = @gui.current_tab
        unless tab
          ObjC::MSG_VOID.call(pool, ObjC.sel('drain'))
          return
        end
        tbh = @gui.tab_bar_height
        gy_off = @gui.grid_y_offset

        ObjC::MSG_VOID.call(@default_bg, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(0.0, dirty_min_y, @cell_width * (@cols + 1), dirty_max_y - dirty_min_y)

        if tbh > 0
          tby = @gui.tab_bar_y
          if dirty_min_y < tby + tbh && dirty_max_y > tby
            draw_tab_bar(tbh, tby)
          end
        end

        pane_rects = tab.pane_tree.layout(0, 0, @cols, @rows)
        pane_rects.each do |rect|
          pane = rect[:pane]
          px = rect[:x] * @cell_width
          py = gy_off + rect[:y] * @cell_height
          is_active = (pane == tab.active_pane)

          draw_pane_content(pane, px, py, dirty_min_y, dirty_max_y, is_active)
        end

        if !tab.pane_tree.single_pane?
          draw_pane_dividers(pane_rects, gy_off)
          draw_active_pane_border(tab, pane_rects, gy_off)
        end

        bell_flash = get_from_gui(:@bell_flash)
        if bell_flash > 0
          flash_color = make_color_with_alpha(make_color(1.0, 1.0, 1.0), 0.15)
          ObjC::MSG_VOID.call(flash_color, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(0.0, gy_off, @cols * @cell_width, @rows * @cell_height)
        end

        search_mode = get_from_gui(:@search_mode)
        if search_mode
          bar_h = @cell_height + 4.0
          bar_y = gy_off + @rows * @cell_height
          bar_bg = make_color(0.2, 0.2, 0.2)
          ObjC::MSG_VOID.call(bar_bg, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(0.0, bar_y, @cols * @cell_width, bar_h)

          search_matches = get_from_gui(:@search_matches)
          search_index = get_from_gui(:@search_index)
          search_regex_mode = get_from_gui(:@search_regex_mode)
          search_case_insensitive = get_from_gui(:@search_case_insensitive)
          search_query = get_from_gui(:@search_query)

          match_info = search_matches.empty? ? "" : " [#{search_index + 1}/#{search_matches.size}]"
          mode_flags = []
          mode_flags << 'regex' if search_regex_mode
          mode_flags << 'i'     if search_case_insensitive
          mode_tag = mode_flags.empty? ? '' : " (#{mode_flags.join(', ')})"
          label = "Find#{mode_tag}: #{search_query}_#{match_info}"
          ns_str = ObjC.nsstring(label)
          ns_attrs = ObjC.nsdict({
            ObjC::NSFontAttributeName => @font,
            ObjC::NSForegroundColorAttributeName => make_color(1.0, 1.0, 1.0),
          })
          ObjC::MSG_VOID_PT_1.call(ns_str, ObjC.sel('drawAtPoint:withAttributes:'), 4.0, bar_y + 2.0, ns_attrs)
        end

        ObjC::MSG_VOID.call(pool, ObjC.sel('drain'))
      end

      def draw_pane_content(pane, px, py, dirty_min_y, dirty_max_y, is_active)
        screen = pane.screen
        scrollback = screen.scrollback
        visible_start = scrollback.size - pane.scroll_offset
        pane_rows = screen.rows
        pane_cols = screen.cols

        copy_mode = pane.copy_mode

        draw_pane_background(screen.background, px, py, pane_cols, pane_rows) if screen.background
        draw_pane_fills(screen.bg_fills, px, py, pane_cols, pane_rows) if screen.bg_fills && !screen.bg_fills.empty?

        pane_rows.times do |r|
          y = py + r * @cell_height
          next if y + @cell_height < dirty_min_y || y > dirty_max_y
          src = visible_start + r
          row = if src < scrollback.size
                  scrollback[src]
                elsif src - scrollback.size < screen.grid.size
                  screen.grid[src - scrollback.size]
                end
          next unless row

          run_chars   = +''
          run_start_c = nil
          run_attrs   = nil
          run_font    = nil
          run_sig     = nil
          flush_run = lambda do
            next if run_chars.empty?
            ns_run = ObjC.nsstring(run_chars)
            run_x  = px + run_start_c * @cell_width
            run_dy = y + y_offset_for_font(run_font)
            ObjC::MSG_VOID_PT_1.call(ns_run, ObjC.sel('drawAtPoint:withAttributes:'),
                                     run_x, run_dy, run_attrs)
            run_chars   = +''
            run_start_c = nil
            run_attrs   = nil
            run_font    = nil
            run_sig     = nil
          end

          row.each_with_index do |cell, c|
            if cell.width == 0 || cell.multicell == :cont
              flush_run.call
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
              fg_color = @colors[fg_val + 8]
            end

            has_bg = !bg_val.nil? || cell.inverse

            selected = is_active && @gui.cell_selected?(src, c)
            is_match = is_active && @gui.search_mode && @gui.search_match_at?(src, c)
            is_current_match = is_active && @gui.search_mode && @gui.current_search_match_at?(src, c)

            if copy_mode&.active && copy_mode.selecting?
              sel_start, sel_end = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
              cm_abs_row = scrollback.size + r - pane.scroll_offset
              if cm_abs_row >= scrollback.size + sel_start[0] && cm_abs_row <= scrollback.size + sel_end[0]
                cm_row = cm_abs_row - scrollback.size
                if cm_row == sel_start[0] && cm_row == sel_end[0]
                  selected = c >= sel_start[1] && c <= sel_end[1]
                elsif cm_row == sel_start[0]
                  selected = c >= sel_start[1]
                elsif cm_row == sel_end[0]
                  selected = c <= sel_end[1]
                else
                  selected = true
                end
              end
            end

            if cell.multicell.is_a?(Hash)
              flush_run.call
              mc = cell.multicell
              x = px + c * @cell_width
              block_w = mc[:cols] * @cell_width
              block_h = mc[:rows] * @cell_height

              if selected
                ObjC::MSG_VOID.call(@selection_color, ObjC.sel('setFill'))
                ObjC::NSRectFill.call(x, y, block_w, block_h)
              elsif has_bg
                ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
                ObjC::NSRectFill.call(x, y, block_w, block_h)
              end

              if mc[:sixel]
                draw_sixel_image(mc[:sixel], x, y, block_w, block_h)
                next
              end

              next if cell.char == " " && !has_bg

              effective_scale = mc[:scale].to_f
              if mc[:frac_d] > 0 && mc[:frac_n] > 0
                effective_scale *= mc[:frac_n].to_f / mc[:frac_d]
              end
              scaled_font = ObjC.retain(create_nsfont(@font_size * effective_scale, family: mc[:family]))
              regular_scaled_lh = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('defaultLineHeightForFont'))
              if cell.bold
                regular = scaled_font
                scaled_font = ObjC.retain(create_bold_nsfont(regular))
                ObjC.release(regular)
              end

              draw_attrs = {
                ObjC::NSFontAttributeName => scaled_font,
                ObjC::NSForegroundColorAttributeName => fg_color,
              }
              if cell.underline
                draw_attrs[ObjC::NSUnderlineStyleAttributeName] = ObjC.nsnumber_int(1)
              end
              if cell.strikethrough
                draw_attrs[ObjC::NSStrikethroughStyleAttributeName] = ObjC.nsnumber_int(1)
              end
              ns_attrs = ObjC.nsdict(draw_attrs)
              ns_char = cached_nsstring(cell.char)

              text_w = ObjC::MSG_RET_D_1.call(ns_char, ObjC.sel('sizeWithAttributes:'), ns_attrs)

              draw_x = case mc[:halign]
                        when 1 then x + block_w - text_w
                        when 2 then x + (block_w - text_w) / 2.0
                        else x
                        end

              scaled_ascender = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('ascender'))
              scaled_descender = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('descender'))
              scaled_leading = ObjC::MSG_RET_D.call(scaled_font, ObjC.sel('leading'))
              text_h = scaled_ascender - scaled_descender + scaled_leading

              draw_y = case mc[:valign]
                        when 1 then y + block_h - text_h
                        when 2 then y + (block_h - text_h) / 2.0
                        else y
                        end

              draw_dy = draw_y + (regular_scaled_lh - scaled_font.defaultLineHeightForFont)
              ObjC::MSG_VOID_PT_1.call(ns_char, ObjC.sel('drawAtPoint:withAttributes:'), draw_x, draw_dy, ns_attrs)

              ObjC.release(scaled_font)
              next
            end

            if selected
              bg_color = @selection_color
              has_bg = true
            elsif is_current_match
              bg_color = @search_current_color
              has_bg = true
            elsif is_match
              bg_color = @search_match_color
              has_bg = true
            end

            if has_bg
              ObjC::MSG_VOID.call(bg_color, ObjC.sel('setFill'))
              ObjC::NSRectFill.call(px + c * @cell_width, y, cell.width * @cell_width, @cell_height)
            end

            next if cell.char == " "

            cell_font = font_for_char(cell.char)
            if cell.bold && cell_font.to_i == @font.to_i
              cell_font = @bold_font
            elsif cell.italic
              cell_font = create_italic_nsfont(cell_font)
            end

            attrs_hash = {
              ObjC::NSFontAttributeName => cell_font,
              ObjC::NSForegroundColorAttributeName => fg_color,
            }
            if cell.underline
              attrs_hash[ObjC::NSUnderlineStyleAttributeName] = ObjC.nsnumber_int(1)
            end
            if cell.strikethrough
              attrs_hash[ObjC::NSStrikethroughStyleAttributeName] = ObjC.nsnumber_int(1)
            end

            # Run signature to match next adjacent cell styles
            sig = [cell_font.to_i, fg_color.to_i, cell.underline, cell.strikethrough]

            if run_chars.empty?
              run_chars << cell.char
              run_start_c = c
              run_attrs = ObjC.nsdict(attrs_hash)
              run_font = cell_font
              run_sig = sig
            elsif sig == run_sig
              run_chars << cell.char
            else
              flush_run.call
              run_chars << cell.char
              run_start_c = c
              run_attrs = ObjC.nsdict(attrs_hash)
              run_font = cell_font
              run_sig = sig
            end
          end

          flush_run.call

          # Paint cursor if active
          if is_active && screen.cursor_visible && r == screen.cursor_y && !@gui.search_mode
            blink_on = get_from_gui(:@cursor_blink_on)
            if blink_on || copy_mode&.active
              cx = px + screen.cursor_x * @cell_width
              cy = y
              c_width = 1 * @cell_width
              c_height = @cell_height

              cursor_color = copy_mode&.active ? @copy_mode_cursor_color : resolve_color(screen.cursor_color, @default_fg)
              ObjC::MSG_VOID.call(cursor_color, ObjC.sel('setFill'))

              case screen.cursor_style
              when :underline
                ObjC::NSRectFill.call(cx, cy + c_height - 2.0, c_width, 2.0)
              when :bar
                ObjC::NSRectFill.call(cx, cy, 2.0, c_height)
              else # :block
                ObjC::NSRectFill.call(cx, cy, c_width, c_height)
                # Invert block cursor cell char
                if screen.cursor_x < pane_cols
                  ccell = row[screen.cursor_x]
                  if ccell && ccell.char != " "
                    char_font = font_for_char(ccell.char)
                    if ccell.bold && char_font.to_i == @font.to_i
                      char_font = @bold_font
                    elsif ccell.italic
                      char_font = create_italic_nsfont(char_font)
                    end
                    inv_attrs = ObjC.nsdict({
                      ObjC::NSFontAttributeName => char_font,
                      ObjC::NSForegroundColorAttributeName => @default_bg,
                    })
                    ns_char = ObjC.nsstring(ccell.char)
                    ObjC::MSG_VOID_PT_1.call(ns_char, ObjC.sel('drawAtPoint:withAttributes:'), cx, cy + y_offset_for_font(char_font), inv_attrs)
                  end
                end
              end
            end
          end
        end
      end

      def draw_tab_bar(tbh, tby)
        ObjC::MSG_VOID.call(@tab_bg, ObjC.sel('setFill'))
        ObjC::NSRectFill.call(0.0, tby, @cols * @cell_width, tbh)

        tabs = get_from_gui(:@tabs)
        active_tab = get_from_gui(:@active_tab)

        tab_w = (@cols * @cell_width) / [tabs.size, 1].max
        tab_w = [tab_w, 200.0].min

        tabs.each_with_index do |tab, idx|
          tx = idx * tab_w
          bg = (idx == active_tab) ? @tab_active_bg : @tab_bg
          ObjC::MSG_VOID.call(bg, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(tx, tby, tab_w - 1.0, tbh)

          title = tab.title.to_s
          ns_title = ObjC.nsstring(title)
          attrs = ObjC.nsdict({
            ObjC::NSFontAttributeName => @font,
            ObjC::NSForegroundColorAttributeName => @tab_fg,
          })
          title_w = ObjC::MSG_RET_D_1.call(ns_title, ObjC.sel('sizeWithAttributes:'), attrs)
          dx = tx + (tab_w - title_w) / 2.0
          dy = tby + y_offset_for_font(@font)
          # Clip text in rect
          ObjC::MSG_VOID_1.call(ObjC.cls('NSGraphicsContext'), ObjC.sel('saveGraphicsState'))
          path = ObjC::MSG_PTR.call(ObjC.cls('NSBezierPath'), ObjC.sel('bezierPathWithRect:'), tx + 4.0, tby, tab_w - 8.0, tbh)
          ObjC::MSG_VOID.call(path, ObjC.sel('addClip'))
          ObjC::MSG_VOID_PT_1.call(ns_title, ObjC.sel('drawAtPoint:withAttributes:'), dx, dy, attrs)
          ObjC::MSG_VOID_1.call(ObjC.cls('NSGraphicsContext'), ObjC.sel('restoreGraphicsState'))
        end
      end

      def draw_pane_dividers(pane_rects, gy_off)
        ObjC::MSG_VOID.call(@pane_divider_color, ObjC.sel('setFill'))
        pane_rects.each do |rect|
          next if rect[:x] == 0
          div_x = rect[:x] * @cell_width - 1.0
          div_y = gy_off + rect[:y] * @cell_height
          div_h = rect[:h] * @cell_height
          ObjC::NSRectFill.call(div_x, div_y, 1.0, div_h)
        end
        pane_rects.each do |rect|
          next if rect[:y] == 0
          div_x = rect[:x] * @cell_width
          div_y = gy_off + rect[:y] * @cell_height - 1.0
          div_w = rect[:w] * @cell_width
          ObjC::NSRectFill.call(div_x, div_y, div_w, 1.0)
        end
      end

      def draw_active_pane_border(tab, pane_rects, gy_off)
        active_rect = pane_rects.find { |r| r[:pane] == tab.active_pane }
        return unless active_rect
        ax = active_rect[:x] * @cell_width
        ay = gy_off + active_rect[:y] * @cell_height
        aw = active_rect[:w] * @cell_width
        ah = active_rect[:h] * @cell_height

        border_w = 2.0
        border_color = @active_pane_border_color
        ObjC::MSG_VOID.call(border_color, ObjC.sel('setFill'))
        # Top
        ObjC::NSRectFill.call(ax, ay, aw, border_w) if active_rect[:y] > 0
        # Bottom
        ObjC::NSRectFill.call(ax, ay + ah - border_w, aw, border_w) if active_rect[:y] + active_rect[:h] < @rows
        # Left
        ObjC::NSRectFill.call(ax, ay, border_w, ah) if active_rect[:x] > 0
        # Right
        ObjC::NSRectFill.call(ax + aw - border_w, ay, border_w, ah) if active_rect[:x] + active_rect[:w] < @cols
      end

      def draw_sixel_image(sixel, x, y, block_w, block_h)
        @sixel_image_cache ||= {}
        cached = @sixel_image_cache[sixel.object_id]
        unless cached
          rgba_data = sixel.rgba_data
          width     = sixel.width
          height    = sixel.height
          rep = ObjC::MSG_PTR.call(ObjC.cls('NSBitmapImageRep'), ObjC.sel('alloc'))
          rep = ObjC::MSG_PTR_L_L_L_L_L_L_L_L_L.call(
            rep, ObjC.sel('initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:'),
            Fiddle::Pointer.new(0), width, height, 8, 4, 1, 0, ObjC::NSCalibratedRGBColorSpace, width * 4, 32
          )
          bitmap_data = ObjC::MSG_PTR.call(rep, ObjC.sel('bitmapData'))
          bitmap_data[0, rgba_data.bytesize] = rgba_data

          img = ObjC::MSG_PTR.call(ObjC.cls('NSImage'), ObjC.sel('alloc'))
          img = ObjC::MSG_PTR_RECT.call(img, ObjC.sel('initWithSize:'), width.to_f, height.to_f)
          ObjC::MSG_VOID_1.call(img, ObjC.sel('addRepresentation:'), rep)

          @sixel_image_cache[sixel.object_id] = ObjC.retain(img)
          cached = img
        end

        ObjC::MSG_VOID_RECT_RECT_L_D_I_P_I.call(
          cached, ObjC.sel('drawInRect:fromRect:operation:fraction:respectFlipped:hints:'),
          x, y, block_w, block_h, 0.0, 0.0, sixel.width.to_f, sixel.height.to_f,
          2, 1.0, 1, Fiddle::Pointer.new(0)
        )
      end

      def key_down(event_ptr)
        @gui.instance_variable_set(:@current_event, event_ptr)
        chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
        chars = ObjC.to_ruby_string(chars_ns)
        flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))

        # If IME text is pending, delegate it
        if @marked_text
          ObjC::MSG_VOID_1.call(@view, ObjC.sel('interpretKeyEvents:'),
                               ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'), event_ptr))
          return
        end

        tab = @gui.current_tab
        pane = tab.active_pane

        if pane.copy_mode&.active
          copy_mode_key_down(event_ptr, pane)
          return
        end

        if @gui.search_mode
          handle_search_key_down(chars, flags)
          return
        end

        ctrl  = (flags & ObjC::NSEventModifierFlagControl) != 0
        cmd   = (flags & ObjC::NSEventModifierFlagCommand) != 0
        opt   = (flags & ObjC::NSEventModifierFlagOption) != 0
        shift = (flags & ObjC::NSEventModifierFlagShift) != 0

        # Discard Cmd combinations so system shortcuts pass through
        return if cmd

        if opt
          # Option-arrow navigates by word in some shells. Send Esc + arrow-char
          # (translates to Esc-b / Esc-f muscle memory).
          case chars
          when "\u{F702}" # Left
            pane.write_input("\e\u{007F}")
            return
          when "\u{F703}" # Right
            pane.write_input("\e\u{001F}")
            return
          end
        end

        mod = modifier_param(flags)
        if mod > 1 && (seq = map_modified_key(chars, mod))
          pane.write_input(seq)
          return
        end

        # Standard keypad / cursor / F-key dispatch
        seq = map_special_keys(chars, pane.screen.application_cursor_mode,
                               app_keypad: pane.screen.application_keypad_mode)
        if seq != chars
          pane.write_input(seq)
          return
        end

        # Direct string dispatch (normal characters or plain ESC combinations)
        input = ObjC.to_ruby_string(ObjC::MSG_PTR.call(event_ptr, ObjC.sel('characters')))
        if input.empty?
          # Try interpretKeyEvents for dead keys / IME
          ObjC::MSG_VOID_1.call(@view, ObjC.sel('interpretKeyEvents:'),
                               ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'), event_ptr))
        else
          # Translate Opt-key combos to ESC + key for traditional Alt-bindings in shells
          if opt && input.length == 1 && input.ascii_only?
            pane.write_input("\e#{input}")
          else
            pane.write_input(input)
          end
        end
      rescue Errno::EIO, IOError
      end

      def perform_key_equivalent(event_ptr)
        # Discard cmd- combos that we want the menu-bar to handle
        # directly (e.g. Cmd+W, Cmd+T, etc.)
        flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))
        cmd   = (flags & ObjC::NSEventModifierFlagCommand) != 0
        cmd ? 0 : 1
      end

      def copy_mode_key_down(event_ptr, pane)
        chars_ns = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('charactersIgnoringModifiers'))
        chars = ObjC.to_ruby_string(chars_ns)
        flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))
        ctrl = (flags & ObjC::NSEventModifierFlagControl) != 0

        # Translate common shell movement hotkeys inside copy mode
        case
        when chars == "\e" || (ctrl && chars == 'c')
          pane.copy_mode.exit
          pane.copy_mode = nil
        when chars == "\u{F700}" || (ctrl && chars == 'p') # Up
          pane.copy_mode.move_cursor_y(-1)
        when chars == "\u{F701}" || (ctrl && chars == 'n') # Down
          pane.copy_mode.move_cursor_y(1)
        when chars == "\u{F702}" || (ctrl && chars == 'b') # Left
          pane.copy_mode.move_cursor_x(-1)
        when chars == "\u{F703}" || (ctrl && chars == 'f') # Right
          pane.copy_mode.move_cursor_x(1)
        when chars == ' ' # Space: start selection anchor
          pane.copy_mode.toggle_selection
        when chars == "\r" || chars == "\n" # Enter: copy selection and exit
          text = pane.copy_mode.selected_text
          if text && !text.empty?
            set_clipboard(text)
          end
          pane.copy_mode.exit
          pane.copy_mode = nil
        end
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def handle_search_key_down(chars, flags)
        ctrl = (flags & ObjC::NSEventModifierFlagControl) != 0

        case
        when chars == "\e" || (ctrl && chars == 'g')
          @gui.toggle_search
        when chars == "\r" || chars == "\n"
          # Submit search: advance to next or exit search panel
          if (flags & ObjC::NSEventModifierFlagShift) != 0
            @gui.search_prev
          else
            @gui.search_next
          end
        when chars == "\u{007F}" # Backspace
          @gui.search_query.chop!
          @gui.perform_search
        when chars.length == 1 && chars.ascii_only? && !ctrl
          @gui.search_query << chars
          @gui.perform_search
        end
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def ime_insert_text(text_ptr)
        text = nsstring_from_input(text_ptr)
        @gui.current_tab.active_pane.write_input(text)
        @marked_text = nil
        sync_to_gui(:@marked_text, nil)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def ime_do_command
        # Let interpretKeyEvents handle key equivalent
        event = get_from_gui(:@current_event)
        return unless event
        key_down(event)
      end

      def ime_set_marked_text(text_ptr, _sel_loc, _sel_len)
        @marked_text = nsstring_from_input(text_ptr)
        sync_to_gui(:@marked_text, @marked_text)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def ime_unmark_text
        @marked_text = nil
        sync_to_gui(:@marked_text, nil)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def ime_has_marked_text
        @marked_text ? 1 : 0
      end

      def ime_marked_range_location
        # Return length of marked text as NSRange
        @marked_text ? @marked_text.length : 0
      end

      def timer_fired
        blink_counter = get_from_gui(:@cursor_blink_counter) || 0
        blink_counter += 1
        sync_to_gui(:@cursor_blink_counter, blink_counter)

        if blink_counter >= 30
          sync_to_gui(:@cursor_blink_counter, 0)
          blink_on = get_from_gui(:@cursor_blink_on)
          sync_to_gui(:@cursor_blink_on, !blink_on)
          ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        end

        bell_flash = get_from_gui(:@bell_flash) || 0
        if bell_flash > 0
          bell_flash -= 1
          sync_to_gui(:@bell_flash, bell_flash)
          ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
        end
      end

      def invalidate_dirty_rows(dirty_rows)
        return unless @view
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def scroll_wheel(event_ptr)
        dy = ObjC::MSG_RET_D.call(event_ptr, ObjC.sel('scrollingDeltaY'))
        # If precision scrolling (trackpad), accumulate deltas
        @scroll_accum ||= 0.0
        @scroll_accum += dy
        lines = (@scroll_accum / 10.0).to_i
        return if lines == 0
        @scroll_accum -= lines * 10.0

        tab = @gui.current_tab
        pane = tab.active_pane
        screen = pane.screen
        scrollback_size = screen.scrollback.size

        # Invert delta sign so scroll-down scrolls back
        pane.scroll_offset += lines
        pane.scroll_offset = pane.scroll_offset.clamp(0, scrollback_size)

        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def mouse_down(event_ptr)
        x, y = event_location(event_ptr)
        click_count = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('clickCount'))
        flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))

        tab = @gui.current_tab
        gy_off = @gui.grid_y_offset
        tbh = @gui.tab_bar_height

        # Tab bar clicks
        if tbh > 0 && y >= @gui.tab_bar_y && y < @gui.tab_bar_y + tbh
          tab_w = (@cols * @cell_width) / [@gui.tabs.size, 1].max
          tab_w = [tab_w, 200.0].min
          idx = (x / tab_w).to_i
          if idx >= 0 && idx < @gui.tabs.size
            @gui.instance_variable_set(:@active_tab, idx)
            ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
          end
          return
        end

        # Pane selection and coordinate mapping
        pane_rects = tab.pane_tree.layout(0, 0, @cols, @rows)
        active_rect = pane_rects.find do |rect|
          px = rect[:x] * @cell_width
          py = gy_off + rect[:y] * @cell_height
          pw = rect[:w] * @cell_width
          ph = rect[:h] * @cell_height
          x >= px && x < px + pw && y >= py && y < py + ph
        end

        if active_rect
          tab.active_pane = active_rect[:pane]
          pane = active_rect[:pane]
          px = active_rect[:x] * @cell_width
          py = gy_off + active_rect[:y] * @cell_height

          col = ((x - px) / @cell_width).to_i.clamp(0, active_rect[:w] - 1)
          row = ((y - py) / @cell_height).to_i.clamp(0, active_rect[:h] - 1)

          abs_row = pane.screen.scrollback.size + row - pane.scroll_offset

          shift = (flags & ObjC::NSEventModifierFlagShift) != 0

          # Double-click selects word
          if click_count == 2
            word_bounds = @gui.word_boundaries_in_row(@gui.row_at(tab, abs_row), col)
            if word_bounds
              sync_to_gui(:@selection_anchor, [abs_row, word_bounds[0]])
              sync_to_gui(:@selection_end, [abs_row, word_bounds[1]])
              sync_to_gui(:@selection_word_anchor, [abs_row, word_bounds[0], word_bounds[1]])
            end
          else
            sync_to_gui(:@selection_word_anchor, nil)
            if shift && get_from_gui(:@selection_anchor)
              sync_to_gui(:@selection_end, [abs_row, col])
            else
              sync_to_gui(:@selection_anchor, [abs_row, col])
              sync_to_gui(:@selection_end, [abs_row, col])
            end
          end

          # If mouse reporting is active, dispatch to child process
          if pane.screen.mouse_reporting_active? && !shift
            btn = click_count == 2 ? 3 : 0 # mouse-down SGR button 0
            send_mouse_event(tab, btn, col, row)
          end
        end

        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def mouse_dragged(event_ptr)
        x, y = event_location(event_ptr)
        tab = @gui.current_tab
        gy_off = @gui.grid_y_offset

        pane_rects = tab.pane_tree.layout(0, 0, @cols, @rows)
        active_rect = pane_rects.find { |r| r[:pane] == tab.active_pane }
        return unless active_rect

        px = active_rect[:x] * @cell_width
        py = gy_off + active_rect[:y] * @cell_height

        col = ((x - px) / @cell_width).to_i.clamp(0, active_rect[:w] - 1)
        row = ((y - py) / @cell_height).to_i.clamp(0, active_rect[:h] - 1)

        pane = active_rect[:pane]
        abs_row = pane.screen.scrollback.size + row - pane.scroll_offset

        flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))
        shift = (flags & ObjC::NSEventModifierFlagShift) != 0

        if pane.screen.mouse_reporting_active? && !shift
          send_mouse_event(tab, 32, col, row) # drag button 32
        else
          word_anchor = get_from_gui(:@selection_word_anchor)
          if word_anchor
            # Expand word selection
            extend_word_drag_selection(tab, [abs_row, col])
          else
            sync_to_gui(:@selection_end, [abs_row, col])
          end
        end

        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def extend_word_drag_selection(tab, pointer_pos)
        anchor = get_from_gui(:@selection_anchor)
        word_anchor = get_from_gui(:@selection_word_anchor)
        return unless anchor && word_anchor

        w_row, w_sc, w_ec = word_anchor
        pr, pc = pointer_pos

        row = @gui.row_at(tab, pr)
        return unless row

        word_bounds = @gui.word_boundaries_in_row(row, pc)
        return unless word_bounds

        if pr < w_row || (pr == w_row && pc < w_sc)
          sync_to_gui(:@selection_anchor, [pr, word_bounds[0]])
          sync_to_gui(:@selection_end, [w_row, w_ec])
        else
          sync_to_gui(:@selection_anchor, [w_row, w_sc])
          sync_to_gui(:@selection_end, [pr, word_bounds[1]])
        end
      end

      def mouse_up(event_ptr)
        x, y = event_location(event_ptr)
        tab = @gui.current_tab
        gy_off = @gui.grid_y_offset

        pane_rects = tab.pane_tree.layout(0, 0, @cols, @rows)
        active_rect = pane_rects.find { |r| r[:pane] == tab.active_pane }
        return unless active_rect

        pane = active_rect[:pane]
        px = active_rect[:x] * @cell_width
        py = gy_off + active_rect[:y] * @cell_height
        col = ((x - px) / @cell_width).to_i.clamp(0, active_rect[:w] - 1)
        row = ((y - py) / @cell_height).to_i.clamp(0, active_rect[:h] - 1)

        flags = ObjC::MSG_RET_L.call(event_ptr, ObjC.sel('modifierFlags'))
        shift = (flags & ObjC::NSEventModifierFlagShift) != 0

        if pane.screen.mouse_reporting_active? && !shift
          send_mouse_event(tab, 3, col, row, release: true) # release button 3
        else
          # Text selection copy on release (similar to macOS terminal behavior)
          anchor = get_from_gui(:@selection_anchor)
          sel_end = get_from_gui(:@selection_end)
          if anchor && sel_end && anchor != sel_end
            start_p, end_p = [anchor, sel_end].sort_by { |p| [p[0], p[1]] }
            text = @gui.selected_text_from_buffer(start_p[0], start_p[1], end_p[0], end_p[1])
            if text && !text.empty?
              set_clipboard(text)
            end
          end
        end

        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def mouse_moved(event_ptr)
        x, y = event_location(event_ptr)
        tab = @gui.current_tab
        gy_off = @gui.grid_y_offset

        pane_rects = tab.pane_tree.layout(0, 0, @cols, @rows)
        active_rect = pane_rects.find { |r| r[:pane] == tab.active_pane }
        return unless active_rect

        pane = active_rect[:pane]
        px = active_rect[:x] * @cell_width
        py = gy_off + active_rect[:y] * @cell_height
        col = ((x - px) / @cell_width).to_i.clamp(0, active_rect[:w] - 1)
        row = ((y - py) / @cell_height).to_i.clamp(0, active_rect[:h] - 1)

        if pane.screen.mouse_reporting_active?
          # mouse moved is generally button 35 (or SGR passive moved)
          # but we only send if mouse tracking is enabled
          if pane.screen.mouse_encoding == :sgr
            send_mouse_event(tab, 35, col, row)
          end
        end
      end

      def right_mouse_down(event_ptr)
        # Mouse reporting support
      end

      def right_mouse_dragged(event_ptr)
      end

      def right_mouse_up(event_ptr)
      end

      def other_mouse_down(event_ptr)
      end

      def other_mouse_dragged(event_ptr)
      end

      def other_mouse_up(event_ptr)
      end

      def handle_resize(w, h)
        return if w == 0 || h == 0
        new_cols = (w / @cell_width).floor - 1
        new_rows = ((h - @gui.tab_bar_height) / @cell_height).floor - 1
        new_cols = [new_cols, 20].max
        new_rows = [new_rows, 5].max

        @cols = new_cols
        @rows = new_rows
        sync_to_gui(:@cols, @cols)
        sync_to_gui(:@rows, @rows)

        @gui.tabs.each do |tab|
          tab.resize(new_cols, new_rows)
        end
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def window_focus_changed(focused)
        @window_focused = focused
        sync_to_gui(:@window_focused, @window_focused)
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def apply_profile(name)
        profile = Echoes.config.all_profiles[name]
        return unless profile

        @gui.instance_variable_set(:@active_profile, profile)
        @gui.instance_variable_set(:@colors, @gui.send(:build_color_table))
        @default_fg = make_color(*profile.foreground)
        @default_bg = make_color(*profile.background)
        @selection_color = make_color(*profile.selection_color)

        sync_to_gui(:@default_fg, @default_fg)
        sync_to_gui(:@default_bg, @default_bg)
        sync_to_gui(:@selection_color, @selection_color)

        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def update_font(size, persist: true)
        @font_size = size
        sync_to_gui(:@font_size, @font_size)
        Preferences.write_double(:font_size, size) if persist

        old_font = @font
        old_bold = @bold_font

        @font = ObjC.retain(create_nsfont(@font_size))
        @bold_font = ObjC.retain(create_bold_nsfont(@font))

        sync_to_gui(:@font, @font)
        sync_to_gui(:@bold_font, @bold_font)

        ObjC.release(old_font) if old_font
        ObjC.release(old_bold) if old_bold

        @font_y_offset_cache = {}
        update_cell_metrics

        # Trigger window resize / recalculate
        if @window
          _, _, w, h = nsrect_via_invocation(@window, 'frame')
          handle_resize(w, h)
        end
      end

      def show_about_panel
        # Standard AppKit About Panel
        dict = ObjC.nsdict({
          ObjC.nsstring('ApplicationName') => ObjC.nsstring('Echoes'),
          ObjC.nsstring('ApplicationVersion') => ObjC.nsstring(Echoes::VERSION),
          ObjC.nsstring('Copyright') => ObjC.nsstring('© 2026 DeepMind / Echoes Contributors'),
        })
        ObjC::MSG_VOID_1.call(@app, ObjC.sel('orderFrontStandardAboutPanelWithOptions:'), dict)
      end

      def select_all
        # Trigger full buffer selection
        tab = @gui.current_tab
        screen = tab.screen
        scrollback_size = screen.scrollback.size
        sync_to_gui(:@selection_anchor, [0, 0])
        sync_to_gui(:@selection_end, [scrollback_size + screen.rows - 1, @cols - 1])
        ObjC::MSG_VOID_I.call(@view, ObjC.sel('setNeedsDisplay:'), 1)
      end

      def prompt_for_file_to_edit
        panel = ObjC::MSG_PTR.call(ObjC.cls('NSOpenPanel'), ObjC.sel('openPanel'))
        ObjC::MSG_VOID_I.call(panel, ObjC.sel('setCanChooseFiles:'), 1)
        ObjC::MSG_VOID_I.call(panel, ObjC.sel('setCanChooseDirectories:'), 0)
        ObjC::MSG_VOID_I.call(panel, ObjC.sel('setAllowsMultipleSelection:'), 0)

        result = ObjC::MSG_RET_L.call(panel, ObjC.sel('runModal'))
        return nil if result != 1 # NSModalResponseOK

        url = ObjC::MSG_PTR.call(panel, ObjC.sel('URL'))
        return nil if url.nil? || url.null?
        path_ns = ObjC::MSG_PTR.call(url, ObjC.sel('path'))
        ObjC.to_ruby_string(path_ns)
      end

      def completion_picked(sender)
        # Handle tab completion menu picker tag
        tag = ObjC::MSG_RET_L.call(sender, ObjC.sel('tag'))
        # completion popup index selected
      end

      def perform_drag_operation(sender)
        pb = ObjC::MSG_PTR.call(sender, ObjC.sel('draggingPasteboard'))
        paths = file_paths_from_pasteboard(pb)
        return false unless paths

        # Write pasted filepath to shell active pane
        @gui.current_tab.active_pane.write_input(paths)
        true
      end

      def file_paths_from_pasteboard(pb)
        nsurl_class = ObjC.cls('NSURL')
        class_array = ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'), nsurl_class)
        urls = ObjC::MSG_PTR_2.call(pb, ObjC.sel('readObjectsForClasses:options:'), class_array, Fiddle::Pointer.new(0))
        return nil if urls.null?

        count = ObjC::MSG_RET_L.call(urls, ObjC.sel('count'))
        return nil if count == 0

        paths = count.times.map do |i|
          url = ObjC::MSG_PTR_L.call(urls, ObjC.sel('objectAtIndex:'), i)
          ns_path = ObjC::MSG_PTR.call(url, ObjC.sel('path'))
          ObjC.to_ruby_string(ns_path).shellescape
        end
        paths.join(' ')
      end

      private

      def sync_to_gui(var_name, val)
        @gui.instance_variable_set(var_name, val)
      end

      def get_from_gui(var_name)
        @gui.instance_variable_get(var_name)
      end

      def cols; @cols; end
      def rows; @rows; end
      def font_size; @font_size; end
      def view; @view; end

      def create_nsfont(size, family: nil)
        family ||= Echoes.config.font_family
        if family
          font = ObjC::MSG_PTR_1D.call(
            ObjC.cls('NSFont'), ObjC.sel('fontWithName:size:'),
            ObjC.nsstring(family), size
          )
          return font if font && font.to_i != 0
        end
        ObjC::MSG_PTR_2D.call(
          ObjC.cls('NSFont'), ObjC.sel('monospacedSystemFontOfSize:weight:'),
          size, 0.0
        )
      end

      def update_cell_metrics
        if Echoes.config.font_family
          attrs = ObjC.nsdict({ObjC::NSFontAttributeName => @font})
          ns_m = ObjC.nsstring("M")
          @cell_width = ObjC::MSG_RET_D_1.call(ns_m, ObjC.sel('sizeWithAttributes:'), attrs)
        else
          @cell_width = ObjC::MSG_RET_D.call(@font, ObjC.sel('maximumAdvancement'))
        end
        ascender = ObjC::MSG_RET_D.call(@font, ObjC.sel('ascender'))
        descender = ObjC::MSG_RET_D.call(@font, ObjC.sel('descender'))
        leading = ObjC::MSG_RET_D.call(@font, ObjC.sel('leading'))
        @cell_height = ascender - descender + leading
        @font_default_line_height = ObjC::MSG_RET_D.call(@font, ObjC.sel('defaultLineHeightForFont'))
        @font_default_ascender = ascender
        @font_default_family = ObjC.to_ruby_string(ObjC::MSG_PTR.call(@font, ObjC.sel('familyName')))

        sync_to_gui(:@cell_width, @cell_width)
        sync_to_gui(:@cell_height, @cell_height)
        sync_to_gui(:@font_default_line_height, @font_default_line_height)
        sync_to_gui(:@font_default_ascender, @font_default_ascender)
        sync_to_gui(:@font_default_family, @font_default_family)

        # Propagate
        window_states = get_from_gui(:@window_states)
        window_states.each do |ws|
          ws[:tabs]&.each do |tab|
            tab.panes.each { |pane| @gui.wire_screen_handlers(pane) }
          end
        end
      end

      def create_bold_nsfont(font)
        fm = ObjC::MSG_PTR.call(ObjC.cls('NSFontManager'), ObjC.sel('sharedFontManager'))
        ObjC::MSG_PTR_1L.call(fm, ObjC.sel('convertFont:toHaveTrait:'), font, 0x2)
      end

      def create_italic_nsfont(font)
        @italic_font_cache ||= {}
        cached = @italic_font_cache[font.to_i]
        return cached if cached
        fm = ObjC::MSG_PTR.call(ObjC.cls('NSFontManager'), ObjC.sel('sharedFontManager'))
        italic = ObjC::MSG_PTR_1L.call(fm, ObjC.sel('convertFont:toHaveTrait:'), font, 0x1)
        @italic_font_cache[font.to_i] = ObjC.retain(italic)
      end

      def font_for_char(char)
        return @font if char.ascii_only?

        cached = @font_cache[char]
        return cached if cached

        ns_str = ObjC.nsstring(char)
        ns_len = ObjC::MSG_RET_L.call(ns_str, ObjC.sel('length'))
        fallback = ObjC::CTFontCreateForString.call(@font, ns_str, 0, ns_len)
        if fallback.to_i == @font.to_i
          @font_cache[char] = @font
        else
          @font_cache[char] = ObjC.retain(fallback)
        end
        @font_cache[char]
      end

      def y_offset_for_font(font)
        return 0.0 if font.to_i == @font.to_i
        cached = @font_y_offset_cache[font.to_i]
        return cached if cached
        font_family = ObjC.to_ruby_string(ObjC::MSG_PTR.call(font, ObjC.sel('familyName')))
        offset =
          if font_family == @font_default_family
            font_lh = ObjC::MSG_RET_D.call(font, ObjC.sel('defaultLineHeightForFont'))
            @font_default_line_height - font_lh
          else
            font_ascender = ObjC::MSG_RET_D.call(font, ObjC.sel('ascender'))
            @font_default_ascender - font_ascender
          end
        @font_y_offset_cache[font.to_i] = offset
      end

      def build_color_table
        ansi_rgb = [
          [0.0,  0.0,  0.0],
          [0.8,  0.0,  0.0],
          [0.0,  0.8,  0.0],
          [0.8,  0.8,  0.0],
          [0.0,  0.0,  0.8],
          [0.8,  0.0,  0.8],
          [0.0,  0.8,  0.8],
          [0.75, 0.75, 0.75],
          [0.5,  0.5,  0.5],
          [1.0,  0.0,  0.0],
          [0.0,  1.0,  0.0],
          [1.0,  1.0,  0.0],
          [0.0,  0.0,  1.0],
          [1.0,  0.0,  1.0],
          [0.0,  1.0,  1.0],
          [1.0,  1.0,  1.0],
        ]

        active_profile = get_from_gui(:@active_profile)
        if (palette = active_profile&.color_palette)
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

      def send_mouse_event(tab, button, col, row, release: false)
        cx = col + 1
        cy = row + 1
        if tab.screen.mouse_encoding == :sgr
          final = release ? 'm' : 'M'
          tab.write_input("\e[<#{button};#{cx};#{cy}#{final}")
        else
          tab.write_input("\e[M#{(button + 32).chr}#{(cx + 32).chr}#{(cy + 32).chr}")
        end
      rescue Errno::EIO, IOError
      end

      def resolve_color(val, default)
        case val
        when nil then default
        when Integer then @colors[val]
        when Array
          key = (val[0] << 16) | (val[1] << 8) | val[2]
          @rgb_color_cache[key] ||= make_color(val[0] / 255.0, val[1] / 255.0, val[2] / 255.0)
        else default
        end
      end

      def make_color_with_alpha(color, alpha)
        ObjC::MSG_PTR_D.call(color, ObjC.sel('colorWithAlphaComponent:'), alpha)
      end

      def cached_nsstring(str)
        @nsstring_cache[str] ||= ObjC.retain(ObjC.nsstring(str))
      end

      def nsstring_from_input(obj_ptr)
        is_attr = ObjC::MSG_PTR_1.call(obj_ptr, ObjC.sel('isKindOfClass:'), ObjC.cls('NSAttributedString'))
        if is_attr.to_i != 0
          ns_str = ObjC::MSG_PTR.call(obj_ptr, ObjC.sel('string'))
          ObjC.to_ruby_string(ns_str)
        else
          ObjC.to_ruby_string(obj_ptr)
        end
      end

      def make_color(r, g, b, a = 1.0)
        ObjC.retain(ObjC::MSG_PTR_4D.call(
          ObjC.cls('NSColor'), ObjC.sel('colorWithRed:green:blue:alpha:'),
          r, g, b, a
        ))
      end

      def draw_pane_background(spec, px, py, pane_cols, pane_rows)
        colors = spec[:colors]
        return if !colors || colors.empty?
        w = pane_cols * @cell_width
        h = pane_rows * @cell_height

        case spec[:type]
        when :flat
          rgba  = colors.first
          color = make_color(*rgba)
          ObjC::MSG_VOID.call(color, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(px, py, w, h)
          ObjC.release(color)
        when :linear
          return if colors.size < 2
          start_rgba = colors.first
          end_rgba   = colors.last
          ns_start = make_color(*start_rgba)
          ns_end   = make_color(*end_rgba)
          alloc = ObjC::MSG_PTR.call(ObjC.cls('NSGradient'), ObjC.sel('alloc'))
          gradient = ObjC::MSG_PTR_2.call(alloc, ObjC.sel('initWithStartingColor:endingColor:'),
                                          ns_start, ns_end)

          ObjC::MSG_VOID_RECT_D.call(gradient, ObjC.sel('drawInRect:angle:'),
                                     px, py, w, h, spec[:angle].to_f)

          ObjC.release(gradient)
          ObjC.release(ns_start)
          ObjC.release(ns_end)
        end
      end

      def draw_pane_fills(fills, px, py, pane_cols, pane_rows)
        fills.each do |fill|
          rect  = fill[:rect]
          rgba  = fill[:color]
          next unless rect && rgba && rect.size == 4
          r1, c1, r2, c2 = rect
          r1 = r1.clamp(0, pane_rows - 1)
          r2 = r2.clamp(0, pane_rows - 1)
          c1 = c1.clamp(0, pane_cols - 1)
          c2 = c2.clamp(0, pane_cols - 1)
          next if r1 > r2 || c1 > c2

          x = px + c1 * @cell_width
          y = py + r1 * @cell_height
          w = (c2 - c1 + 1) * @cell_width
          h = (r2 - r1 + 1) * @cell_height

          ns = make_color(*rgba)
          ObjC::MSG_VOID.call(ns, ObjC.sel('setFill'))
          ObjC::NSRectFill.call(x, y, w, h)
          ObjC.release(ns)
        end
      end

      def view_frame_height
        buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
        sig = ObjC::MSG_PTR_1.call(ObjC.cls('NSView'), ObjC.sel('instanceMethodSignatureForSelector:'), ObjC.sel('frame'))
        inv = ObjC::MSG_PTR_1.call(ObjC.cls('NSInvocation'), ObjC.sel('invocationWithMethodSignature:'), sig)
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('setSelector:'), ObjC.sel('frame'))
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('invokeWithTarget:'), @view)
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('getReturnValue:'), buf)
        buf[0, 32].unpack('d4')[3]
      end

      def event_location(event_ptr)
        event_class = ObjC::MSG_PTR.call(event_ptr, ObjC.sel('class'))
        sig = ObjC::MSG_PTR_1.call(
          event_class, ObjC.sel('instanceMethodSignatureForSelector:'),
          ObjC.sel('locationInWindow')
        )
        inv = ObjC::MSG_PTR_1.call(
          ObjC.cls('NSInvocation'), ObjC.sel('invocationWithMethodSignature:'), sig
        )
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('setSelector:'), ObjC.sel('locationInWindow'))
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('invokeWithTarget:'), event_ptr)
        buf = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('getReturnValue:'), buf)
        buf[0, 16].unpack('dd')
      end

      def measure_glyph(text, family, scale, frac_n, frac_d)
        effective_scale = scale.to_f
        if frac_d > 0 && frac_n > 0
          effective_scale *= frac_n.to_f / frac_d.to_f
        end
        font = ObjC.retain(create_nsfont(@font_size * effective_scale, family: family))
        ns = ObjC.nsstring(text)
        attrs = ObjC.nsdict(ObjC::NSFontAttributeName => font)
        width = ObjC::MSG_RET_D_1.call(ns, ObjC.sel('sizeWithAttributes:'), attrs)
        ObjC.release(font)
        width
      end

      def display_info_json(pane)
        screens = ObjC::MSG_PTR.call(ObjC.cls('NSScreen'), ObjC.sel('screens'))
        return '[]' if screens.nil? || screens.null?
        count = ObjC::MSG_RET_L.call(screens, ObjC.sel('count'))

        main_screen = ObjC::MSG_PTR.call(ObjC.cls('NSScreen'), ObjC.sel('mainScreen'))
        win_screen = nsscreen_for_pane(pane)

        entries = []
        count.times do |i|
          s = ObjC::MSG_PTR_L.call(screens, ObjC.sel('objectAtIndex:'), i)
          _, _, w, h = nsrect_via_invocation(s, 'frame')
          entries << {
            'index'   => i,
            'w'       => w.to_i,
            'h'       => h.to_i,
            'primary' => s.to_i == main_screen.to_i,
            'current' => win_screen && s.to_i == win_screen.to_i,
          }
        end
        JSON.generate(entries)
      rescue StandardError => e
        warn "echoes display-info: #{e.class}: #{e.message}"
        '[]'
      end

      def nsscreen_for_pane(pane)
        window_states = get_from_gui(:@window_states)
        ws = window_states.find { |w| w[:tabs]&.any? { |t| t.panes.include?(pane) } }
        return nil unless ws && ws[:nswindow]
        ObjC::MSG_PTR.call(ws[:nswindow], ObjC.sel('screen'))
      end

      def nsrect_via_invocation(target, sel_name)
        target_class = ObjC::MSG_PTR.call(target, ObjC.sel('class'))
        sig = ObjC::MSG_PTR_1.call(
          target_class, ObjC.sel('instanceMethodSignatureForSelector:'),
          ObjC.sel(sel_name)
        )
        inv = ObjC::MSG_PTR_1.call(
          ObjC.cls('NSInvocation'), ObjC.sel('invocationWithMethodSignature:'), sig
        )
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('setSelector:'), ObjC.sel(sel_name))
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('invokeWithTarget:'), target)
        buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
        ObjC::MSG_VOID_1.call(inv, ObjC.sel('getReturnValue:'), buf)
        buf[0, 32].unpack('dddd')
      end

      def child_env_for_open_window
        env = ENV.to_h
        env['PATH']  = merge_path(env['PATH'])
        env['HOME']  = ENV['HOME'] || Dir.home
        env['USER']  ||= (ENV['LOGNAME'] || `id -un 2>/dev/null`.chomp)
        env['LANG']  ||= 'en_US.UTF-8'
        env['TERM']  ||= Echoes.config.term
        env
      end

      def merge_path(parent_path)
        seen = {}
        out  = []
        (parent_path.to_s.split(':') + DEFAULT_PATH_DIRS).each do |dir|
          next if dir.empty? || seen[dir]
          seen[dir] = true
          out << dir
        end
        out.join(':')
      end

      def open_window_from_osc(pane, args_str)
        params = {}
        args_str.to_s.split(':').each do |pair|
          k, v = pair.split('=', 2)
          next if k.nil? || k.empty? || v.nil?
          params[k] = v
        end

        display_index = (params['display'] || '0').to_i
        fullscreen    = params['fullscreen'] == 'yes'
        program_b64   = params['program']
        return unless program_b64

        json_str = program_b64.delete("\r\n\t ").unpack1('m0')
        argv = JSON.parse(json_str)
        return unless argv.is_a?(Array) && !argv.empty?

        open_external_window(argv: argv, display_index: display_index, fullscreen: fullscreen)
      rescue StandardError => e
        warn "echoes open-window: #{e.class}: #{e.message}"
      end

      def open_external_window(argv:, display_index:, fullscreen:)
        @gui.send(:save_window_state)

        screens = ObjC::MSG_PTR.call(ObjC.cls('NSScreen'), ObjC.sel('screens'))
        count = ObjC::MSG_RET_L.call(screens, ObjC.sel('count'))
        return if display_index < 0 || display_index >= count
        target = ObjC::MSG_PTR_L.call(screens, ObjC.sel('objectAtIndex:'), display_index)

        rect_sel = fullscreen ? 'frame' : 'visibleFrame'
        sx, sy, sw, sh = nsrect_via_invocation(target, rect_sel)

        cols = (sw / @cell_width).floor
        rows = (sh / @cell_height).floor
        cols = [cols, 20].max
        rows = [rows, 5].max

        tab = Tab.new(command: argv, rows: rows, cols: cols, embedded: false,
                      env: child_env_for_open_window)
        tab.title = File.basename(argv.first.to_s)
        tab.panes.each { |pn| @gui.wire_screen_handlers(pn) }

        style_mask = fullscreen ? 0 : ObjC::NSWindowStyleMaskDefault
        new_window = ObjC::MSG_PTR.call(ObjC.cls('NSWindow'), ObjC.sel('alloc'))
        new_window = ObjC::MSG_PTR_RECT_L_L_I.call(
          new_window, ObjC.sel('initWithContentRect:styleMask:backing:defer:'),
          sx, sy, sw, sh, style_mask, ObjC::NSBackingStoreBuffered, 0
        )
        ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setTitle:'), ObjC.nsstring(tab.title))
        ObjC::MSG_VOID_L.call(new_window, ObjC.sel('setCollectionBehavior:'), 1 << 7)
        ObjC::MSG_VOID_I.call(new_window, ObjC.sel('setAcceptsMouseMovedEvents:'), 1)
        if fullscreen
          ObjC::MSG_VOID_L.call(new_window, ObjC.sel('setLevel:'), 25)
        end

        new_view = ObjC::MSG_PTR.call(@view_class, ObjC.sel('alloc'))
        new_view = ObjC::MSG_PTR_RECT.call(new_view, ObjC.sel('initWithFrame:'),
                                            0.0, 0.0, sw, sh)
        drag_types = ObjC::MSG_PTR_1.call(ObjC.cls('NSArray'), ObjC.sel('arrayWithObject:'),
                                           ObjC::NSPasteboardTypeFileURL)
        ObjC::MSG_VOID_1.call(new_view, ObjC.sel('registerForDraggedTypes:'), drag_types)

        ObjC::MSG_VOID_1.call(new_window, ObjC.sel('setContentView:'), new_view)
        ObjC::MSG_VOID_1.call(new_window, ObjC.sel('makeKeyAndOrderFront:'), @app)
        ObjC::MSG_VOID_1.call(new_window, ObjC.sel('makeFirstResponder:'), new_view)
        ObjC::MSG_VOID_I.call(@app, ObjC.sel('activateIgnoringOtherApps:'), 1)

        nc = ObjC::MSG_PTR.call(ObjC.cls('NSNotificationCenter'), ObjC.sel('defaultCenter'))
        ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
          new_view, ObjC.sel('windowDidBecomeKey:'),
          ObjC.nsstring('NSWindowDidBecomeKeyNotification'), new_window)
        ObjC::MSG_VOID_4.call(nc, ObjC.sel('addObserver:selector:name:object:'),
          new_view, ObjC.sel('windowDidResignKey:'),
          ObjC.nsstring('NSWindowDidResignKeyNotification'), new_window)

        @window = new_window
        @view = new_view
        sync_to_gui(:@window, @window)
        sync_to_gui(:@view, @view)

        @tabs = [tab]
        sync_to_gui(:@tabs, @tabs)
        @active_tab = 0
        sync_to_gui(:@active_tab, @active_tab)

        @search_mode = false
        @search_query = +""
        @search_matches = []
        @search_index = -1
        @search_regex_mode = false
        @search_case_insensitive = false
        @bell_flash = 0
        @marked_text = nil
        @current_event = nil
        @selection_anchor = nil
        @selection_end = nil
        @selection_word_anchor = nil
        @window_focused = true

        sync_to_gui(:@search_mode, @search_mode)
        sync_to_gui(:@search_query, @search_query)
        sync_to_gui(:@search_matches, @search_matches)
        sync_to_gui(:@search_index, @search_index)
        sync_to_gui(:@search_regex_mode, @search_regex_mode)
        sync_to_gui(:@search_case_insensitive, @search_case_insensitive)
        sync_to_gui(:@bell_flash, @bell_flash)
        sync_to_gui(:@marked_text, @marked_text)
        sync_to_gui(:@current_event, @current_event)
        sync_to_gui(:@selection_anchor, @selection_anchor)
        sync_to_gui(:@selection_end, @selection_end)
        sync_to_gui(:@selection_word_anchor, @selection_word_anchor)
        sync_to_gui(:@window_focused, @window_focused)

        window_states = get_from_gui(:@window_states)
        view_to_ws = get_from_gui(:@view_to_ws)

        ws = {}
        window_states << ws
        view_to_ws[@view.to_i] = ws

        sync_to_gui(:@window_states, window_states)
        sync_to_gui(:@view_to_ws, view_to_ws)

        @gui.send(:save_window_state)
      end

      def capture_pane_to_png(pane, path)
        return unless @view
        tab = @gui.current_tab
        return unless tab
        rect_info = tab.pane_tree.layout(0, 0, @cols, @rows).find { |r| r[:pane] == pane }
        return unless rect_info

        gy = @gui.grid_y_offset
        px = rect_info[:x] * @cell_width
        py = gy + rect_info[:y] * @cell_height
        pw = rect_info[:w] * @cell_width
        ph = rect_info[:h] * @cell_height

        bytes =
          case @gui.class.capture_format_for(path)
          when :png then png_bytes_for_view_rect(px, py, pw, ph)
          else           pdf_bytes_for_view_rect(px, py, pw, ph)
          end
        return unless bytes
        File.binwrite(path, bytes)
      rescue => e
        warn "echoes capture: #{e.class}: #{e.message}"
      end

      def pdf_bytes_for_view_rect(px, py, pw, ph)
        data = ObjC::MSG_PTR_RECT.call(
          @view, ObjC.sel('dataWithPDFInsideRect:'),
          px, py, pw, ph
        )
        return nil if data.nil? || data.null?
        length    = ObjC::MSG_RET_L.call(data, ObjC.sel('length'))
        bytes_ptr = ObjC::MSG_PTR.call(data, ObjC.sel('bytes'))
        bytes_ptr.to_str(length)
      end

      def png_bytes_for_view_rect(px, py, pw, ph)
        rep = ObjC::MSG_PTR_RECT.call(
          @view, ObjC.sel('bitmapImageRepForCachingDisplayInRect:'),
          px, py, pw, ph
        )
        return nil if rep.nil? || rep.null?
        ObjC::MSG_VOID_RECT_1.call(
          @view, ObjC.sel('cacheDisplayInRect:toBitmapImageRep:'),
          px, py, pw, ph, rep
        )
        empty_dict = ObjC.nsdict({})
        data = ObjC::MSG_PTR_L_1.call(
          rep, ObjC.sel('representationUsingType:properties:'),
          NS_BITMAP_IMAGE_FILE_TYPE_PNG, empty_dict
        )
        return nil if data.nil? || data.null?
        length    = ObjC::MSG_RET_L.call(data, ObjC.sel('length'))
        bytes_ptr = ObjC::MSG_PTR.call(data, ObjC.sel('bytes'))
        bytes_ptr.to_str(length)
      end

      def close_current_window
        closing_view = @view
        window_states = get_from_gui(:@window_states)
        view_to_ws = get_from_gui(:@view_to_ws)

        ws = view_to_ws[closing_view.to_i]
        view_to_ws.delete(closing_view.to_i)
        window_states.delete(ws)
        ObjC::MSG_VOID_1.call(@window, ObjC.sel('orderOut:'), Fiddle::Pointer.new(0))

        sync_to_gui(:@window_states, window_states)
        sync_to_gui(:@view_to_ws, view_to_ws)

        if window_states.empty?
          ObjC::MSG_VOID_1.call(@app, ObjC.sel('terminate:'), Fiddle::Pointer.new(0))
          return
        end

        @gui.send(:load_window_state, window_states.last)

        # Retrieve newly loaded window state vars
        @window = get_from_gui(:@window)
        @view = get_from_gui(:@view)

        # If the timer targeted the closed view, retarget it
        timer = get_from_gui(:@timer)
        timer_view_id = get_from_gui(:@timer_view_id)
        if timer && closing_view.to_i == timer_view_id
          ObjC::MSG_VOID.call(timer, ObjC.sel('invalidate'))
          timer_view_id = @view.to_i
          timer = ObjC::MSG_PTR_D_P_P_P_I.call(
            ObjC.cls('NSTimer'),
            ObjC.sel('scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:'),
            1.0 / 60.0, @view, ObjC.sel('timerFired:'),
            Fiddle::Pointer.new(0), 1
          )
          sync_to_gui(:@timer, timer)
          sync_to_gui(:@timer_view_id, timer_view_id)
        end
      end
    end
  end
end

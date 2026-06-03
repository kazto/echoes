# frozen_string_literal: true

require "test_helper"

Echoes.load_gui_backend if Echoes::Platform.windows?

if Echoes::Platform.windows?
  class Echoes::GUIWin32ParityUnitTest < Test::Unit::TestCase
    StubScreen = Struct.new(:rows, :cols, :scrollback, :cursor)
    StubPane = Struct.new(:screen, :copy_mode)
    StubTab = Struct.new(:active_pane)

    def setup
      @gui = Echoes::GUI::Backend::Win32.allocate
    end

    test "select_all enters copy mode and selects everything" do
      cursor = Struct.new(:row, :col).new(0, 0)
      screen = StubScreen.new(24, 80, ["row"] * 100, cursor)
      pane = StubPane.new(screen, nil)
      tab = StubTab.new(pane)
      @gui.instance_variable_set(:@tabs, [tab])
      @gui.instance_variable_set(:@active_tab, 0)
      @gui.define_singleton_method(:current_tab) { @tabs[@active_tab] }

      assert_true @gui.send(:select_all)
      
      copy_mode = pane.copy_mode
      assert_not_nil copy_mode
      assert_true copy_mode.active
      assert_equal [-100, 0], copy_mode.selection_start
      assert_equal [23, 79], copy_mode.selection_end
    end

    test "update_font updates font_size and clears handles" do
      @gui.instance_variable_set(:@font_size, 12.0)
      @gui.instance_variable_set(:@hfont, 123)
      @gui.instance_variable_set(:@cell_width, 8)
      @gui.instance_variable_set(:@hwnd, nil) # skip window resize
      
      # Mock Preferences
      singleton = class << Echoes::Preferences; self; end
      original_set = Echoes::Preferences.method(:set_double)
      singleton.send(:remove_method, :set_double)
      singleton.define_method(:set_double) { |key, val| [key, val] }

      # Mock Win32 calls
      original_delete = Echoes::Win32::DeleteObject
      Echoes::Win32.send(:remove_const, :DeleteObject)
      Echoes::Win32.const_set(:DeleteObject, ->(h) { h })

      @gui.define_singleton_method(:create_font) { |**_args| 456 }
      @gui.define_singleton_method(:invalidate_window) { true }
      
      begin
        assert_true @gui.send(:update_font, 14.0)
        
        assert_equal 14.0, @gui.instance_variable_get(:@font_size)
        assert_equal 456, @gui.instance_variable_get(:@hfont)
        assert_nil @gui.instance_variable_get(:@cell_width)
        assert_nil @gui.instance_variable_get(:@cell_height)
      ensure
        singleton.send(:remove_method, :set_double)
        singleton.define_method(:set_double, original_set)
        Echoes::Win32.send(:remove_const, :DeleteObject)
        Echoes::Win32.const_set(:DeleteObject, original_delete)
      end
    end

    test "tab_bar_height returns 0 for single tab, >0 for multiple" do
      @gui.instance_variable_set(:@tabs, [StubTab.new(nil)])
      assert_equal 0.0, @gui.tab_bar_height

      @gui.instance_variable_set(:@tabs, [StubTab.new(nil), StubTab.new(nil)])
      @gui.instance_variable_set(:@cell_height, 20)
      assert_equal 24.0, @gui.tab_bar_height
    end

    test "handle_left_button_down switches tabs when clicking tab bar" do
      tab1 = StubTab.new(nil)
      tab2 = StubTab.new(nil)
      @gui.instance_variable_set(:@tabs, [tab1, tab2])
      @gui.instance_variable_set(:@active_tab, 0)
      @gui.instance_variable_set(:@cell_width, 10)
      @gui.instance_variable_set(:@cell_height, 20)
      
      # Mock client_size
      @gui.define_singleton_method(:client_size) { [200, 400] }
      @gui.define_singleton_method(:invalidate_window) { true }

      # Click on second tab: x=150, y=10 (within tab bar height=24)
      lparam = (10 << 16) | 150
      assert_true @gui.send(:handle_left_button_down, 0, lparam)
      assert_equal 1, @gui.instance_variable_get(:@active_tab)
    end
  end
end

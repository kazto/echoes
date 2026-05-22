require_relative '../test_helper'

class GuiLoadTest < Test::Unit::TestCase
  def test_gui_window_class_binding
    Echoes.load_gui_backend
    assert_not_nil Echoes::GUI.window_class
    if Echoes::Platform.windows?
      assert_equal "Echoes::GUI::Win32Window", Echoes::GUI.window_class.name
    elsif Echoes::Platform.macos?
      assert_equal "Echoes::GUI::MacWindow", Echoes::GUI.window_class.name
    end
  end
end

# frozen_string_literal: true

require "test_helper"

Echoes.load_gui_backend if Echoes::Platform.windows?

if Echoes::Platform.windows?
  class Echoes::Win32NotificationTest < Test::Unit::TestCase
    # Regression: show_notification referenced Win32 bindings that were never
    # defined (NameError: uninitialized constant Echoes::Win32::GetClassLongW),
    # so every notification call failed. A bogus hwnd exercises the full body
    # without needing a real window; Shell_NotifyIconW just returns failure.
    test "show_notification does not raise for a stale hwnd" do
      assert_nothing_raised do
        Echoes::Win32.show_notification(0x1234, "Echoes", "hello")
      end
    end
  end
end

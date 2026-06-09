# frozen_string_literal: true

require "test_helper"
require "echoes/gui/backend"

class Echoes::PlatformTest < Test::Unit::TestCase
  test "detects Windows host os variants" do
    assert_true Echoes::Platform.windows?("mswin")
    assert_true Echoes::Platform.windows?("mingw32")
    assert_true Echoes::Platform.windows?("x64-mingw-ucrt")
    assert_true Echoes::Platform.windows?("cygwin")
    assert_false Echoes::Platform.windows?("darwin23")
    assert_false Echoes::Platform.windows?("linux-gnu")
  end

  test "detects macOS host os variants" do
    assert_true Echoes::Platform.macos?("darwin23")
    assert_false Echoes::Platform.macos?("x64-mingw-ucrt")
    assert_false Echoes::Platform.macos?("linux-gnu")
  end

  test "detects Unix-like hosts excluding Windows" do
    assert_true Echoes::Platform.unix?("darwin23")
    assert_true Echoes::Platform.unix?("linux-gnu")
    assert_false Echoes::Platform.unix?("x64-mingw-ucrt")
    assert_false Echoes::Platform.unix?("mswin")
  end

  test "chooses a platform default shell" do
    assert_equal(
      "powershell.exe",
      Echoes::Platform.default_shell("x64-mingw-ucrt", env: {}, executable_lookup: ->(_) {})
    )
    assert_equal "/bin/bash", Echoes::Platform.default_shell("darwin23")
    assert_equal "/bin/bash", Echoes::Platform.default_shell("linux-gnu")
  end

  test "Windows default shell prefers COMSPEC" do
    assert_equal(
      "C:\\Windows\\System32\\cmd.exe",
      Echoes::Platform.default_shell(
        "x64-mingw-ucrt",
        env: {"COMSPEC" => "C:\\Windows\\System32\\cmd.exe"}
      )
    )
  end

  test "Windows default shell prefers pwsh before Windows PowerShell" do
    lookup = ->(name) { name == "pwsh" ? "C:\\Program Files\\PowerShell\\7\\pwsh.exe" : nil }
    assert_equal(
      "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
      Echoes::Platform.default_shell("x64-mingw-ucrt", env: {}, executable_lookup: lookup)
    )
  end

  test "gui_backend raises Error for unsupported platform" do
    assert_raise(Echoes::Error) do
      Echoes::Platform.gui_backend("linux-gnu")
    end
  end

  if Echoes::Platform.windows?
    test "gui_backend returns Win32 backend class on Windows" do
      omit "GUI::Backend::Win32 not yet defined" unless defined?(Echoes::GUI::Backend::Win32)
      klass = Echoes::Platform.gui_backend
      assert_equal "Echoes::GUI::Backend::Win32", klass.name
    end
  end
end

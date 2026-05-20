# frozen_string_literal: true

require "test_helper"

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
    assert_equal "powershell.exe", Echoes::Platform.default_shell("x64-mingw-ucrt")
    assert_equal "/bin/bash", Echoes::Platform.default_shell("darwin23")
    assert_equal "/bin/bash", Echoes::Platform.default_shell("linux-gnu")
  end
end

# frozen_string_literal: true

require "test_helper"
require "echoes/shell_backend"

class Echoes::ShellBackendTest < Test::Unit::TestCase
  test "selects Windows popen backend on Windows" do
    assert_equal(
      Echoes::WindowsPopenBackend,
      Echoes::ShellBackend.for_platform("mswin")
    )
  end

  test "selects Mac pty backend on macOS" do
    assert_equal(
      Echoes::MacPtyBackend,
      Echoes::ShellBackend.for_platform("darwin")
    )
  end

  test "selects Unix pty backend on other Unix platforms" do
    assert_equal(
      Echoes::UnixPtyBackend,
      Echoes::ShellBackend.for_platform("linux")
    )
  end
end

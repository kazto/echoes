# frozen_string_literal: true

require "test_helper"
require "echoes/cli"

class Echoes::CLITest < Test::Unit::TestCase
  test "runs terminal mode without loading gui backend" do
    loaded_gui = false
    ran_terminal = false

    Echoes::CLI.run(
      ["--tty"],
      load_core: -> {},
      load_gui: -> { loaded_gui = true },
      terminal_runner: -> { ran_terminal = true },
      gui_runner: -> {},
      installer: nil
    )

    assert_true(ran_terminal)
    assert_false(loaded_gui)
  end

  test "loads gui backend only for gui mode" do
    loaded_gui = false
    ran_gui = false

    Echoes::CLI.run(
      [],
      load_core: -> {},
      load_gui: -> { loaded_gui = true },
      terminal_runner: -> {},
      gui_runner: -> { ran_gui = true },
      installer: nil
    )

    assert_true(loaded_gui)
    assert_true(ran_gui)
  end

  test "dispatches installer commands without loading core gui" do
    loaded_core = false
    installed = false
    installer = Object.new
    installer.define_singleton_method(:install) { installed = true }

    Echoes::CLI.run(
      ["install"],
      load_core: -> { loaded_core = true },
      load_gui: -> {},
      terminal_runner: -> {},
      gui_runner: -> {},
      installer: installer
    )

    assert_true(installed)
    assert_false(loaded_core)
  end
end

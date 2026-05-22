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

  test "selects Windows ConPTY backend when requested" do
    assert_equal(
      Echoes::WindowsConPTYBackend,
      Echoes::ShellBackend.for_platform("mswin", windows_backend: :conpty)
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

  class FakeConPTY
    attr_reader :spawn_args, :resizes, :writes, :killed

    def initialize
      @pipe_out_r = 111
      @pipe_in_w = 222
      @h_process = 333
      @h_process_id = 444
      @resizes = []
      @writes = []
      @killed = false
    end

    attr_reader :pipe_out_r, :pipe_in_w, :h_process, :h_process_id

    def spawn(command, cols:, rows:)
      @spawn_args = [command, cols, rows]
    end

    def resize(cols, rows)
      @resizes << [cols, rows]
    end

    def write(bytes)
      @writes << bytes
    end

    def read_available_output(max)
      "x" * max
    end

    def alive?
      true
    end

    def kill
      @killed = true
    end
  end

  test "ConPTY backend exposes the shell backend contract" do
    conpty = FakeConPTY.new
    backend = Echoes::WindowsConPTYBackend.new(
      command: "powershell.exe",
      env: nil,
      rows: 24,
      cols: 80,
      conpty: conpty
    )

    assert_equal(["powershell.exe", 80, 24], conpty.spawn_args)
    assert_equal(444, backend.pid)
    assert_equal("xxxxx", backend.read_available_output(5))

    backend.write("abc")
    backend.resize(30, 100)
    assert_equal(["abc"], conpty.writes)
    assert_equal([[100, 30]], conpty.resizes)
    assert_true(backend.alive?)

    backend.close
    assert_true(conpty.killed)
  end
end

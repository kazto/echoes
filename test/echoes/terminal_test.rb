# frozen_string_literal: true

require "test_helper"

class Echoes::TerminalTest < Test::Unit::TestCase
  class FakeBackend
    attr_reader :command, :env, :rows, :cols, :px_width, :px_height, :writes

    def initialize(command:, env:, rows:, cols:, px_width: 0, px_height: 0)
      @command = command
      @env = env
      @rows = rows
      @cols = cols
      @px_width = px_width
      @px_height = px_height
      @writes = []
    end

    def read_io
      nil
    end

    def write_io
      nil
    end

    def pid
      123
    end

    def write(bytes)
      @writes << bytes
    end

    def resize(rows, cols, px_width: 0, px_height: 0)
      @rows = rows
      @cols = cols
      @px_width = px_width
      @px_height = px_height
    end

    def close; end
  end

  test "start_backend uses the configured shell backend" do
    terminal = Echoes::Terminal.new(command: "cmd.exe", rows: 12, cols: 34, backend_class: FakeBackend)
    backend = terminal.send(:start_backend)

    assert_instance_of(FakeBackend, backend)
    assert_equal("cmd.exe", backend.command)
    assert_equal(12, backend.rows)
    assert_equal(34, backend.cols)
    assert_equal(123, terminal.pid)
  end

  test "parser writer sends terminal responses through the backend" do
    terminal = Echoes::Terminal.new(command: "cmd.exe", rows: 12, cols: 34, backend_class: FakeBackend)
    backend = terminal.send(:start_backend)

    terminal.parser.feed("\e[6n")

    assert_include(backend.writes.join, "\e[")
  end
end

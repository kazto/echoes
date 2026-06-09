# frozen_string_literal: true

require "test_helper"

class Echoes::GuiWin32LayoutTest < Test::Unit::TestCase
  test "gui win32 files stay under 1000 lines each" do
    files = [
      File.expand_path("../../lib/echoes/gui_win32.rb", __dir__),
      *Dir.glob(File.expand_path("../../lib/echoes/gui_win32/*.rb", __dir__)).sort
    ]

    assert_operator(files.size, :>, 1)

    files.each do |path|
      line_count = File.readlines(path, chomp: false).size
      assert_operator(line_count, :<=, 1000, "#{path} has #{line_count} lines")
    end
  end
end

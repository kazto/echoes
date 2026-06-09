# frozen_string_literal: true

require "test_helper"

# Lint rules for lib/echoes/gui_win32/*.rb files.
# These tests catch structural problems that ruby -c cannot detect.
class Echoes::GUIWin32LintTest < Test::Unit::TestCase
  WIN32_FILES = Dir[File.expand_path("../../../lib/echoes/gui_win32/*.rb", __dir__)].sort.freeze

  # Deep nesting (class GUI / class Backend / class Win32) causes Ruby's
  # constant lookup to find the Win32 class itself when resolving bare Win32::,
  # shadowing Echoes::Win32. All files must use compact notation instead.
  #
  # CORRECT:   module Echoes; class GUI::Backend::Win32
  # WRONG:     module Echoes; class GUI; class Backend; class Win32
  test "all gui_win32 files use compact class notation, not deep nesting" do
    violations = WIN32_FILES.select do |path|
      content = File.read(path)
      content.match?(/^  class GUI\b(?!::)/)
    end
    assert_empty violations,
      "These gui_win32 files use deep nesting instead of compact notation " \
      "(see CLAUDE.md 'Win32 Backend Class Notation Rule'):\n" +
      violations.map { |f| "  #{File.basename(f)}" }.join("\n")
  end

  # Every gui_win32 file must open the correct class. Catches typos or
  # accidental reopening of the wrong class.
  test "all gui_win32 files reopen GUI::Backend::Win32 or define it" do
    violations = WIN32_FILES.reject do |path|
      content = File.read(path)
      content.match?(/class GUI::Backend::Win32/)
    end
    assert_empty violations,
      "These gui_win32 files do not open Echoes::GUI::Backend::Win32:\n" +
      violations.map { |f| "  #{File.basename(f)}" }.join("\n")
  end
end

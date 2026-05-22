# frozen_string_literal: true

# When invoked outside Bundler (e.g. from the .app launcher with bare
# `ruby exe/echoes`), `require 'rubish'` and `require 'rvim'` would
# pick up gem-installed copies that may lag the path-pinned source
# in the Gemfile and lack methods echoes calls. Prepend the sibling
# repo lib paths so the source versions win over Rubygems' default
# activation. The Gemfile already encodes the same sibling assumption
# via `path: "../rubish"` / `path: "../rvim"`, so this is just the
# Bundler-less mirror of that.
%w[rubish rvim].each do |sibling|
  lib = File.expand_path("../../#{sibling}/lib", __dir__)
  $LOAD_PATH.unshift(lib) if File.directory?(lib) && !$LOAD_PATH.include?(lib)
end

require_relative "echoes/version"
require_relative "echoes/platform"
require_relative "echoes/configuration"
require_relative "echoes/cell"
require_relative "echoes/cursor"
require_relative "echoes/screen"
require_relative "echoes/parser"
require_relative "echoes/copy_mode"
require_relative "echoes/shake_detector"
require_relative "echoes/pane"
require_relative "echoes/pane_tree"
require_relative "echoes/tab"
require_relative "echoes/sixel_decoder"
require_relative "echoes/terminal"
require_relative "echoes/preferences"

module Echoes
  class Error < StandardError; end

  module_function

  def load_gui_backend
    if Platform.windows?
      require_relative "echoes/win32"
      require_relative "echoes/gui_win32"
      require_relative "echoes/gui/win32_window"
      GUI.window_class = GUI::Win32Window
    elsif Platform.macos?
      require_relative "echoes/objc"
      require_relative "echoes/gui"
      require_relative "echoes/gui/mac_window"
      GUI.window_class = GUI::MacWindow
    else
      raise Error, "Echoes GUI is not supported on this platform"
    end
  end
end

Echoes.load_config

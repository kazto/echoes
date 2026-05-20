# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "echoes"

require "test-unit"
require "rbconfig"

module TestHelper
  IS_WINDOWS = RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
  # Windows uses cmd.exe to mimic an interactive process that handles stdin and echoes output.
  CAT_COMMAND = IS_WINDOWS ? "cmd.exe" : "/bin/cat"
  TRUE_COMMAND = IS_WINDOWS ? "cmd.exe /c exit" : "/usr/bin/true"
end


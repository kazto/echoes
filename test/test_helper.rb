# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
ENV["ECHOES_CONFIG_HOME"] ||= File.expand_path("../tmp/test-config", __dir__)
require "echoes"

require "test-unit"

module TestHelper
  IS_WINDOWS = Echoes::Platform.windows?
  # Windows uses cmd.exe to mimic an interactive process that handles stdin and echoes output.
  CAT_COMMAND = IS_WINDOWS ? "cmd.exe" : "/bin/cat"
  TRUE_COMMAND = IS_WINDOWS ? "cmd.exe /c exit" : "/usr/bin/true"
end


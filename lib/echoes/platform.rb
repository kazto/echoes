# frozen_string_literal: true

require 'rbconfig'

module Echoes
  module Platform
    WINDOWS_RE = /mswin|mingw|cygwin/i
    MACOS_RE = /darwin/i

    module_function

    def host_os
      RbConfig::CONFIG['host_os'].to_s
    end

    def windows?(os = host_os)
      os.to_s.match?(WINDOWS_RE)
    end

    def macos?(os = host_os)
      os.to_s.match?(MACOS_RE)
    end

    def unix?(os = host_os)
      !windows?(os)
    end

    def default_shell(os = host_os)
      windows?(os) ? 'powershell.exe' : '/bin/bash'
    end
  end
end

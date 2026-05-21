# frozen_string_literal: true

module Echoes
  module CLI
    module_function

    def run(argv = ARGV,
            load_core: -> { require "echoes" },
            load_gui: -> { Echoes.load_gui_backend },
            terminal_runner: -> { Echoes::Terminal.new.run },
            gui_runner: -> { Echoes::GUI.new.run },
            installer: nil)
      args = argv.dup

      case args.first
      when "install", "uninstall"
        require "echoes/installer" unless installer
        (installer || Echoes::Installer).public_send(args.shift)
      else
        load_core.call
        if args.delete("--tty") || args.delete("-t")
          terminal_runner.call
        else
          load_gui.call
          gui_runner.call
        end
      end
    end
  end
end

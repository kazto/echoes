# frozen_string_literal: true

module Echoes
  # Thin platform-agnostic orchestrator. Owns no native state itself;
  # delegates run() to the platform backend selected by Platform.gui_backend.
  class GUI
    extend GUI::Osc7

    def initialize(command: Echoes.config.shell, rows: Echoes.config.rows, cols: Echoes.config.cols, font_size: nil)
      @backend = Platform.gui_backend.new(
        command: command, rows: rows, cols: cols, font_size: font_size
      )
    end

    def run
      @backend.run
    end

    # capture_format_for exists on both platform backends; forward from the
    # thin orchestrator so callers using Echoes::GUI.capture_format_for still work.
    def self.capture_format_for(path)
      Platform.gui_backend.capture_format_for(path)
    end
  end
end

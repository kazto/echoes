# frozen_string_literal: true

module Echoes
  class GUI
    # Abstract base class for platform GUI backends.
    # Each backend owns a native window, run loop, and rendering.
    # The GUI orchestrator (gui_orchestrator.rb) holds one backend instance
    # and delegates #run to it.
    #
    # Subclasses must implement #initialize and #run.
    # All other methods are platform-specific and live only on the subclass.
    class Backend
      def initialize(command:, rows:, cols:, font_size: nil)
        raise NotImplementedError, "#{self.class}#initialize not implemented"
      end

      def run
        raise NotImplementedError, "#{self.class}#run not implemented"
      end
    end
  end
end

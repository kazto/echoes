# frozen_string_literal: true

module Echoes
  # Detect a "shake to find pointer" gesture from a stream of mouse
  # samples. Looks at the trailing WINDOW seconds of motion: a shake
  # is several quick direction reversals over a meaningful distance.
  # Tuned for casual wrist-shakes; not a substitute for the OS's own
  # accessibility feature, which kicks in for the visible system
  # cursor regardless of what apps are doing.
  class ShakeDetector
    WINDOW   = 0.5    # seconds of history to consider
    MIN_REVS = 3      # direction reversals required
    MIN_PATH = 150.0  # cumulative pixels of motion required

    def initialize
      @samples = []
    end

    # Add a (time, x, y) sample. Returns true on the call where a
    # shake first crosses the threshold; callers should treat this
    # as edge-triggered and follow up with #reset.
    def observe(t, x, y)
      @samples << [t, x, y]
      cutoff = t - WINDOW
      @samples.shift while @samples.first && @samples.first[0] < cutoff
      return false if @samples.size < 4
      detect
    end

    def reset
      @samples.clear
    end

    private

    def detect
      reversals = 0
      path = 0.0
      prev_dx = nil
      prev_dy = nil
      (1...@samples.size).each do |i|
        _, x0, y0 = @samples[i - 1]
        _, x1, y1 = @samples[i]
        dx = x1 - x0
        dy = y1 - y0
        next if dx.zero? && dy.zero?
        path += Math.sqrt(dx * dx + dy * dy)
        if prev_dx
          if (prev_dx * dx < 0) || (prev_dy * dy < 0)
            reversals += 1
          end
        end
        prev_dx = dx
        prev_dy = dy
      end
      reversals >= MIN_REVS && path >= MIN_PATH
    end
  end
end

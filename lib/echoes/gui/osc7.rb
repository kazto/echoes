# frozen_string_literal: true

require "uri"
require "socket"

module Echoes
  class GUI
    module Osc7
      def pane_local_cwd(pane)
        uri_str = pane&.screen&.current_directory
        cwd_from_osc7_uri(uri_str)
      end

      def cwd_from_osc7_uri(uri_str)
        return nil if uri_str.nil? || uri_str.empty?

        uri = URI.parse(uri_str) rescue nil
        return nil unless uri && uri.scheme == "file"

        host = uri.host.to_s
        local_host = Socket.gethostname
        unless host.empty? || host == "localhost" ||
               host == local_host || host == local_host.split(".").first
          return nil
        end

        path = URI.decode_www_form_component(uri.path) rescue nil
        # Windows: file URI encodes C:\... as /C:/...; strip the leading slash.
        # Harmless on macOS/Linux: no path matches /[A-Za-z]:/.
        path = path[1..] if path&.match?(/\A\/[A-Za-z]:\//)
        path if path && !path.empty? && Dir.exist?(path)
      end
    end
  end
end

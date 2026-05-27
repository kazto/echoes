# frozen_string_literal: true

require_relative 'win32'

module Echoes
  module WindowRegistry
    REGISTRY_NAME = "EchoesWindowRegistry"
    MAX_WINDOWS = 32
    ENTRY_SIZE = 256
    HEADER_SIZE = 32
    TOTAL_SIZE = HEADER_SIZE + (MAX_WINDOWS * ENTRY_SIZE)
    VERSION = 1

    class << self
      def register_window(hwnd, title)
        ensure_registry_initialized
        return false unless @mapping && @view

        acquire_mutex do
          find_or_create_entry(Process.pid, hwnd, title)
        end
      end

      def unregister_window(pid)
        ensure_registry_initialized
        return false unless @mapping && @view

        acquire_mutex do
          remove_entry_by_pid(pid)
        end
      end

      def list_windows
        ensure_registry_initialized
        return [] unless @mapping && @view

        acquire_mutex do
          read_all_entries
        end || []
      end

      def focus_window(hwnd)
        return false unless Echoes::Win32::SetForegroundWindow
        return false if hwnd.nil? || Echoes::Win32.null_pointer?(hwnd)

        Echoes::Win32::SetForegroundWindow.call(hwnd) != 0
      end

      def update_title(pid, new_title)
        ensure_registry_initialized
        return false unless @mapping && @view

        acquire_mutex do
          update_entry_title(pid, new_title)
        end
      end

      def cleanup
        if @view && !Echoes::Win32.null_pointer?(@view)
          Echoes::Win32::UnmapViewOfFile.call(@view)
          @view = nil
        end

        if @mapping && !Echoes::Win32.null_pointer?(@mapping) &&
           @mapping.to_i != Echoes::Win32::INVALID_HANDLE_VALUE
          Echoes::Win32::CloseHandle.call(@mapping)
          @mapping = nil
        end

        if @mutex && !Echoes::Win32.null_pointer?(@mutex)
          Echoes::Win32::CloseHandle.call(@mutex)
          @mutex = nil
        end
      end

      private

      def ensure_registry_initialized
        return true if @mapping && @view && @mutex

        @mutex = create_mutex
        return false unless @mutex

        @mapping = create_shared_memory
        return false unless @mapping

        @view = map_shared_memory
        return false unless @view

        initialize_header if new_registry?
        true
      end

      def create_mutex
        return nil unless Echoes::Win32::CreateMutexW

        mutex_name = Echoes::Win32.to_wstring("#{registry_name}_Mutex")
        mutex = Echoes::Win32::CreateMutexW.call(0, 0, mutex_name)
        return nil if Echoes::Win32.null_pointer?(mutex) || mutex.to_i == Echoes::Win32::INVALID_HANDLE_VALUE

        mutex
      end

      def create_shared_memory
        return nil unless Echoes::Win32::CreateFileMappingW

        registry_name = Echoes::Win32.to_wstring(registry_name)
        mapping = Echoes::Win32::CreateFileMappingW.call(
          Echoes::Win32::INVALID_HANDLE_VALUE,
          0,
          Echoes::Win32::PAGE_READWRITE,
          0,
          TOTAL_SIZE,
          registry_name
        )

        return nil if Echoes::Win32.null_pointer?(mapping) || mapping.to_i == Echoes::Win32::INVALID_HANDLE_VALUE

        mapping
      end

      def registry_name
        ENV.fetch('ECHOES_WINDOW_REGISTRY_NAME', REGISTRY_NAME)
      end

      def map_shared_memory
        return nil unless Echoes::Win32::MapViewOfFile

        view = Echoes::Win32::MapViewOfFile.call(
          @mapping,
          Echoes::Win32::FILE_MAP_ALL_ACCESS,
          0,
          0,
          TOTAL_SIZE
        )

        return nil if Echoes::Win32.null_pointer?(view) || view.to_i == 0

        view
      end

      def new_registry?
        return false unless @view

        version = @view[0, 4].unpack1('L')
        version == 0
      end

      def initialize_header
        return unless @view

        @view[0, 4] = [VERSION].pack('L')
        @view[4, 4] = [0].pack('L')
        @view[8, 8] = [0].pack('Q')

        zero_entries
      end

      def zero_entries
        return unless @view

        (HEADER_SIZE...TOTAL_SIZE).step(ENTRY_SIZE) do |offset|
          @view[offset, ENTRY_SIZE] = "\x00" * ENTRY_SIZE
        end
      end

      def acquire_mutex
        return false unless @mutex && Echoes::Win32::WaitForSingleObject

        result = Echoes::Win32::WaitForSingleObject.call(@mutex, Echoes::Win32::INFINITE_SIGNED)
        return false if result != Echoes::Win32::WAIT_OBJECT_0

        begin
          yield
        ensure
          Echoes::Win32::ReleaseMutex.call(@mutex) if Echoes::Win32::ReleaseMutex
        end
      end

      def find_or_create_entry(pid, hwnd, title)
        existing_index = find_entry_index_by_pid(pid)
        if existing_index
          update_entry_at_index(existing_index, pid, hwnd, title)
        else
          empty_index = find_empty_entry_index
          return false unless empty_index

          create_entry_at_index(empty_index, pid, hwnd, title)
        end
      end

      def find_entry_index_by_pid(pid)
        (0...MAX_WINDOWS).each do |i|
          entry_pid = read_entry_pid(i)
          return i if entry_pid == pid
        end
        nil
      end

      def find_empty_entry_index
        (0...MAX_WINDOWS).each do |i|
          entry_pid = read_entry_pid(i)
          return i if entry_pid == 0
        end
        nil
      end

      def remove_entry_by_pid(pid)
        index = find_entry_index_by_pid(pid)
        return false unless index

        zero_entry_at_index(index)
        true
      end

      def read_all_entries
        windows = []
        (0...MAX_WINDOWS).each do |i|
          entry = read_entry_at_index(i)
          windows << entry if entry
        end
        windows
      end

      def update_entry_title(pid, new_title)
        index = find_entry_index_by_pid(pid)
        return false unless index

        offset = HEADER_SIZE + (index * ENTRY_SIZE) + 16
        title_bytes = Echoes::Win32.to_wstring(new_title.to_s)[0...240]
        padding_size = 240 - title_bytes.bytesize
        padding = "\x00\x00".encode('UTF-16LE') * (padding_size / 2)
        @view[offset, 240] = title_bytes + padding

        update_timestamp
        true
      end

      def read_entry_at_index(index)
        pid = read_entry_pid(index)
        return nil if pid == 0

        offset = HEADER_SIZE + (index * ENTRY_SIZE)
        hwnd = @view[offset + 8, 8].unpack1('Q')
        title_raw = @view[offset + 16, 240]

        return nil if hwnd == 0

        title = begin
          Echoes::Win32.from_wstring(Fiddle::Pointer[title_raw])
        rescue
          nil
        end

        {
          pid: pid,
          hwnd: hwnd,
          title: title || "Echoes"
        }
      end

      def read_entry_pid(index)
        offset = HEADER_SIZE + (index * ENTRY_SIZE)
        @view[offset, 8].unpack1('Q')
      end

      def create_entry_at_index(index, pid, hwnd, title)
        offset = HEADER_SIZE + (index * ENTRY_SIZE)
        @view[offset, 8] = [pid].pack('Q')
        @view[offset + 8, 8] = [hwnd.to_i].pack('Q')

        title_bytes = Echoes::Win32.to_wstring(title.to_s)[0...240]
        padding_size = 240 - title_bytes.bytesize
        padding = "\x00\x00".encode('UTF-16LE') * (padding_size / 2)
        @view[offset + 16, 240] = title_bytes + padding

        update_timestamp
        true
      end

      def update_entry_at_index(index, pid, hwnd, title)
        offset = HEADER_SIZE + (index * ENTRY_SIZE)
        @view[offset, 8] = [pid].pack('Q')
        @view[offset + 8, 8] = [hwnd.to_i].pack('Q')

        title_bytes = Echoes::Win32.to_wstring(title.to_s)[0...240]
        padding_size = 240 - title_bytes.bytesize
        padding = "\x00\x00".encode('UTF-16LE') * (padding_size / 2)
        @view[offset + 16, 240] = title_bytes + padding

        update_timestamp
        true
      end

      def zero_entry_at_index(index)
        offset = HEADER_SIZE + (index * ENTRY_SIZE)
        @view[offset, ENTRY_SIZE] = "\x00" * ENTRY_SIZE
        update_timestamp
      end

      def update_timestamp
        return unless @view

        timestamp = Time.now.to_i
        @view[8, 8] = [timestamp].pack('Q')
      end
    end
  end
end

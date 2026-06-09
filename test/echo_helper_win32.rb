# frozen_string_literal: true

STDOUT.sync = true
STDIN.sync = true

while chunk = STDIN.read(1)
  STDOUT.write(chunk)
  STDOUT.flush
end

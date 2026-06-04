# frozen_string_literal: true

# SlotConfig derives a worktree's runtime configuration from its slot number:
# the local Rails port and the (slot-suffixed) database names / connection URLs.
#
# Slot 1 keeps the original database names for backward compatibility; higher
# slots get an `_sN` suffix so worktrees never share data. Only the Rails port
# varies per worktree — the shared deps (postgres, redis, observability) are
# reached on fixed localhost ports.
module SlotConfig
  RAILS_BASE_PORT  = 3000
  RAILS_PORT_STRIDE = 10
  DB_BASE = "chatbot_development"

  # Connection options database.yml applies to every local connection; kept on
  # the URL so a URL override doesn't drop them (needed on arm64 macOS forks).
  DB_QUERY = "sslmode=disable&gssencmode=disable"

  module_function

  def rails_port(slot)
    RAILS_BASE_PORT + (slot - 1) * RAILS_PORT_STRIDE
  end

  # { primary:, queue:, cable:, cache: } database names for the slot.
  def database_names(slot)
    prefix = slot == 1 ? DB_BASE : "#{DB_BASE}_s#{slot}"
    {
      primary: prefix,
      queue:   "#{prefix}_queue",
      cable:   "#{prefix}_cable",
      cache:   "#{prefix}_cache"
    }
  end

  # { primary:, queue:, cable:, cache: } => postgresql URLs.
  def database_urls(slot, host:, port:, username:, password:)
    authority = "#{username}:#{password}@#{host}:#{port}"
    database_names(slot).transform_values do |db|
      "postgresql://#{authority}/#{db}?#{DB_QUERY}"
    end
  end

  # Flat ENV-style mapping a shell can source: SLOT, RAILS_PORT, *_DATABASE_URL.
  def env(slot, host:, port:, username:, password:)
    urls = database_urls(slot, host: host, port: port, username: username, password: password)
    {
      "SLOT"               => slot.to_s,
      "RAILS_PORT"         => rails_port(slot).to_s,
      "DATABASE_URL"       => urls[:primary],
      "QUEUE_DATABASE_URL" => urls[:queue],
      "CABLE_DATABASE_URL" => urls[:cable],
      "CACHE_DATABASE_URL" => urls[:cache]
    }
  end
end

# frozen_string_literal: true

require "json"

# SlotRegistry maps a git worktree path to a stable "slot" number used to
# allocate a per-worktree Rails port and database names.
#
# The registry is a small JSON file shared by every worktree of the repo (it
# lives in the shared `git --git-common-dir`, so each worktree sees the same
# data). Assignment is first-come: a new worktree gets the lowest free slot.
#
# Pure stdlib — usable both from the standalone bin/use-slot script and from
# the Rails test suite (Zeitwerk autoloads this under `lib/`).
class SlotRegistry
  DEFAULT_FILENAME = "rails-llm-slots.json"

  def initialize(path)
    @path = path
  end

  # Slot for `worktree`, assigning the lowest free slot if not yet registered.
  def assign(worktree)
    with_lock do |data|
      key = normalize(worktree)
      data[key] ||= lowest_free_slot(data.values)
      write(data)
      data[key]
    end
  end

  # Slot for `worktree`, or nil if not registered. Does not assign.
  def lookup(worktree)
    read[normalize(worktree)]
  end

  # Remove `worktree` from the registry. Returns its freed slot, or nil.
  def release(worktree)
    with_lock do |data|
      removed = data.delete(normalize(worktree))
      write(data)
      removed
    end
  end

  # Full { path => slot } mapping.
  def all
    read
  end

  private

  def normalize(worktree)
    # realpath resolves symlinks (e.g. macOS /var -> /private/var) so the same
    # worktree always maps to one key; fall back for paths that don't exist yet.
    File.realpath(worktree)
  rescue Errno::ENOENT
    File.expand_path(worktree)
  end

  # Lowest positive integer not already taken.
  def lowest_free_slot(used)
    taken = used.map(&:to_i)
    slot = 1
    slot += 1 while taken.include?(slot)
    slot
  end

  def read
    return {} unless File.exist?(@path)

    raw = File.read(@path).strip
    return {} if raw.empty?

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def write(data)
    File.write(@path, JSON.pretty_generate(data) + "\n")
  end

  # Serialize read-modify-write across concurrent worktrees via an exclusive
  # flock on a sidecar lockfile.
  def with_lock
    File.open(lockfile, File::RDWR | File::CREAT, 0o644) do |f|
      f.flock(File::LOCK_EX)
      yield read
    end
  end

  def lockfile
    "#{@path}.lock"
  end
end

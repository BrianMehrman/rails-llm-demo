# frozen_string_literal: true

# Pure unit test — deliberately avoids test_helper so it needs no database or
# Rails boot. Run with the suite (bin/rails test) or standalone:
#   ruby -Itest test/lib/slot_registry_test.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/slot_registry"

class SlotRegistryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, SlotRegistry::DEFAULT_FILENAME)
    @registry = SlotRegistry.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_assigns_slot_one_to_first_worktree
    assert_equal 1, @registry.assign("/work/a")
  end

  def test_assignment_is_idempotent_for_same_worktree
    first = @registry.assign("/work/a")
    second = @registry.assign("/work/a")
    assert_equal first, second
  end

  def test_assigns_next_free_slot_to_additional_worktrees
    assert_equal 1, @registry.assign("/work/a")
    assert_equal 2, @registry.assign("/work/b")
    assert_equal 3, @registry.assign("/work/c")
  end

  def test_reuses_lowest_freed_slot_after_release
    @registry.assign("/work/a") # 1
    @registry.assign("/work/b") # 2
    @registry.assign("/work/c") # 3

    assert_equal 2, @registry.release("/work/b")
    # Lowest free slot is now 2, not 4.
    assert_equal 2, @registry.assign("/work/d")
  end

  def test_normalizes_relative_and_absolute_paths
    Dir.chdir(@dir) do
      FileUtils.mkdir_p("nested")
      absolute = File.join(@dir, "nested")
      slot_rel = @registry.assign("nested")
      slot_abs = @registry.assign(absolute)
      assert_equal slot_rel, slot_abs
    end
  end

  def test_lookup_does_not_assign
    assert_nil @registry.lookup("/work/a")
    assert_empty @registry.all
  end

  def test_release_of_unknown_worktree_returns_nil
    assert_nil @registry.release("/work/missing")
  end

  def test_persists_across_instances
    @registry.assign("/work/a")
    reopened = SlotRegistry.new(@path)
    assert_equal 1, reopened.lookup("/work/a")
  end

  def test_tolerates_corrupt_registry_file
    File.write(@path, "{ not json")
    assert_equal 1, @registry.assign("/work/a")
  end

  def test_all_returns_full_mapping
    @registry.assign("/work/a")
    @registry.assign("/work/b")
    assert_equal 2, @registry.all.size
  end
end

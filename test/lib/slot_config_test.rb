# frozen_string_literal: true

# Pure unit test — no Rails boot / database. Run standalone with:
#   ruby -Itest test/lib/slot_config_test.rb
require "minitest/autorun"
require_relative "../../lib/slot_config"

class SlotConfigTest < Minitest::Test
  def test_slot_one_uses_base_rails_port
    assert_equal 3000, SlotConfig.rails_port(1)
  end

  def test_rails_port_strides_by_ten
    assert_equal 3010, SlotConfig.rails_port(2)
    assert_equal 3020, SlotConfig.rails_port(3)
  end

  def test_slot_one_keeps_original_database_names
    names = SlotConfig.database_names(1)
    assert_equal "chatbot_development", names[:primary]
    assert_equal "chatbot_development_queue", names[:queue]
    assert_equal "chatbot_development_cable", names[:cable]
    assert_equal "chatbot_development_cache", names[:cache]
  end

  def test_higher_slots_get_suffixed_database_names
    names = SlotConfig.database_names(2)
    assert_equal "chatbot_development_s2", names[:primary]
    assert_equal "chatbot_development_s2_queue", names[:queue]
    assert_equal "chatbot_development_s2_cable", names[:cable]
    assert_equal "chatbot_development_s2_cache", names[:cache]
  end

  def test_database_urls_embed_credentials_host_and_db
    urls = SlotConfig.database_urls(2, host: "localhost", port: 5432, username: "postgres", password: "password")
    assert_equal "postgresql://postgres:password@localhost:5432/chatbot_development_s2?sslmode=disable&gssencmode=disable",
                 urls[:primary]
  end

  def test_env_emits_sourceable_mapping
    env = SlotConfig.env(2, host: "localhost", port: 5432, username: "postgres", password: "password")
    assert_equal "2", env["SLOT"]
    assert_equal "3010", env["RAILS_PORT"]
    assert_includes env["DATABASE_URL"], "/chatbot_development_s2?"
    assert_includes env["QUEUE_DATABASE_URL"], "/chatbot_development_s2_queue?"
  end
end

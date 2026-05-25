require "test_helper"

class ChatChannelTest < ActionCable::Channel::TestCase
  test "subscribes and streams for the given chat id" do
    subscribe chat_id: 42
    assert subscription.confirmed?
    assert_has_stream "chat_42"
  end

  test "does not stream for a different chat id" do
    subscribe chat_id: 42
    assert_has_no_stream "chat_99"
  end
end

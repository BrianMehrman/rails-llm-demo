require "test_helper"

class MessageTest < ActiveSupport::TestCase
  def setup
    @chat = Chat.create!(title: "Test Chat")
  end

  test "is valid with role, content, and chat" do
    msg = Message.new(chat: @chat, role: "user", content: "Hello", status: "complete")
    assert msg.valid?
  end

  test "role must be user or assistant" do
    msg = Message.new(chat: @chat, role: "bot", content: "Hi", status: "complete")
    assert_not msg.valid?
    assert_includes msg.errors[:role], "is not included in the list"
  end

  test "status must be pending, complete, or error" do
    msg = Message.new(chat: @chat, role: "user", content: "Hi", status: "unknown")
    assert_not msg.valid?
    assert_includes msg.errors[:status], "is not included in the list"
  end

  test "is invalid without a chat" do
    msg = Message.new(role: "user", content: "Hi", status: "complete")
    assert_not msg.valid?
  end

  test "defaults status to pending" do
    msg = Message.new(chat: @chat, role: "user", content: "Hi")
    assert_equal "pending", msg.status
    assert msg.valid?
  end

  test "is invalid without content" do
    msg = Message.new(chat: @chat, role: "user", status: "complete")
    assert_not msg.valid?
    assert_includes msg.errors[:content], "can't be blank"
  end
end

require "test_helper"

class ChatTest < ActiveSupport::TestCase
  test "is valid with a title" do
    chat = Chat.new(title: "Hello")
    assert chat.valid?
  end

  test "has many messages" do
    chat = Chat.create!(title: "Test")
    chat.messages.create!(role: "user", content: "Hi", status: "complete")
    assert_equal 1, chat.messages.count
  end

  test "is invalid without a title" do
    chat = Chat.new(title: "")
    assert_not chat.valid?
    assert_includes chat.errors[:title], "can't be blank"
  end

  test "destroying a chat destroys its messages" do
    chat = Chat.create!(title: "Doomed")
    chat.messages.create!(role: "user", content: "Hi", status: "complete")
    chat.messages.create!(role: "assistant", content: "", status: "pending")

    assert_difference("Message.count", -2) do
      chat.destroy!
    end
  end
end

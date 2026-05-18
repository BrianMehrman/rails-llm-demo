require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  test "GET /chats lists chats" do
    Chat.create!(title: "My Chat")
    get chats_url
    assert_response :success
    assert_select "h1", "Chats"
  end

  test "GET /chats/:id shows messages" do
    chat = Chat.create!(title: "Test Chat")
    chat.messages.create!(role: "user", content: "Hello", status: "complete")
    get chat_url(chat)
    assert_response :success
    assert_select ".message", count: 1
  end

  test "POST /chats creates a chat and redirects" do
    assert_difference("Chat.count") do
      post chats_url, params: { chat: { title: "New Chat" } }
    end
    assert_redirected_to chat_url(Chat.last)
  end

  test "DELETE /chats/:id destroys the chat" do
    chat = Chat.create!(title: "Bye")
    assert_difference("Chat.count", -1) do
      delete chat_url(chat)
    end
    assert_redirected_to chats_url
  end
end

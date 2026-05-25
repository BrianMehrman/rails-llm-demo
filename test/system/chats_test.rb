require "application_system_test_case"

class ChatsTest < ApplicationSystemTestCase
  test "visiting the chats index" do
    visit chats_url
    assert_selector "h1", text: "Your Chats"
  end

  test "creating a new chat navigates to the chat page" do
    visit chats_url
    click_link "Start one →"

    fill_in "Chat title", with: "My System Test Chat"
    click_button "Start Chat"

    assert_selector "h1", text: "My System Test Chat"
    assert_current_path %r{/chats/\d+}
  end

  test "submitting a message shows it in the chat and renders the thinking placeholder" do
    chat = Chat.create!(title: "E2E Chat")
    visit chat_url(chat)

    fill_in "content", with: "Hello from system test"
    click_button "Send"

    assert_selector ".message--user", text: "Hello from system test"
    assert_selector ".message--assistant em", text: "Thinking…"
  end
end

require "application_system_test_case"

class ChatsTest < ApplicationSystemTestCase
  test "visiting the chats index" do
    visit chats_url

    assert_selector "h1", text: "Your Chats"
  end
end

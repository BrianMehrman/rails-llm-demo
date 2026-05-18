require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @chat = Chat.create!(title: "Test Chat")
  end

  test "POST creates a user message and enqueues LlmResponseJob" do
    assert_enqueued_with(job: LlmResponseJob) do
      post chat_messages_url(@chat), params: { content: "Hello LLM" }
    end

    assert_redirected_to chat_url(@chat)
    user_msg = @chat.messages.where(role: "user").last
    assert_equal "Hello LLM", user_msg.content
    assert_equal "complete", user_msg.status
  end
end

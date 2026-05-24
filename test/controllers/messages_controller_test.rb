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

  test "POST with blank content redirects with alert" do
    post chat_messages_url(@chat), params: { content: "" }
    assert_redirected_to chat_url(@chat)
    assert_equal "Message can't be blank.", flash[:alert]
  end

  test "POST creates a pending assistant message" do
    assert_enqueued_with(job: LlmResponseJob) do
      post chat_messages_url(@chat), params: { content: "Hello" }
    end

    assistant_msgs = @chat.messages.where(role: "assistant")
    assert_equal 1, assistant_msgs.count
    assert_equal "pending", assistant_msgs.first.status
  end

  test "POST enqueues LlmResponseJob with chat id and assistant message id" do
    post chat_messages_url(@chat), params: { content: "Hello" }

    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    chat_id, assistant_msg_id = job[:args]
    assert_equal @chat.id, chat_id
    assert_equal @chat.messages.where(role: "assistant").last.id, assistant_msg_id
  end
end

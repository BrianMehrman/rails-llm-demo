require "test_helper"

class LlmResponseJobTest < ActiveJob::TestCase
  def setup
    @chat = Chat.create!(title: "Test")
    @chat.messages.create!(role: "user", content: "Hello", status: "complete")

    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(
        status: 200,
        body: { choices: [{ message: { content: "Hi there!" } }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  test "creates an assistant message with the LLM response" do
    assert_difference("Message.count") do
      LlmResponseJob.perform_now(@chat.id)
    end

    assistant_msg = @chat.messages.where(role: "assistant").last
    assert_equal "Hi there!", assistant_msg.content
    assert_equal "complete", assistant_msg.status
  end

  test "marks assistant message as error when LLM fails" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(status: 500, body: "Server Error")

    assert_difference("Message.count") do
      LlmResponseJob.perform_now(@chat.id)
    end

    assistant_msg = @chat.messages.where(role: "assistant").last
    assert_equal "error", assistant_msg.status
  end

  test "only sends complete messages as LLM history" do
    @chat.messages.create!(role: "assistant", content: "", status: "pending")

    LlmResponseJob.perform_now(@chat.id)

    # The pending assistant message should not appear in history
    # WebMock will raise if the request body doesn't match expectations
    # Verify: only 1 user message + original assistant in history (not the pending one)
    assert_requested(:post, "http://localhost:11434/v1/chat/completions") do |req|
      body = JSON.parse(req.body)
      body["messages"].none? { |m| m["content"] == "" }
    end
  end
end

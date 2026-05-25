require "test_helper"

class LlmResponseJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper

  def setup
    @chat = Chat.create!(title: "Test")
    @chat.messages.create!(role: "user", content: "Hello", status: "complete")

    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(
        status: 200,
        body: { choices: [ { message: { content: "Hi there!" } } ] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  test "creates an assistant message with the LLM response" do
    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")
    LlmResponseJob.perform_now(@chat.id, assistant_msg.id)

    assistant_msg.reload
    assert_equal "Hi there!", assistant_msg.content
    assert_equal "complete", assistant_msg.status
  end

  test "marks assistant message as error when LLM fails" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(status: 500, body: "Server Error")

    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")
    LlmResponseJob.perform_now(@chat.id, assistant_msg.id)

    assistant_msg.reload
    assert_equal "error", assistant_msg.status
  end

  test "only sends complete messages as LLM history" do
    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")

    LlmResponseJob.perform_now(@chat.id, assistant_msg.id)

    # The pending assistant message should not appear in history
    # WebMock will raise if the request body doesn't match expectations
    # Verify: only 1 user message + original assistant in history (not the pending one)
    assert_requested(:post, "http://localhost:11434/v1/chat/completions") do |req|
      body = JSON.parse(req.body)
      body["messages"].none? { |m| m["content"] == "" }
    end
  end

  test "broadcasts the assistant message after successful LLM response" do
    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")

    assert_turbo_stream_broadcasts(@chat, count: 1) do
      LlmResponseJob.perform_now(@chat.id, assistant_msg.id)
    end
  end

  test "broadcasts the assistant message even when LLM fails" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(status: 500, body: "Server Error")

    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")

    assert_turbo_stream_broadcasts(@chat, count: 1) do
      LlmResponseJob.perform_now(@chat.id, assistant_msg.id)
    end
  end

  test "creates an OTEL span with correct attributes on success" do
    finished_spans = []
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    OpenTelemetry::SDK.configure do |c|
      c.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
      )
    end

    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")
    LlmResponseJob.perform_now(@chat.id, assistant_msg.id)

    finished_spans = exporter.finished_spans
    job_span = finished_spans.find { |s| s.name == "llm_response_job.perform" }

    assert_not_nil job_span, "Expected a span named 'llm_response_job.perform'"
    assert_equal @chat.id.to_s, job_span.attributes["chat.id"]
    assert_equal assistant_msg.id.to_s, job_span.attributes["message.id"]
  end

  test "sets OTEL span status to OK on success" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    OpenTelemetry::SDK.configure do |c|
      c.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
      )
    end

    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")
    LlmResponseJob.perform_now(@chat.id, assistant_msg.id)

    job_span = exporter.finished_spans.find { |s| s.name == "llm_response_job.perform" }
    assert_not_nil job_span
    assert_equal OpenTelemetry::Trace::Status::OK, job_span.status.code
  end

  test "sets OTEL span status to ERROR when LLM fails" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(status: 500, body: "Server Error")

    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    OpenTelemetry::SDK.configure do |c|
      c.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
      )
    end

    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")
    LlmResponseJob.perform_now(@chat.id, assistant_msg.id)

    job_span = exporter.finished_spans.find { |s| s.name == "llm_response_job.perform" }
    assert_not_nil job_span
    assert_equal OpenTelemetry::Trace::Status::ERROR, job_span.status.code
  end

  test "observes histogram on success with correct status label" do
    registry = Prometheus::Client.registry
    histogram = registry.get(:llm_job_duration_seconds)
    assert_not_nil histogram, "Expected :llm_job_duration_seconds histogram to be registered"

    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")

    before_values = histogram.values.dup
    LlmResponseJob.perform_now(@chat.id, assistant_msg.id)
    after_values = histogram.values

    success_key = { status: "success" }
    assert after_values.key?(success_key), "Expected histogram to have a 'success' label entry"
  end

  test "observes histogram on error with correct status label" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(status: 500, body: "Server Error")

    registry = Prometheus::Client.registry
    histogram = registry.get(:llm_job_duration_seconds)
    assert_not_nil histogram, "Expected :llm_job_duration_seconds histogram to be registered"

    assistant_msg = @chat.messages.create!(role: "assistant", content: "", status: "pending")

    LlmResponseJob.perform_now(@chat.id, assistant_msg.id)
    after_values = histogram.values

    error_key = { status: "error" }
    assert after_values.key?(error_key), "Expected histogram to have an 'error' label entry"
  end
end

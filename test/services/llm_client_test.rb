require "test_helper"

class LlmClientTest < ActiveSupport::TestCase
  test "chat returns assistant content on success" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(
        status: 200,
        body: {
          choices: [ { message: { content: "Hello from LLM" } } ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    client = LlmClient.new
    result = client.chat([ { role: "user", content: "Hi" } ])
    assert_equal "Hello from LLM", result
  end

  test "chat raises LlmClient::Error on non-200 response" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")

    client = LlmClient.new
    assert_raises(LlmClient::Error) do
      client.chat([ { role: "user", content: "Hi" } ])
    end
  end

  test "uses OPENAI_API_BASE env var for base URL" do
    stub_request(:post, "http://custom-llm-host:8080/v1/chat/completions")
      .to_return(
        status: 200,
        body: { choices: [ { message: { content: "ok" } } ] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    ClimateControl.modify(OPENAI_API_BASE: "http://custom-llm-host:8080/v1") do
      result = LlmClient.new.chat([ { role: "user", content: "Hi" } ])
      assert_equal "ok", result
    end
  end

  test "sends LLM_MODEL env var as model in request body" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(
        status: 200,
        body: { choices: [ { message: { content: "ok" } } ] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    ClimateControl.modify(LLM_MODEL: "mistral") do
      LlmClient.new.chat([ { role: "user", content: "Hi" } ])
    end

    assert_requested(:post, "http://localhost:11434/v1/chat/completions") do |req|
      JSON.parse(req.body)["model"] == "mistral"
    end
  end

  test "raises LlmClient::Error on connection refused" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_raise(Errno::ECONNREFUSED)

    assert_raises(LlmClient::Error) do
      LlmClient.new.chat([ { role: "user", content: "Hi" } ])
    end
  end

  test "raises LlmClient::Error on read timeout" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_raise(Net::ReadTimeout)

    assert_raises(LlmClient::Error) do
      LlmClient.new.chat([ { role: "user", content: "Hi" } ])
    end
  end

  test "sets llm token span attributes when usage is present" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(
        status: 200,
        body: {
          choices: [ { message: { content: "Hello" } } ],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    OpenTelemetry::SDK.configure do |c|
      c.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
      )
    end

    LlmClient.new.chat([ { role: "user", content: "Hi" } ])

    span = exporter.finished_spans.find { |s| s.name == "llm.chat" }
    assert_not_nil span, "Expected an llm.chat span to be recorded"
    assert_equal 10, span.attributes["llm.prompt_tokens"]
    assert_equal 5,  span.attributes["llm.completion_tokens"]
    assert_equal 15, span.attributes["llm.total_tokens"]
  ensure
    OpenTelemetry.tracer_provider.shutdown
    OpenTelemetry.tracer_provider = OpenTelemetry::Internal::ProxyTracerProvider.new
  end

  test "does not raise when usage is absent from response" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(
        status: 200,
        body: {
          choices: [ { message: { content: "Hello" } } ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    assert_nothing_raised do
      LlmClient.new.chat([ { role: "user", content: "Hi" } ])
    end
  end

  test "increments llm_tokens_total counter on successful call" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(
        status: 200,
        body: {
          choices: [ { message: { content: "Hello" } } ],
          usage: { prompt_tokens: 8, completion_tokens: 4, total_tokens: 12 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    registry = Prometheus::Client.registry
    counter  = registry.get(:llm_tokens_total)

    ClimateControl.modify(LLM_MODEL: "test-model") do
      before_prompt     = counter.get(labels: { model: "test-model", type: "prompt" })
      before_completion = counter.get(labels: { model: "test-model", type: "completion" })
      before_total      = counter.get(labels: { model: "test-model", type: "total" })

      LlmClient.new.chat([ { role: "user", content: "Hi" } ])

      assert_equal before_prompt + 8,     counter.get(labels: { model: "test-model", type: "prompt" })
      assert_equal before_completion + 4, counter.get(labels: { model: "test-model", type: "completion" })
      assert_equal before_total + 12,     counter.get(labels: { model: "test-model", type: "total" })
    end
  end

  test "does not increment llm_tokens_total when usage is absent" do
    stub_request(:post, "http://localhost:11434/v1/chat/completions")
      .to_return(
        status: 200,
        body: {
          choices: [ { message: { content: "Hello" } } ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    registry = Prometheus::Client.registry
    counter  = registry.get(:llm_tokens_total)

    ClimateControl.modify(LLM_MODEL: "no-usage-model") do
      before_prompt = counter.get(labels: { model: "no-usage-model", type: "prompt" })

      LlmClient.new.chat([ { role: "user", content: "Hi" } ])

      assert_equal before_prompt, counter.get(labels: { model: "no-usage-model", type: "prompt" })
    end
  end
end

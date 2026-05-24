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
end

require "net/http"
require "json"
require "prometheus/client"

class LlmClient
  Error = Class.new(StandardError)

  REGISTRY     = Prometheus::Client.registry
  LLM_DURATION = begin
    REGISTRY.histogram(
      :llm_request_duration_seconds,
      docstring: "LLM API request duration in seconds",
      labels:    [ :model, :status ]
    )
  rescue Prometheus::Client::Registry::AlreadyRegisteredError
    REGISTRY.get(:llm_request_duration_seconds)
  end

  def initialize
    @base_url = ENV.fetch("OPENAI_API_BASE", "http://localhost:11434/v1")
    @model    = ENV.fetch("LLM_MODEL", "llama4")
  end

  def chat(messages)
    tracer = OpenTelemetry.tracer_provider.tracer("llm_client")
    start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    tracer.in_span(
      "llm.chat",
      attributes: {
        "llm.model"         => @model,
        "llm.message_count" => messages.size
      }
    ) do |span|
      response = make_request(messages)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      LLM_DURATION.observe(duration, labels: { model: @model, status: "success" })
      span.set_attribute("llm.response_length", response.to_s.length)
      response
    end
  rescue LlmClient::Error
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    LLM_DURATION.observe(duration, labels: { model: @model, status: "error" })
    raise
  end

  private

  def make_request(messages)
    uri  = URI("#{@base_url}/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = uri.scheme == "https"
    http.read_timeout = 120

    request                 = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body            = { model: @model, messages: messages, stream: false }.to_json

    response = http.request(request)
    raise Error, "LLM request failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).dig("choices", 0, "message", "content")
  rescue Errno::ECONNREFUSED, SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise Error, "LLM endpoint unreachable (#{@base_url}): #{e.message}"
  end
end

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

  LLM_TOKENS = begin
    REGISTRY.counter(
      :llm_tokens_total,
      docstring: "Total number of LLM tokens processed",
      labels:    [ :model, :type ]
    )
  rescue Prometheus::Client::Registry::AlreadyRegisteredError
    REGISTRY.get(:llm_tokens_total)
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
      result   = make_request(messages)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      LLM_DURATION.observe(duration, labels: { model: @model, status: "success" })
      span.set_attribute("llm.response_length", result[:content].to_s.length)

      if (usage = result[:usage])
        span.set_attribute("llm.prompt_tokens",     usage[:prompt_tokens])
        span.set_attribute("llm.completion_tokens", usage[:completion_tokens])
        span.set_attribute("llm.total_tokens",      usage[:total_tokens])

        LLM_TOKENS.increment(by: usage[:prompt_tokens],     labels: { model: @model, type: "prompt" })
        LLM_TOKENS.increment(by: usage[:completion_tokens], labels: { model: @model, type: "completion" })
        LLM_TOKENS.increment(by: usage[:total_tokens],      labels: { model: @model, type: "total" })
      end

      result[:content]
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

    body    = JSON.parse(response.body)
    content = body.dig("choices", 0, "message", "content")
    usage   = parse_usage(body["usage"])

    { content: content, usage: usage }
  rescue Errno::ECONNREFUSED, SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise Error, "LLM endpoint unreachable (#{@base_url}): #{e.message}"
  end

  def parse_usage(raw)
    return nil if raw.nil?

    {
      prompt_tokens:     raw["prompt_tokens"],
      completion_tokens: raw["completion_tokens"],
      total_tokens:      raw["total_tokens"]
    }
  end
end

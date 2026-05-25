require "prometheus/client"

class LlmResponseJob < ApplicationJob
  queue_as :default

  REGISTRY = Prometheus::Client.registry
  LLM_JOB_DURATION = begin
    REGISTRY.histogram(
      :llm_job_duration_seconds,
      docstring: "LLM response job duration in seconds",
      labels: [ :status ]
    )
  rescue Prometheus::Client::Registry::AlreadyRegisteredError
    REGISTRY.get(:llm_job_duration_seconds)
  end

  def perform(chat_id, assistant_message_id)
    tracer = OpenTelemetry.tracer_provider.tracer("llm_response_job")
    start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    tracer.in_span(
      "llm_response_job.perform",
      attributes: {
        "chat.id"    => chat_id.to_s,
        "message.id" => assistant_message_id.to_s
      }
    ) do |span|
      chat          = Chat.find(chat_id)
      assistant_msg = Message.find(assistant_message_id)

      history = chat.messages
                    .where(status: "complete")
                    .order(:created_at)
                    .map { |m| { role: m.role, content: m.content } }

      begin
        result = LlmClient.new.chat(history)
        assistant_msg.update!(content: result[:content], status: "complete")
        ctx = OpenTelemetry::Trace.current_span.context
        payload = { event: "llm_job_complete", chat_id: chat_id, message_id: assistant_message_id }
        if ctx.valid?
          payload[:trace_id] = ctx.trace_id.unpack1("H*")
          payload[:span_id]  = ctx.span_id.unpack1("H*")
        end
        if result[:usage]
          payload[:prompt_tokens]     = result[:usage][:prompt_tokens]
          payload[:completion_tokens] = result[:usage][:completion_tokens]
          payload[:total_tokens]      = result[:usage][:total_tokens]
        end
        Rails.logger.info payload.to_json
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        LLM_JOB_DURATION.observe(duration, labels: { status: "success" })
        span.status = OpenTelemetry::Trace::Status.ok
      rescue LlmClient::Error => e
        assistant_msg.update!(content: e.message, status: "error")
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        LLM_JOB_DURATION.observe(duration, labels: { status: "error" })
        span.status = OpenTelemetry::Trace::Status.error(e.message)
      end

      Turbo::StreamsChannel.broadcast_replace_to(
        chat,
        target: assistant_msg,
        partial: "chats/message",
        locals: { message: assistant_msg }
      )
    end
  end
end

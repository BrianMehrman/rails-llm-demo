Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new

  config.lograge.custom_options = lambda do |event|
    { timestamp: event.time.utc.iso8601(3) }
  end

  config.lograge.custom_payload do |controller|
    ctx = OpenTelemetry::Trace.current_span.context
    ctx.valid? ? { trace_id: ctx.trace_id.unpack1("H*"), span_id: ctx.span_id.unpack1("H*") } : {}
  end
end

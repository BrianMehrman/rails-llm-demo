Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new

  config.lograge.custom_options = lambda do |_event|
    # Rails 8.1's ActiveSupport::Notifications::Event#time returns a Float, not a
    # Time, so calling .utc on it raises. Use the emit-time wall clock instead —
    # precise span timing is carried by trace_id/span_id in the custom_payload.
    # Format matches the Fluent Bit `rails_json` parser (Time_Format %Y-%m-%dT%H:%M:%S.%LZ).
    { timestamp: Time.now.utc.iso8601(3) }
  end

  config.lograge.custom_payload do |controller|
    ctx = OpenTelemetry::Trace.current_span.context
    ctx.valid? ? { trace_id: ctx.trace_id.unpack1("H*"), span_id: ctx.span_id.unpack1("H*") } : {}
  end
end

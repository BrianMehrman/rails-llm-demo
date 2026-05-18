if ENV["OTEL_ENABLED"] == "true"
  require "opentelemetry/sdk"
  require "opentelemetry/exporter/otlp"
  require "opentelemetry/instrumentation/rails"
  require "opentelemetry/instrumentation/active_record"
  require "opentelemetry/instrumentation/http"

  OpenTelemetry::SDK.configure do |c|
    c.service_name    = ENV.fetch("OTEL_SERVICE_NAME", "rails-llm-demo")
    c.service_version = ENV.fetch("OTEL_SERVICE_VERSION", "1.0.0")

    c.use "OpenTelemetry::Instrumentation::Rails"
    c.use "OpenTelemetry::Instrumentation::ActiveRecord"
    c.use "OpenTelemetry::Instrumentation::Http"
  end
end

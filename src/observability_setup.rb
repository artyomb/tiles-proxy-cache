MAX_SQL_LOG_LENGTH = 100

class Sequel::Database
  def log_each(level, message)
    @loggers.each { |logger| logger.public_send(level, message.gsub(/X'[0-9A-Fa-f]{#{MAX_SQL_LOG_LENGTH + 1},}'/) do |match|
      "X'#{match[2, MAX_SQL_LOG_LENGTH]}...[TRUNCATED]'"
    end) }
  end
end

# Faraday: Selective disabling of OTEL tracing for HTTP requests
def setup_faraday_otel_patch
  return unless defined?(OpenTelemetry::Instrumentation::Faraday::Middlewares::Old::TracerMiddleware)

  OpenTelemetry::Instrumentation::Faraday::Middlewares::Old::TracerMiddleware.class_eval do
    alias_method :call_with_tracing, :call unless method_defined?(:call_with_tracing)

    def call(env)
      Thread.current[:skip_faraday_otel] ? app.call(env) : call_with_tracing(env)
    end
  end
end
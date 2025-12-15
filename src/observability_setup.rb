MAX_SQL_LOG_LENGTH = 100

class SqlBlobSanitizer
  def initialize(base_logger)
    @base_logger = base_logger
  end

  def <<(msg) = @base_logger << sanitize(msg)
  def info(msg) = @base_logger.info(sanitize(msg))
  def debug(msg) = @base_logger.debug(sanitize(msg))
  def warn(msg) = @base_logger.warn(sanitize(msg))
  def error(msg) = @base_logger.error(sanitize(msg))
  def fatal(msg) = @base_logger.fatal(sanitize(msg))

  private

  def sanitize(msg)
    text = msg.to_s
    text.gsub(/X'[0-9A-Fa-f]{#{MAX_SQL_LOG_LENGTH + 1},}'/) do |match|
      "X'#{match[2, MAX_SQL_LOG_LENGTH]}...[TRUNCATED]'"
    end
  end
end

def setup_sequel_logging
  return unless defined?(Sequel)

  Sequel::Database.after_initialize do |db|
    db.loggers.clear
    db.loggers << SqlBlobSanitizer.new(LOGGER)
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

module ObservabilityHelpers
  module_function
  
  def without_http_tracing
    Thread.current[:skip_faraday_otel] = true
    yield
  ensure
    Thread.current[:skip_faraday_otel] = false
  end
end

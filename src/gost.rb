raise 'libengine-gost-openssl not installed' unless system('dpkg -s libengine-gost-openssl > /dev/null 2>&1')

require 'openssl'
require 'ffi'

module OpenSSLFFI
  extend FFI::Library
  ffi_lib 'libcrypto.so'

  attach_function :ENGINE_load_builtin_engines, [], :void
  attach_function :ENGINE_by_id, [:string], :pointer
  attach_function :ENGINE_init, [:pointer], :int
  attach_function :ENGINE_set_default, [:pointer, :uint], :int
end

module GOSTEngine
  extend self

  def initialize_engine
    return if @initialized
    OpenSSLFFI.ENGINE_load_builtin_engines
    @gost_engine = OpenSSLFFI.ENGINE_by_id("gost") || raise('GOST engine not found')
    OpenSSLFFI.ENGINE_init(@gost_engine).zero? && raise('Failed to initialize GOST engine')
    @initialized = true
  end

  def with_gost(&block)
    initialize_engine
    OpenSSLFFI.ENGINE_set_default(@gost_engine, 0xFFFF).zero? && raise('Failed to set GOST engine')
    yield
  ensure
    OpenSSLFFI.ENGINE_set_default(@gost_engine, 0) if @initialized
  end
end

GOSTEngine.initialize_engine

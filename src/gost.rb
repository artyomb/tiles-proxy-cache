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

# Initialize GOST engine
OpenSSLFFI.ENGINE_load_builtin_engines
gost_engine = OpenSSLFFI.ENGINE_by_id("gost") || raise('GOST engine not found')
OpenSSLFFI.ENGINE_init(gost_engine).zero? && raise('Failed to initialize GOST engine')
OpenSSLFFI.ENGINE_set_default(gost_engine, 0xFFFF).zero? && raise('Failed to set GOST engine as default')

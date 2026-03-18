require "mkmf"

native = ENV["TPC_EXT_NATIVE"] == "1"
lto    = ENV["TPC_EXT_LTO"] == "1"

arch_flags =
  if native
    " -march=native -mtune=native"
  else
    " -march=x86-64 -mtune=generic"
  end

$CXXFLAGS += " -std=c++23 -O3#{arch_flags}#{lto ? ' -flto' : ''} -Wno-unused-function"
$CXXFLAGS += " -Wall -Wextra -Wpedantic"
$CXXFLAGS += " -fno-rtti"
$CPPFLAGS += " -I/usr/local/include"

$srcs = ["terrain_downsample_extension.cpp"]

unless pkg_config("libpng")
  abort "libpng not found. Please install libpng-dev"
end

create_makefile("terrain_downsample_extension")


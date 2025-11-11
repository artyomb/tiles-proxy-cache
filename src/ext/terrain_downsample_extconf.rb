require "mkmf"

$CXXFLAGS += " -std=c++23 -O3 -march=native -mtune=native -flto -Wno-unused-function"
$CXXFLAGS += " -Wall -Wextra -Wpedantic"
$CXXFLAGS += " -fno-rtti"
$CPPFLAGS += " -I/usr/local/include"

$srcs = ["terrain_downsample_extension.cpp"]

unless pkg_config("libpng")
  abort "libpng not found. Please install libpng-dev"
end

create_makefile("terrain_downsample_extension")


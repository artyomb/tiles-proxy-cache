require "mkmf"

$CXXFLAGS += " -std=c++23 -O3 -march=native -mtune=native -flto -Wno-unused-function"
$CXXFLAGS += " -Wall -Wextra -Wpedantic"
$CXXFLAGS += " -fno-rtti"
$CPPFLAGS += " -I/usr/local/include"

$srcs = ["lerc_extension.cpp"]
$LIBS += " -lLerc"

create_makefile("lerc_extension")
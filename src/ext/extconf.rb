require "mkmf"

$CFLAGS += " -Wno-unused-function"
$CPPFLAGS += " -I/usr/local/include"
$LIBS += " -lLerc"

create_makefile("lerc_extension")
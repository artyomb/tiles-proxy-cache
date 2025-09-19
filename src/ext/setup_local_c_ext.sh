#!/bin/bash
set -e

LERC_VERSION="4.0.0"
LERC_SHA256="91431c2b16d0e3de6cbaea188603359f87caed08259a645fd5a3805784ee30a0"
LERC_URL="https://github.com/Esri/lerc/archive/refs/tags/v${LERC_VERSION}.tar.gz"

for tool in cmake make curl ruby g++; do
    command -v $tool >/dev/null 2>&1 || { echo "Error: $tool required"; exit 1; }
done

echo "Building LERC..."
mkdir -p temp && cd temp
curl -fsSL "$LERC_URL" -o lerc.tar.gz
echo "${LERC_SHA256}  lerc.tar.gz" | sha256sum -c -
tar -xz --strip-components=1 -f lerc.tar.gz
cmake . -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX=/usr/local
make -j$(nproc) && sudo make install && sudo ldconfig
cd .. && rm -rf temp

echo "Building extension..."
ruby extconf.rb && make
echo "✅ Done: $(ls *.so)"

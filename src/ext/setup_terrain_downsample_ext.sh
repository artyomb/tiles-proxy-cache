#!/bin/bash
set -e

for tool in ruby g++ pkg-config; do
    command -v $tool >/dev/null 2>&1 || { echo "Error: $tool required"; exit 1; }
done

if ! pkg-config --exists libpng; then
    echo "Error: libpng not found. Please install libpng-dev"
    exit 1
fi

echo "Building terrain_downsample_extension..."
cd "$(dirname "$0")"
ruby terrain_downsample_extconf.rb && make
echo "✅ Done: $(ls terrain_downsample_extension.so 2>/dev/null || echo 'terrain_downsample_extension.so')"


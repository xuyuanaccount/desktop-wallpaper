#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
command_name="$1"
shift
cache="$PWD/.build/local"
mkdir -p "$cache"/{clang,cache,config,security}
export CLANG_MODULE_CACHE_PATH="$cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache/clang"
if [[ "${WALLPAPER_SWIFT_DISABLE_SANDBOX:-0}" == 1 ]]; then
    set -- --disable-sandbox "$@"
fi
exec swift "$command_name" --manifest-cache local \
    --cache-path "$cache/cache" --config-path "$cache/config" --security-path "$cache/security" "$@"

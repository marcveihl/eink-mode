#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift test --disable-sandbox
python3 scripts/test_cli.py .build/debug/eink

#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EXAMPLES="$ROOT/sources/xodus/crates/xodus-cli/examples"
mkdir -p "$EXAMPLES/bedrock_helper_parts" "$ROOT/logs"
cp "$ROOT/bedrock-helper.rs" "$EXAMPLES/bedrock_helper.rs"
cp "$ROOT/prepare-owned-game.rs" "$EXAMPLES/bedrock_helper_parts/prepare_owned_game.rs"
cargo +1.98.0 build --manifest-path "$ROOT/sources/xodus/Cargo.toml" \
  --release --locked -j6 -p xodus-cli --example bedrock_helper \
  > "$ROOT/logs/unified-helper-build.log" 2>&1

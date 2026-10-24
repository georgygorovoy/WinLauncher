#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
upstream_commit="4b42c46131fd5b53cae7588773cac2d601471c2f"
work="${TMPDIR:-/tmp}/winlauncher-xbox-helper-source"

for tool in git cargo protoc; do
  command -v "$tool" >/dev/null || {
    print -u2 "Missing build tool: $tool"
    exit 2
  }
done

if [[ ! -d "$work/.git" ]]; then
  git clone --filter=blob:none https://github.com/1JRobertson/bedrock-mac.git "$work"
fi
git -C "$work" fetch --depth=1 origin "$upstream_commit"
git -C "$work" checkout --detach "$upstream_commit"
[[ "$(git -C "$work" rev-parse HEAD)" == "$upstream_commit" ]]

python3 "$work/standalone-setup.py" --build-helper --jobs 4
if git -C "$work/sources/xodus" apply --reverse --check "$root/Sources/xodus-licensing-jwe-safe.patch"; then
  print "JWE license patch is already applied."
else
  git -C "$work/sources/xodus" apply --check "$root/Sources/xodus-licensing-jwe-safe.patch"
  git -C "$work/sources/xodus" apply "$root/Sources/xodus-licensing-jwe-safe.patch"
fi
cargo +1.98.0 test --manifest-path "$work/sources/xodus/Cargo.toml" \
  --locked --no-default-features -p xodus licensing_ticket_tests
cargo +1.98.0 build --manifest-path "$work/sources/xodus/Cargo.toml" \
  --release --locked --no-default-features -j 4 -p xodus-cli --example standalone_helper
install -d -m 700 "$root/bin"
install -m 700 "$work/sources/xodus/target/release/examples/standalone_helper" \
  "$root/bin/standalone_helper"
codesign --force --sign - "$root/bin/standalone_helper"
print "Built $root/bin/standalone_helper"

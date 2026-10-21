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
install -d -m 700 "$root/bin"
install -m 700 "$work/sources/xodus/target/release/examples/standalone_helper" \
  "$root/bin/standalone_helper"
codesign --force --sign - "$root/bin/standalone_helper"
print "Built $root/bin/standalone_helper"

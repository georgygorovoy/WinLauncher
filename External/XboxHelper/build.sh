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

# Upstream setup verifies its own pristine patch state. Undo this project's
# patches from a previous run so the build can be repeated in the same tree.
if [[ -d "$work/sources/xodus" ]]; then
  for patch in xodus-xbox-jwe-ticket-retry.patch xodus-private-account-store.patch xodus-licensing-jwe-safe.patch; do
    if git -C "$work/sources/xodus" apply --reverse --check "$root/Sources/$patch" 2>/dev/null; then
      git -C "$work/sources/xodus" apply --reverse "$root/Sources/$patch"
    fi
  done
fi
python3 "$work/standalone-setup.py" --build-helper --jobs 4
cp "$root/Sources/standalone-helper.rs" \
  "$work/sources/xodus/crates/xodus-cli/examples/standalone_helper.rs"
cp "$root/Sources/standalone-xvd.rs" \
  "$work/sources/xodus/crates/xodus-cli/examples/standalone_xvd.rs"
if git -C "$work/sources/xodus" apply --reverse --check "$root/Sources/xodus-licensing-jwe-safe.patch"; then
  print "JWE license patch is already applied."
else
  git -C "$work/sources/xodus" apply --check "$root/Sources/xodus-licensing-jwe-safe.patch"
  git -C "$work/sources/xodus" apply "$root/Sources/xodus-licensing-jwe-safe.patch"
fi
if git -C "$work/sources/xodus" apply --reverse --check "$root/Sources/xodus-private-account-store.patch"; then
  print "Private account store patch is already applied."
else
  git -C "$work/sources/xodus" apply --check "$root/Sources/xodus-private-account-store.patch"
  git -C "$work/sources/xodus" apply "$root/Sources/xodus-private-account-store.patch"
fi
if git -C "$work/sources/xodus" apply --reverse --check "$root/Sources/xodus-xbox-jwe-ticket-retry.patch"; then
  print "Xbox JWE ticket retry patch is already applied."
else
  git -C "$work/sources/xodus" apply --check "$root/Sources/xodus-xbox-jwe-ticket-retry.patch"
  git -C "$work/sources/xodus" apply "$root/Sources/xodus-xbox-jwe-ticket-retry.patch"
fi
cargo +1.98.0 test --manifest-path "$work/sources/xodus/Cargo.toml" \
  --locked --no-default-features -p xodus licensing_ticket_tests
cargo +1.98.0 test --manifest-path "$work/sources/xodus/Cargo.toml" \
  --locked --no-default-features --features account-file \
  -p xodus-cli --example standalone_helper
# Embed an Info.plist: macOS 27 never shows windows of an executable without
# one, which left the Microsoft sign-in window invisible.
cargo +1.98.0 rustc --manifest-path "$work/sources/xodus/Cargo.toml" \
  --release --locked --no-default-features --features account-file \
  -j 4 -p xodus-cli --example standalone_helper -- \
  -C "link-arg=-Wl,-sectcreate,__TEXT,__info_plist,$root/Sources/standalone-helper-Info.plist"
/usr/bin/otool -s __TEXT __info_plist "$work/sources/xodus/target/release/examples/standalone_helper" \
  | /usr/bin/grep -q 'Contents of (__TEXT,__info_plist) section' || {
    print -u2 "Info.plist was not embedded into the helper"
    exit 1
  }
install -d -m 700 "$root/bin"
install -m 700 "$work/sources/xodus/target/release/examples/standalone_helper" \
  "$root/bin/standalone_helper"
codesign --force --sign - "$root/bin/standalone_helper"
print "Built $root/bin/standalone_helper"

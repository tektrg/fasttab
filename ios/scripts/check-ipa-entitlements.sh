#!/bin/bash
# Fail if an exported IPA (or a fixture .app/.appex dir) carries development-only
# entitlements, which App Store upload rejects (90045/90046; FastTab build 1, 2026-10-30).
# Usage: check-ipa-entitlements.sh <file.ipa | dir-with-bundles>
set -uo pipefail
src="${1:?usage: $0 <ipa|dir>}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -f "$src" ]; then unzip -q "$src" -d "$tmp" || exit 2; root="$tmp"; else root="$src"; fi
fail=0; n=0
while IFS= read -r -d '' b; do
  n=$((n+1))
  if [ -f "$b/entitlements.plist" ]; then ent=$(plutil -convert xml1 -o - "$b/entitlements.plist")  # fixture
  else ent=$(codesign -d --entitlements - --xml "$b" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null); fi
  bad=$(printf '%s' "$ent" | python3 -I -c '
import sys, plistlib
e = plistlib.loads(sys.stdin.buffer.read() or b"<plist><dict/></plist>")
out = []
if e.get("aps-environment") == "development": out.append("aps-environment=development")
if str(e.get("com.apple.developer.icloud-container-environment", "")).lower() == "development": out.append("icloud-container-environment=Development")
if "com.apple.developer.icloud-container-development-container-identifiers" in e: out.append("icloud-container-development-container-identifiers present")
if e.get("get-task-allow") is True: out.append("get-task-allow=true")
print("; ".join(out))')
  if [ -n "$bad" ]; then echo "FAIL $(basename "$b"): $bad"; fail=1; else echo "ok   $(basename "$b")"; fi
done < <(find "$root" \( -name '*.app' -o -name '*.appex' \) -type d -print0)
[ $n -eq 0 ] && { echo "FAIL: no app bundles found"; exit 2; }
exit $fail

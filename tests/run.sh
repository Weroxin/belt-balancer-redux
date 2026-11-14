#!/bin/sh
# Run the headless test scenario against this mod in a throwaway Factorio profile.
# usage: tests/run.sh [test|bench|bench-nomod|bench-onlyN] [factorio executable]
#   SPACE_AGE=1 tests/run.sh   also enables space-age, quality and elevated-rails
set -e
arg=${1:-test}
exe=${2:-${FACTORIO:-"/e/SteamLibrary/steamapps/common/Factorio/bin/x64/factorio.exe"}}
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
p() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

dlc=false; [ -n "$SPACE_AGE" ] && dlc=true
mkdir -p "$tmp/mods/belt-balancer-redux" "$tmp/write/scenarios"
(cd "$here/.." && tar --exclude=./tests -cf - .) | tar -xf - -C "$tmp/mods/belt-balancer-redux"
cp -r "$here/bb-test" "$tmp/write/scenarios/"
cat > "$tmp/mods/mod-list.json" <<EOF
{"mods":[{"name":"base","enabled":true},{"name":"belt-balancer-redux","enabled":true},
{"name":"space-age","enabled":$dlc},{"name":"quality","enabled":$dlc},{"name":"elevated-rails","enabled":$dlc}]}
EOF
printf '[path]\nread-data=__PATH__executable__/../../data\nwrite-data=%s\n' "$(p "$tmp/write")" > "$tmp/config.ini"

"$exe" -c "$(p "$tmp/config.ini")" --mod-directory "$(p "$tmp/mods")" \
    --test-scenario bb-test --test-arg "$arg" > "$tmp/out.txt" 2>&1 && status=0 || status=$?
grep -E -i "PASS|FAIL|SKIP|BENCH|Error|locale|Test (passed|failed)" "$tmp/out.txt" || cat "$tmp/out.txt"
exit $status

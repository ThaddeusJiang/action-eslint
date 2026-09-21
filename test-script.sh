#!/usr/bin/env bash
set -eu

ACTION_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo/src" "$TEST_ROOT/repo/other"
export TEST_ARGS="$TEST_ROOT/args"
export TEST_REPORT="$TEST_ROOT/report.json"
cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$TEST_ROOT/bin/npx" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *'--version'* ]]; then
  echo v8.57.1
else
  printf '%s\0' "$@" > "$TEST_ARGS"
  echo '{"diagnostics":[]}'
fi
STUB
cat > "$TEST_ROOT/bin/reviewdog" <<'STUB'
#!/bin/sh
cat > "$TEST_REPORT"
STUB
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
cd "$TEST_ROOT/repo"
git init -q
git config user.name Test
git config user.email test@example.invalid
printf 'old\n' > src/changed.js
printf 'old\n' > src/unchanged.js
printf 'old\n' > src/deleted.js
git add .
git commit -qm base
BASE=$(git rev-parse HEAD)
printf 'new\n' > src/changed.js
printf 'new\n' > 'src/space name.js'
printf 'new\n' > src/typed.ts
printf 'new\n' > other/outside.js
printf 'docs\n' > README.md
git rm -q src/deleted.js
git add .
git commit -qm change
HEAD=$(git rev-parse HEAD)

run_action() {
  rm -f "$TEST_ARGS"
  GITHUB_WORKSPACE="$PWD" GITHUB_ACTION_PATH="$ACTION_DIR" INPUT_WORKDIR=. \
    INPUT_ONLY_CHANGED="${ONLY_CHANGED:-true}" INPUT_ESLINT_FLAGS="$1" \
    BASE_REF="$2" HEAD_REF="$3" \
    bash "$ACTION_DIR/script.sh" > "$TEST_ROOT/output" 2>&1
}

assert_args() {
  local actual=() arg
  while IFS= read -r -d '' arg; do actual+=("$arg"); done < "$TEST_ARGS"
  local expected=(--no-install eslint -f "$ACTION_DIR/eslint-formatter-rdjson/index.js" "$@")
  if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
    printf 'Unexpected arguments:' >&2
    printf ' %q' "${actual[@]}" >&2
    echo >&2
    return 1
  fi
  local i
  for ((i=0; i<${#expected[@]}; i++)); do
    if [[ "${actual[i]}" != "${expected[i]}" ]]; then
      printf 'Argument %s: expected %q, got %q\n' "$i" "${expected[i]}" "${actual[i]}" >&2
      return 1
    fi
  done
}

run_action . "$BASE" "$HEAD"
assert_args -- other/outside.js src/changed.js 'src/space name.js'

run_action 'src/ --ext .js,.ts --ignore-pattern skip.js --quiet' "$BASE" "$HEAD"
assert_args --ext .js,.ts --ignore-pattern skip.js --quiet -- src/changed.js 'src/space name.js' src/typed.ts

run_action '"src/space name.js" --rule "semi: [2, never]"' "$BASE" "$HEAD"
assert_args --rule 'semi: [2, never]' -- 'src/space name.js'

run_action $'src/\n--quiet' "$BASE" "$HEAD"
assert_args --quiet -- src/changed.js 'src/space name.js'

run_action . "$HEAD" "$HEAD"
test ! -e "$TEST_ARGS"

if run_action . "$BASE" invalid-head; then
  echo 'An invalid diff must fail, not report no changed files' >&2
  exit 1
fi
test ! -e "$TEST_ARGS"

if run_action . invalid-base "$HEAD"; then
  echo 'A failed base fetch must fail' >&2
  exit 1
fi
test ! -e "$TEST_ARGS"

run_action . '' "$HEAD"
assert_args .

ONLY_CHANGED=false run_action 'src/ --quiet' "$BASE" "$HEAD"
assert_args src/ --quiet

# Keep network installation and GitHub publication stubbed, but run the actual
# installed ESLint and formatter to prove that unchanged files are not linted.
export REAL_ESLINT="$ACTION_DIR/node_modules/.bin/eslint"
cat > "$TEST_ROOT/bin/npx" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *'--version'* ]]; then
  exec "$REAL_ESLINT" --version
fi
shift 2
exec "$REAL_ESLINT" "$@"
STUB
run_action "src/ --config $ACTION_DIR/.eslintrc.js" "$BASE" "$HEAD"
node - "$TEST_REPORT" "$PWD" <<'NODE'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const files = [...new Set(report.diagnostics.map(item =>
  path.relative(fs.realpathSync(process.argv[3]), fs.realpathSync(item.location.path))))].sort()
assert.deepEqual(files, ['src/changed.js', 'src/space name.js'])
NODE
echo 'script behavior: 10 scenarios passed (including real ESLint)'

#!/usr/bin/env bash

cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit 1

TEMP_PATH="$(mktemp -d)"
trap 'rm -rf "$TEMP_PATH"' EXIT
PATH="${TEMP_PATH}:$PATH"
export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"
ESLINT_FORMATTER="${GITHUB_ACTION_PATH}/eslint-formatter-rdjson/index.js"

echo '::group::🐶 Installing reviewdog ... https://github.com/reviewdog/reviewdog'
curl -sfL https://raw.githubusercontent.com/reviewdog/reviewdog/fd59714416d6d9a1c0692d872e38e7f8448df4fc/install.sh | sh -s -- -b "${TEMP_PATH}" "${REVIEWDOG_VERSION}" 2>&1
echo '::endgroup::'

if ! npx --no-install -c 'eslint --version'; then
  echo '::group:: Installing eslint with npm ...'
  npm install || exit $?
  echo '::endgroup::'
fi

echo "eslint version:$(npx --no-install -c 'eslint --version')"

# Preserve quoted arguments and globs without evaluating shell code in inputs.
printf '%s\n' "${INPUT_ESLINT_FLAGS:-.}" | xargs printf '%s\0' > "$TEMP_PATH/flags" || exit $?
ESLINT_FLAGS_ARRAY=()
while IFS= read -r -d '' flag; do
  ESLINT_FLAGS_ARRAY+=("$flag")
done < "$TEMP_PATH/flags"
ESLINT_ARGS=(-f "${ESLINT_FORMATTER}")

if [ "${INPUT_ONLY_CHANGED}" = "true" ] && [ -n "${BASE_REF}" ] && [ -n "${HEAD_REF}" ]; then
  echo '::group:: Getting changed files list'
  ESLINT_PATHS=()
  EXTENSIONS=(js)
  i=0
  while (( i < ${#ESLINT_FLAGS_ARRAY[@]} )); do
    flag=${ESLINT_FLAGS_ARRAY[i]}
    case "$flag" in
      --)
        ESLINT_PATHS+=("${ESLINT_FLAGS_ARRAY[@]:i+1}")
        break
        ;;
      --ext=*)
        IFS=, read -r -a EXTENSIONS <<< "${flag#*=}"
        ESLINT_ARGS+=("$flag")
        ;;
      --*=*) ESLINT_ARGS+=("$flag") ;;
      -c|--config|--env|--ext|--global|--parser|--parser-options|--resolve-plugins-relative-to|--plugin|--rule|--rulesdir|--fix-type|--ignore-path|--ignore-pattern|--stdin-filename|--max-warnings|-o|--output-file|-f|--format|--cache-file|--cache-location|--cache-strategy|--print-config|--flag|--concurrency|--report-unused-disable-directives-severity)
        ((i+=1))
        if (( i >= ${#ESLINT_FLAGS_ARRAY[@]} )); then
          echo "Missing value for $flag" >&2
          exit 1
        fi
        value=${ESLINT_FLAGS_ARRAY[i]}
        ESLINT_ARGS+=("$flag" "$value")
        if [[ "$flag" == --ext ]]; then
          IFS=, read -r -a EXTENSIONS <<< "$value"
        fi
        ;;
      --no-*|--eslintrc|--ignore|--inline-config|--report-unused-disable-directives|--fix|--fix-dry-run|--stdin|--quiet|--color|--exit-on-fatal-error|--cache|--debug|-h|--help|-v|--version|--pass-on-no-patterns|--stats)
        ESLINT_ARGS+=("$flag")
        ;;
      -*)
        echo "Unsupported only_changed option: $flag. Use its --option=value form." >&2
        exit 1
        ;;
      *) ESLINT_PATHS+=("$flag") ;;
    esac
    ((i+=1))
  done

  if (( ${#ESLINT_PATHS[@]} == 0 )); then ESLINT_PATHS=(.); fi
  PATHSPECS=()
  for path in "${ESLINT_PATHS[@]}"; do
    if [[ -d "$path" ]]; then
      prefix="${path%/}/"
      prefix="${prefix#./}"
      for extension in "${EXTENSIONS[@]}"; do
        PATHSPECS+=(":(glob)${prefix}**/*.${extension#.}")
      done
    else
      case "$path" in
        *'{'*|*'}'*)
          echo 'only_changed uses Git path globs; list brace alternatives separately.' >&2
          exit 1
          ;;
        *'*'*|*'?'*|*'['*) PATHSPECS+=(":(glob)$path") ;;
        *) PATHSPECS+=(":(literal)$path") ;;
      esac
    fi
  done

  if ! git cat-file -e "${BASE_REF}^{commit}" 2>/dev/null; then
    git fetch --depth 1 origin "${BASE_REF}" || exit $?
  fi
  git diff --relative --diff-filter=ACMR --name-only -z \
    "${BASE_REF}..${HEAD_REF}" -- "${PATHSPECS[@]}" > "$TEMP_PATH/changed-files" || exit $?

  CHANGED_FILES=()
  while IFS= read -r -d '' file; do
    CHANGED_FILES+=("$file")
  done < "$TEMP_PATH/changed-files"

  if (( ${#CHANGED_FILES[@]} == 0 )); then
    echo 'No changed lint targets, skipping'
    echo '::endgroup::'
    exit 0
  fi
  printf '%s\n' "${CHANGED_FILES[@]}"
  ESLINT_ARGS+=(-- "${CHANGED_FILES[@]}")
  echo '::endgroup::'
else
  if [[ "${INPUT_ONLY_CHANGED}" == true ]]; then
    echo 'BASE_REF or HEAD_REF is not available. Running eslint on all files.'
  fi
  ESLINT_ARGS+=("${ESLINT_FLAGS_ARRAY[@]}")
fi

echo '::group:: Running eslint with reviewdog 🐶 ...'
# shellcheck disable=SC2086
npx --no-install eslint "${ESLINT_ARGS[@]}" \
  | reviewdog -f=rdjson \
      -name="${INPUT_TOOL_NAME}" \
      -reporter="${INPUT_REPORTER:-github-pr-review}" \
      -filter-mode="${INPUT_FILTER_MODE}" \
      -fail-level="${INPUT_FAIL_LEVEL}" \
      -fail-on-error="${INPUT_FAIL_ON_ERROR}" \
      -level="${INPUT_LEVEL}" \
      ${INPUT_REVIEWDOG_FLAGS}

reviewdog_rc=$?
echo '::endgroup::'
exit $reviewdog_rc

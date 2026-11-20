#!/usr/bin/env bash
# Source this helper; retry only network/daemon/resource failures, never
# deterministic compiler/configuration errors. Preserve the command's exit code.
ffmpegpp_gradle_retry() {
  local attempts="${FFMPEGPP_RETRY_MAX_ATTEMPTS:-5}"
  local base_delay="${FFMPEGPP_RETRY_BASE_DELAY:-20}"
  if [[ ! "$attempts" =~ ^[1-9][0-9]*$ ]] || (( attempts > 10 )) ||
     [[ ! "$base_delay" =~ ^[0-9]+$ ]] || (( base_delay > 180 )); then
    echo "ERROR: retry attempts must be 1..10 and delay must be 0..180 seconds" >&2
    return 2
  fi
  if (( $# == 0 )); then
    echo "ERROR: no build command was supplied" >&2
    return 2
  fi
  local attempt log_path rc delay
  local -a pipeline_status
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    log_path=$(mktemp "${TMPDIR:-/tmp}/ffmpegpp-gradle-attempt.XXXXXX") || return 1
    echo "======== ATTEMPT $attempt/$attempts ========"
    echo "Gradle attempt log: $log_path"
    if "$@" 2>&1 | tee "$log_path"; then
      pipeline_status=("${PIPESTATUS[@]}")
    else
      pipeline_status=("${PIPESTATUS[@]}")
    fi
    rc=${pipeline_status[0]}
    if (( pipeline_status[1] != 0 )); then
      echo "ERROR: could not write the build log (tee rc=${pipeline_status[1]})" >&2
      return "${pipeline_status[1]}"
    fi
    if (( rc == 0 )); then
      echo "BUILD SUCCESS on attempt $attempt"
      return 0
    fi
    echo "attempt $attempt failed (rc=$rc)" >&2
    if ! grep -Eiq '429|Too Many Requests|status code 5[0-9][0-9]|timed? out|timeout|Connection (reset|refused|timed out)|Temporary failure in name resolution|Could not resolve host|Remote host terminated|daemon disappeared|Gradle build daemon disappeared|OutOfMemoryError|Cannot allocate memory|Killed' "$log_path" &&
       (( rc != 137 && rc != 143 )); then
      echo "ERROR: non-transient failure; not retrying a compiler or configuration error" >&2
      return "$rc"
    fi
    if (( attempt == attempts )); then
      echo "ALL ATTEMPTS FAILED (last rc=$rc)" >&2
      return "$rc"
    fi
    delay=$((base_delay * 2 ** (attempt - 1)))
    (( delay > 180 )) && delay=180
    echo "Transient failure; retrying in ${delay}s" >&2
    if (( delay > 0 )); then sleep "$delay"; fi
  done
}

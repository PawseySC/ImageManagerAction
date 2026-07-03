#!/usr/bin/env bash
# shellcheck shell=bash
# retry <attempts> <initial_delay_seconds> <command...>
# Exponential backoff: delay doubles after each failed attempt.
retry() {
  local attempts="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      echo "✗ Command failed after $n attempts: $*"
      return 1
    fi
    echo "↻ Attempt $n failed; retrying in ${delay}s…"
    sleep "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
  done
}

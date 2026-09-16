#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED_BIN="${OMASHORT_BIN:-${HOME}/.local/bin/omashort-native}"
LOCAL_BIN="${ROOT_DIR}/native/omashort-native"

if [[ -x "${INSTALLED_BIN}" ]]; then
  exec "${INSTALLED_BIN}" "$@"
fi

if [[ -x "${LOCAL_BIN}" ]]; then
  cd "${ROOT_DIR}/native"
  exec "${LOCAL_BIN}" "$@"
fi

printf 'OmaShort binary not found. Build it with:\n' >&2
printf '  cd "%s/native" && qmake6 omashort-native.pro && make -j4\n' "${ROOT_DIR}" >&2
exit 1

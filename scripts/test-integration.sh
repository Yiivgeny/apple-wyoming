#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
host="${WYOMING_HOST:-127.0.0.1}"
port="${WYOMING_PORT:-10700}"

for version in 1.7.2 1.10.0; do
  echo "Testing official Wyoming client ${version}"
  uv run --with "wyoming==${version}" \
    python "${project_dir}/Tests/Integration/test_wyoming.py" \
    --host "${host}" --port "${port}"
done

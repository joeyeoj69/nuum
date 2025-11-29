#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCENARIO="${ROOT_DIR}/config/backtest/sample_scenario_vol_world.json"
ARTIFACTS_DIR="${ROOT_DIR}/artifacts/backtest_smoke"

mkdir -p "${ARTIFACTS_DIR}"

PYTHONPATH="${ROOT_DIR}/python:${PYTHONPATH:-}"
export PYTHONPATH

python3 -m nuum.backtest.cli_runner \
  --scenario "${SCENARIO}" \
  --artifacts-dir "${ARTIFACTS_DIR}" \
  --print-summary

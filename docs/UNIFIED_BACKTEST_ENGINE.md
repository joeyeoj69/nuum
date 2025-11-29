# NUUM Unified Backtest Engine (studio1, volatility world-model)

This module provides a single backtesting engine capable of replaying UW, gamma, and vol strategies
off lake1 state and emitting standardized performance artifacts.

## Layout

- `python/nuum/backtest/`
  - `scenario.py` – scenario specification (universe, strategies, risk, fees, world-model).
  - `data_adapter.py` – simplified lake1 data adapter (synthetic or file-based).
  - `strategies.py` – UW, gamma, and vol strategy adapters.
  - `engine.py` – unified backtest engine and result model.
  - `artifacts.py` – artifact writer (equity curve, trades, summary, diagnostics).
  - `cli_runner.py` – Python CLI entrypoint.

- `cli/backtest/`
  - `nuum_backtest_run.sh` – shell wrapper for the Python CLI.
  - `nuum_backtest_smoke.sh` – smoke test runner using the sample scenario.

- `config/backtest/sample_scenario_vol_world.json` – example scenario spec.

- `tests/backtest/test_unified_engine.py` – basic end-to-end test.

## Usage

From the repo root:

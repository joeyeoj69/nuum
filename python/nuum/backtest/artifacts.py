#!/usr/bin/env python3
import json
from dataclasses import asdict
from pathlib import Path
from typing import Dict, Any

from .engine import BacktestResult
from .scenario import BacktestScenario


class ArtifactWriter:
    def __init__(self, base_dir: str):
        self.base_dir = Path(base_dir)

    def write_all(self, scenario: BacktestScenario, result: BacktestResult) -> Dict[str, str]:
        out_dir = self.base_dir / scenario.scenario_id
        out_dir.mkdir(parents=True, exist_ok=True)

        paths: Dict[str, str] = {}

        scenario_path = out_dir / "scenario.json"
        with scenario_path.open("w", encoding="utf-8") as f:
            json.dump(scenario.to_dict(), f, indent=2, sort_keys=True)
        paths["scenario"] = str(scenario_path)

        equity_path = out_dir / "equity_curve.json"
        with equity_path.open("w", encoding="utf-8") as f:
            json.dump(result.equity_curve, f, indent=2, sort_keys=True)
        paths["equity_curve"] = str(equity_path)

        trades_path = out_dir / "trades.json"
        with trades_path.open("w", encoding="utf-8") as f:
            json.dump(result.trades, f, indent=2, sort_keys=True)
        paths["trades"] = str(trades_path)

        summary_path = out_dir / "summary.json"
        with summary_path.open("w", encoding="utf-8") as f:
            json.dump(result.summary, f, indent=2, sort_keys=True)
        paths["summary"] = str(summary_path)

        diag_path = out_dir / "diagnostics.txt"
        with diag_path.open("w", encoding="utf-8") as f:
            f.write("NUUM Unified Backtest Diagnostics\n")
            f.write(f"Scenario: {scenario.scenario_id}\n")
            f.write(f"World model: {scenario.world_model}\n")
            f.write(f"Lake1 env: {scenario.lake1_env}\n")
            f.write(f"Universe: {scenario.universe.universe_id}\n")
            f.write(f"Symbols: {', '.join(scenario.universe.symbols)}\n")
            f.write(f"Strategies: {[s.strategy_id for s in scenario.strategies]}\n")
            f.write(f"Summary: {json.dumps(result.summary, sort_keys=True)}\n")
        paths["diagnostics"] = str(diag_path)

        return paths

#!/usr/bin/env python3
from dataclasses import dataclass, asdict
from datetime import datetime
from typing import Dict, List, Any

from .scenario import BacktestScenario
from .data_adapter import Lake1DataAdapter, MarketBar
from .strategies import build_strategy, BaseStrategy


@dataclass
class BacktestResult:
    scenario_id: str
    start_ts: datetime
    end_ts: datetime
    equity_curve: List[Dict[str, Any]]
    trades: List[Dict[str, Any]]
    summary: Dict[str, Any]


class BacktestEngine:
    def __init__(self, scenario: BacktestScenario):
        self.scenario = scenario
        self.strategies: List[BaseStrategy] = [
            build_strategy(s.kind, s.strategy_id, s.params) for s in scenario.strategies
        ]

    def run(self) -> BacktestResult:
        adapter = Lake1DataAdapter(
            universe_symbols=self.scenario.universe.symbols,
            start_ts=self.scenario.start_ts,
            end_ts=self.scenario.end_ts,
            state_path=self.scenario.universe.lake1_state_path,
        )
        equity_curve: List[Dict[str, Any]] = []
        all_trades: List[Dict[str, Any]] = []
        last_ts: datetime | None = None
        equity = 0.0
        peak_equity = 0.0
        max_drawdown = 0.0

        for bar in adapter.iter_bars():
            last_ts = bar.ts
            prices: Dict[str, float] = {bar.symbol: bar.price}
            for strat in self.strategies:
                strat.on_bar(bar)
            equity = 0.0
            for strat in self.strategies:
                equity += strat.mark_to_market(prices)
            peak_equity = max(peak_equity, equity)
            dd = 0.0 if peak_equity == 0 else (peak_equity - equity) / max(1e-9, peak_equity)
            max_drawdown = max(max_drawdown, dd)
            equity_curve.append(
                {
                    "ts": bar.ts.isoformat(),
                    "equity": equity,
                    "max_drawdown": max_drawdown,
                }
            )

        for strat in self.strategies:
            for t in strat.trades:
                all_trades.append(
                    {
                        "ts": t.ts.isoformat(),
                        "symbol": t.symbol,
                        "qty": t.qty,
                        "price": t.price,
                        "strategy_id": t.strategy_id,
                    }
                )

        start_ts = self.scenario.start_ts
        end_ts = last_ts or self.scenario.end_ts
        summary = {
            "scenario_id": self.scenario.scenario_id,
            "start_ts": start_ts.isoformat(),
            "end_ts": end_ts.isoformat(),
            "final_equity": equity,
            "max_drawdown": max_drawdown,
            "num_trades": len(all_trades),
            "num_points": len(equity_curve),
        }
        return BacktestResult(
            scenario_id=self.scenario.scenario_id,
            start_ts=start_ts,
            end_ts=end_ts,
            equity_curve=equity_curve,
            trades=all_trades,
            summary=summary,
        )

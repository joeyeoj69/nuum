#!/usr/bin/env python3
import dataclasses
import json
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Any


def _parse_dt(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


@dataclass
class UniverseSpec:
    universe_id: str
    symbols: List[str]
    lake1_snapshot_ts: Optional[str] = None
    lake1_state_path: Optional[str] = None

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "UniverseSpec":
        return UniverseSpec(
            universe_id=data["universe_id"],
            symbols=list(data.get("symbols", [])),
            lake1_snapshot_ts=data.get("lake1_snapshot_ts"),
            lake1_state_path=data.get("lake1_state_path"),
        )


@dataclass
class StrategySpec:
    strategy_id: str
    kind: str  # "uw", "gamma", "vol"
    params: Dict[str, Any] = field(default_factory=dict)

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "StrategySpec":
        return StrategySpec(
            strategy_id=data["strategy_id"],
            kind=data["kind"],
            params=dict(data.get("params", {})),
        )


@dataclass
class RiskSpec:
    max_gross_notional: float
    max_leverage: float
    max_drawdown: float
    other_limits: Dict[str, Any] = field(default_factory=dict)

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "RiskSpec":
        return RiskSpec(
            max_gross_notional=float(data["max_gross_notional"]),
            max_leverage=float(data["max_leverage"]),
            max_drawdown=float(data["max_drawdown"]),
            other_limits=dict(data.get("other_limits", {})),
        )


@dataclass
class FeeSpec:
    commission_per_contract: float
    slippage_bps: float
    borrow_cost_bps: float
    other_fees: Dict[str, Any] = field(default_factory=dict)

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "FeeSpec":
        return FeeSpec(
            commission_per_contract=float(data["commission_per_contract"]),
            slippage_bps=float(data["slippage_bps"]),
            borrow_cost_bps=float(data["borrow_cost_bps"]),
            other_fees=dict(data.get("other_fees", {})),
        )


@dataclass
class BacktestScenario:
    scenario_id: str
    description: str
    start_ts: datetime
    end_ts: datetime
    universe: UniverseSpec
    strategies: List[StrategySpec]
    risk: RiskSpec
    fees: FeeSpec
    lake1_env: str = "studio1"
    world_model: str = "volatility"
    artifacts_dir: str = "artifacts"

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "BacktestScenario":
        universe = UniverseSpec.from_dict(data["universe"])
        strategies = [StrategySpec.from_dict(s) for s in data.get("strategies", [])]
        risk = RiskSpec.from_dict(data["risk"])
        fees = FeeSpec.from_dict(data["fees"])
        return BacktestScenario(
            scenario_id=data["scenario_id"],
            description=data.get("description", ""),
            start_ts=_parse_dt(data["start_ts"]),
            end_ts=_parse_dt(data["end_ts"]),
            universe=universe,
            strategies=strategies,
            risk=risk,
            fees=fees,
            lake1_env=data.get("lake1_env", "studio1"),
            world_model=data.get("world_model", "volatility"),
            artifacts_dir=data.get("artifacts_dir", "artifacts"),
        )

    @staticmethod
    def load(path: str) -> "BacktestScenario":
        p = Path(path)
        with p.open("r", encoding="utf-8") as f:
            data = json.load(f)
        return BacktestScenario.from_dict(data)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "scenario_id": self.scenario_id,
            "description": self.description,
            "start_ts": self.start_ts.isoformat(),
            "end_ts": self.end_ts.isoformat(),
            "universe": dataclasses.asdict(self.universe),
            "strategies": [dataclasses.asdict(s) for s in self.strategies],
            "risk": dataclasses.asdict(self.risk),
            "fees": dataclasses.asdict(self.fees),
            "lake1_env": self.lake1_env,
            "world_model": self.world_model,
            "artifacts_dir": self.artifacts_dir,
        }

    def dump(self, path: str) -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2, sort_keys=True)

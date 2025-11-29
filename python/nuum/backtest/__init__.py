#!/usr/bin/env python3
"""
NUUM unified backtesting engine package.

This package provides:
- Scenario specification models
- Data adapters for lake1 state
- Strategy adapters (UW, gamma, vol)
- A modular backtest runner
- Performance artifact generation
"""
from .scenario import BacktestScenario, UniverseSpec, StrategySpec, RiskSpec, FeeSpec
from .engine import BacktestEngine, BacktestResult
from .artifacts import ArtifactWriter

__all__ = [
    "BacktestScenario",
    "UniverseSpec",
    "StrategySpec",
    "RiskSpec",
    "FeeSpec",
    "BacktestEngine",
    "BacktestResult",
    "ArtifactWriter",
]

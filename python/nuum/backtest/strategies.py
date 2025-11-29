#!/usr/bin/env python3
from dataclasses import dataclass
from typing import Dict, List, Any
from datetime import datetime

from .data_adapter import MarketBar


@dataclass
class Position:
    symbol: str
    qty: float
    avg_price: float


@dataclass
class Trade:
    ts: datetime
    symbol: str
    qty: float
    price: float
    strategy_id: str


class BaseStrategy:
    def __init__(self, strategy_id: str, params: Dict[str, Any]):
        self.strategy_id = strategy_id
        self.params = params
        self.positions: Dict[str, Position] = {}
        self.trades: List[Trade] = []

    def on_bar(self, bar: MarketBar) -> None:
        raise NotImplementedError

    def mark_to_market(self, prices: Dict[str, float]) -> float:
        pnl = 0.0
        for pos in self.positions.values():
            price = prices.get(pos.symbol, pos.avg_price)
            pnl += pos.qty * (price - pos.avg_price)
        return pnl

    def _trade(self, ts: datetime, symbol: str, qty: float, price: float) -> None:
        if qty == 0:
            return
        pos = self.positions.get(symbol)
        if pos is None:
            self.positions[symbol] = Position(symbol=symbol, qty=qty, avg_price=price)
        else:
            new_qty = pos.qty + qty
            if new_qty == 0:
                self.positions.pop(symbol, None)
            else:
                new_avg = (pos.avg_price * pos.qty + price * qty) / new_qty
                pos.qty = new_qty
                pos.avg_price = new_avg
        self.trades.append(Trade(ts=ts, symbol=symbol, qty=qty, price=price, strategy_id=self.strategy_id))


class UWStrategy(BaseStrategy):
    """
    Underwriting-style strategy: scale exposure with price trend.
    """

    def on_bar(self, bar: MarketBar) -> None:
        trend_sensitivity = float(self.params.get("trend_sensitivity", 0.1))
        target_notional = trend_sensitivity * (bar.price - 100.0)
        current_qty = self.positions.get(bar.symbol, Position(bar.symbol, 0.0, bar.price)).qty
        current_notional = current_qty * bar.price
        delta_notional = target_notional - current_notional
        qty = delta_notional / bar.price if bar.price != 0 else 0.0
        if abs(qty) * bar.price < 1e-6:
            return
        self._trade(bar.ts, bar.symbol, qty, bar.price)


class GammaStrategy(BaseStrategy):
    """
    Gamma strategy: trade against price moves, scaled by implied vol.
    """

    def on_bar(self, bar: MarketBar) -> None:
        gamma_scale = float(self.params.get("gamma_scale", 0.05))
        ref_price = float(self.params.get("ref_price", 100.0))
        move = (bar.price - ref_price) / ref_price
        qty = -gamma_scale * move * (1.0 + bar.iv)
        if abs(qty) * bar.price < 1e-6:
            return
        self._trade(bar.ts, bar.symbol, qty, bar.price)


class VolStrategy(BaseStrategy):
    """
    Volatility strategy: go long or short vol proxy.
    """

    def on_bar(self, bar: MarketBar) -> None:
        vol_target = float(self.params.get("vol_target", 0.25))
        vol_leverage = float(self.params.get("vol_leverage", 10.0))
        diff = bar.iv - vol_target
        qty = vol_leverage * diff
        if abs(qty) * bar.price < 1e-6:
            return
        self._trade(bar.ts, bar.symbol, qty, bar.price)


def build_strategy(kind: str, strategy_id: str, params: Dict[str, Any]) -> BaseStrategy:
    kind_lower = kind.lower()
    if kind_lower == "uw":
        return UWStrategy(strategy_id=strategy_id, params=params)
    if kind_lower == "gamma":
        return GammaStrategy(strategy_id=strategy_id, params=params)
    if kind_lower == "vol":
        return VolStrategy(strategy_id=strategy_id, params=params)
    raise ValueError(f"Unknown strategy kind: {kind}")

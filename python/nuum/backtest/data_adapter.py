#!/usr/bin/env python3
import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, Iterable, List, Any, Generator


@dataclass
class MarketBar:
    ts: datetime
    symbol: str
    price: float
    volume: float
    iv: float  # implied volatility proxy


class Lake1DataAdapter:
    """
    Simplified adapter that replays lake1 state.

    In a real deployment this would query lake1; here we support:
    - JSON lines file with synthetic bars
    - Or generate dummy bars if no file is provided
    """

    def __init__(self, universe_symbols: List[str], start_ts: datetime, end_ts: datetime, state_path: str | None):
        self.universe_symbols = universe_symbols
        self.start_ts = start_ts
        self.end_ts = end_ts
        self.state_path = state_path

    def _iter_from_file(self, path: Path) -> Generator[MarketBar, None, None]:
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                rec = json.loads(line)
                ts = datetime.fromisoformat(rec["ts"])
                if ts < self.start_ts or ts > self.end_ts:
                    continue
                yield MarketBar(
                    ts=ts,
                    symbol=rec["symbol"],
                    price=float(rec["price"]),
                    volume=float(rec.get("volume", 0.0)),
                    iv=float(rec.get("iv", 0.0)),
                )

    def _iter_synthetic(self) -> Generator[MarketBar, None, None]:
        step = timedelta(minutes=5)
        ts = self.start_ts
        while ts <= self.end_ts:
            for i, sym in enumerate(self.universe_symbols):
                base = 100.0 + i
                price = base * (1.0 + 0.01 * ((ts - self.start_ts).total_seconds() / 3600.0))
                iv = 0.2 + 0.01 * (i % 5)
                yield MarketBar(ts=ts, symbol=sym, price=price, volume=1000.0, iv=iv)
            ts += step

    def iter_bars(self) -> Iterable[MarketBar]:
        if self.state_path:
            path = Path(self.state_path)
            if path.exists():
                return self._iter_from_file(path)
        return self._iter_synthetic()

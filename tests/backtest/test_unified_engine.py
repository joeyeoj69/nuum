#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


def project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def run_cli(args):
    root = project_root()
    env = os.environ.copy()
    env["PYTHONPATH"] = str(root / "python") + os.pathsep + env.get("PYTHONPATH", "")
    cmd = [sys.executable, "-m", "nuum.backtest.cli_runner"] + args
    return subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True, check=True)


def test_sample_scenario_runs(tmp_path):
    root = project_root()
    scenario = root / "config" / "backtest" / "sample_scenario_vol_world.json"
    artifacts_dir = tmp_path / "artifacts"
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    result = run_cli(["--scenario", str(scenario), "--artifacts-dir", str(artifacts_dir), "--print-summary"])
    assert "final_equity" in result.stdout

    scenario_id = "sample_vol_world_studio1"
    out_dir = artifacts_dir / scenario_id
    assert (out_dir / "equity_curve.json").exists()
    assert (out_dir / "trades.json").exists()
    assert (out_dir / "summary.json").exists()

    with (out_dir / "summary.json").open("r", encoding="utf-8") as f:
        summary = json.load(f)
    assert summary["scenario_id"] == scenario_id
    assert summary["num_points"] > 0

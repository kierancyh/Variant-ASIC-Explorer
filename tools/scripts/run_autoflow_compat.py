#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Sequence

ROOT = Path(__file__).resolve().parents[2]
AUTOFLOW = ROOT / "tools" / "scripts" / "autoflow.py"


def q(parts: Sequence[str]) -> str:
    return " ".join(shlex.quote(p) for p in parts)


def run(cmd: List[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=str(ROOT), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def build_profiles(args: argparse.Namespace) -> List[List[str]]:
    base_env = {
        "AUTOFLOW_VARIANT": args.variant,
        "AUTOFLOW_CLOCK_NS": str(args.clock_ns),
        "AUTOFLOW_STAGE_LABEL": args.stage_label,
        "AUTOFLOW_ARTIFACT_NAME": args.artifact_name,
        "AUTOFLOW_PDK_ROOT": args.pdk_root,
    }
    os.environ.update(base_env)

    optional_pairs = [
        ("--synth-strategy", args.synth_strategy),
        ("--run-antenna-repair", args.run_antenna_repair),
        ("--run-heuristic-diode-insertion", args.run_heuristic_diode_insertion),
        ("--run-post-grt-design-repair", args.run_post_grt_design_repair),
        ("--run-post-grt-resizer-timing", args.run_post_grt_resizer_timing),
    ]

    def extras(style: str) -> List[str]:
        out: List[str] = []
        for key, value in optional_pairs:
            if str(value).strip() == "":
                continue
            flag = key if style == "dash" else key.replace("-", "_")
            out.extend([flag, str(value)])
        return out

    profiles: List[List[str]] = []
    dash = [
        sys.executable,
        str(AUTOFLOW),
        "--variant", args.variant,
        "--clock-ns", str(args.clock_ns),
        "--pdk-root", args.pdk_root,
        "--stage-label", args.stage_label,
        "--artifact-name", args.artifact_name,
        *extras("dash"),
    ]
    dash_no_pdk = [p for p in dash if p not in {"--pdk-root", args.pdk_root}]
    snake = [
        sys.executable,
        str(AUTOFLOW),
        "--variant", args.variant,
        "--clock_ns", str(args.clock_ns),
        "--pdk_root", args.pdk_root,
        "--stage_label", args.stage_label,
        "--artifact_name", args.artifact_name,
        *extras("snake"),
    ]
    snake_no_pdk = [p for p in snake if p not in {"--pdk_root", args.pdk_root}]
    minimal = [sys.executable, str(AUTOFLOW), "--variant", args.variant, "--clock-ns", str(args.clock_ns)]

    profiles.extend([dash, dash_no_pdk, snake, snake_no_pdk, minimal])
    return profiles


def main() -> None:
    ap = argparse.ArgumentParser(description="Compatibility wrapper around the existing autoflow.py CLI.")
    ap.add_argument("--variant", required=True)
    ap.add_argument("--clock-ns", required=True, dest="clock_ns")
    ap.add_argument("--pdk-root", default=os.environ.get("PDK_ROOT", os.environ.get("VOLARE_DIR", "/home/runner/.volare")))
    ap.add_argument("--stage-label", default="coarse")
    ap.add_argument("--artifact-name", default="")
    ap.add_argument("--synth-strategy", default="")
    ap.add_argument("--run-antenna-repair", default="")
    ap.add_argument("--run-heuristic-diode-insertion", default="")
    ap.add_argument("--run-post-grt-design-repair", default="")
    ap.add_argument("--run-post-grt-resizer-timing", default="")
    args = ap.parse_args()

    if not AUTOFLOW.exists():
        raise SystemExit(f"Missing {AUTOFLOW}")

    attempts = build_profiles(args)
    last = None
    for idx, cmd in enumerate(attempts, start=1):
        result = run(cmd)
        sys.stdout.write(f"\n[run_autoflow_compat] Attempt {idx}: {q(cmd)}\n")
        sys.stdout.write(result.stdout or "")
        if result.returncode == 0:
            return
        text = (result.stdout or "").lower()
        if "unrecognized arguments" not in text and "usage:" not in text and "error:" not in text:
            last = result
            break
        last = result

    raise SystemExit(last.returncode if last is not None else 1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, List


ROOT = Path(__file__).resolve().parents[2]


def write_json(path: Path, data: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description="Run the Yosys structural precheck and emit status metadata.")
    ap.add_argument("--meta-json", required=True)
    ap.add_argument("--out-dir", default="precheck/yosys")
    args = ap.parse_args()

    meta = json.loads(Path(args.meta_json).read_text(encoding="utf-8"))
    cfg = meta.get("precheck", {}).get("yosys", {}) or {}
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    log_path = out_dir / "yosys.log"
    stat_txt = out_dir / "stat.txt"
    stat_json = out_dir / "stat.json"
    status_path = out_dir / "status.json"
    meta_path = out_dir / "precheck_meta.json"
    top = str(meta.get("top_module") or "").strip()
    netlist_path = out_dir / f"{top}_synth.v"
    script_path = out_dir / "run.ys"

    enabled = bool(cfg.get("enabled", True))
    precheck_meta = {
        "variant_path": meta.get("variant_path", ""),
        "safe_variant": meta.get("safe_variant", ""),
        "top_module": top,
        "rtl_sources": list(meta.get("rtl_sources", []) or []),
        "tool": "yosys",
        "mode": str(cfg.get("mode") or "structural"),
        "enabled": enabled,
    }

    if not enabled:
        log_path.write_text("Yosys precheck disabled by variant.yaml\n", encoding="utf-8")
        stat_txt.write_text("Yosys precheck disabled by variant.yaml\n", encoding="utf-8")
        stat_json.write_text("{}\n", encoding="utf-8")
        write_json(meta_path, precheck_meta)
        write_json(status_path, {
            "tool": "yosys",
            "enabled": False,
            "status": "SKIP",
            "passed": True,
            "warning_count": 0,
            "reason": "disabled",
        })
        return

    def ys_quote(path: str) -> str:
        return '"' + path.replace('\\', '\\\\').replace('"', '\\"') + '"'

    read_files = " ".join(ys_quote(str(ROOT / rel)) for rel in meta.get("rtl_sources", []) or [])
    script = f"""
read_verilog -sv {read_files}
hierarchy -check -top {top}
check
proc
opt
fsm
opt
memory
techmap
opt
check
tee -o {ys_quote(str(stat_txt.resolve()))} stat
tee -o {ys_quote(str(stat_json.resolve()))} stat -json
write_verilog -noattr -noexpr {ys_quote(str(netlist_path.resolve()))}
""".strip() + "\n"
    script_path.write_text(script, encoding="utf-8")

    result = subprocess.run(
        ["yosys", "-s", str(script_path)],
        cwd=str(ROOT),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    log_path.write_text(result.stdout or "", encoding="utf-8")

    warnings = len(re.findall(r"(?im)^warning:", result.stdout or ""))
    passed = result.returncode == 0 and netlist_path.exists() and stat_txt.exists()
    status = "PASS" if passed and warnings == 0 else "WARN" if passed else "FAIL"
    reason = "ok" if passed else "yosys_failed"
    if passed and warnings:
        reason = "warnings_present"

    write_json(meta_path, precheck_meta)
    write_json(status_path, {
        "tool": "yosys",
        "enabled": True,
        "status": status,
        "passed": passed,
        "warning_count": warnings,
        "rc": result.returncode,
        "variant_path": meta.get("variant_path", ""),
        "safe_variant": meta.get("safe_variant", ""),
        "top_module": top,
        "netlist_present": netlist_path.exists(),
        "stat_txt_present": stat_txt.exists(),
        "stat_json_present": stat_json.exists(),
        "reason": reason,
    })


if __name__ == "__main__":
    main()

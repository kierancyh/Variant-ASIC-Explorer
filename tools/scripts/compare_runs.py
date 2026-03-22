#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import html
import json
import os
import re
import shutil
import urllib.parse
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

TT_GDS_VIEWER_URL = "https://gds-viewer.tinytapeout.com/"
SURFER_WEB_APP_URL = "https://app.surfer-project.org/"


def to_float(v: Any) -> Optional[float]:
    try:
        if v in (None, "", "None"):
            return None
        return float(v)
    except Exception:
        return None


def load_json(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def read_csv_row(path: Path) -> Optional[Dict[str, str]]:
    if not path.exists():
        return None
    with path.open("r", newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return rows[0] if rows else None


def flatten_scalar_metrics(value: Any, prefix: str = "", out: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    if out is None:
        out = {}
    if isinstance(value, dict):
        for key, child in value.items():
            next_prefix = f"{prefix}__{key}" if prefix else str(key)
            flatten_scalar_metrics(child, next_prefix, out)
        return out
    if isinstance(value, list):
        for idx, child in enumerate(value):
            if isinstance(child, (dict, list)):
                continue
            if child in (None, ""):
                continue
            next_prefix = f"{prefix}__{idx}" if prefix else str(idx)
            out[next_prefix] = child
        return out
    if prefix and value not in (None, ""):
        out[prefix] = value
    return out


def signoff_clean(row: Dict[str, str]) -> bool:
    for key in ("drc_errors", "lvs_errors", "antenna_violations"):
        v = to_float(row.get(key))
        if v is not None and v != 0.0:
            return False
    return True


def timing_ok(row: Dict[str, str]) -> bool:
    swns = to_float(row.get("setup_wns_ns"))
    stns = to_float(row.get("setup_tns_ns"))
    return swns is not None and stns is not None and swns >= 0.0 and stns >= 0.0


def classify_status(row: Dict[str, str]) -> str:
    raw_status = str(row.get("status", "")).strip().upper()
    if raw_status in {"FLOW_FAIL", "INCOMPLETE"}:
        return "FLOW_FAIL"
    if not (
        to_float(row.get("setup_wns_ns")) is not None
        and to_float(row.get("setup_tns_ns")) is not None
    ):
        return "FLOW_FAIL"
    clean = signoff_clean(row)
    ok = timing_ok(row)
    if clean and ok:
        return "PASS"
    if clean and not ok:
        return "TIMING_FAIL"
    if (not clean) and ok:
        return "SIGNOFF_FAIL"
    return "SIGNOFF_AND_TIMING_FAIL"


def explain_row(row: Dict[str, str]) -> str:
    if classify_status(row) == "FLOW_FAIL":
        return "Flow failed before valid timing metrics were produced."
    reasons: List[str] = []
    for k, label in (("drc_errors", "DRC"), ("lvs_errors", "LVS"), ("antenna_violations", "Antenna")):
        v = to_float(row.get(k))
        if v not in (None, 0.0):
            reasons.append(f"{label}={int(v) if float(v).is_integer() else v}")
    swns = to_float(row.get("setup_wns_ns"))
    stns = to_float(row.get("setup_tns_ns"))
    if swns is None or swns < 0.0:
        reasons.append(f"setup WNS={row.get('setup_wns_ns', '')}")
    if stns is None or stns < 0.0:
        reasons.append(f"setup TNS={row.get('setup_tns_ns', '')}")
    return "; ".join(reasons) if reasons else "Clean signoff and non-negative setup timing."


def best_sort_key(row: Dict[str, str]) -> Tuple[Any, ...]:
    clean = signoff_clean(row)
    ok = timing_ok(row)
    clk = to_float(row.get("clock_ns"))
    swns = to_float(row.get("setup_wns_ns"))
    stns = to_float(row.get("setup_tns_ns"))
    penalty = sum((to_float(row.get(k)) or 0.0) for k in ("antenna_violations", "drc_errors", "lvs_errors"))
    return (
        0 if clean and ok else 1,
        0 if clean else 1,
        penalty,
        clk if clk is not None else 1e12,
        -(swns if swns is not None else -1e12),
        -(stns if stns is not None else -1e12),
    )


def parse_attempt_started(path: Path) -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


def infer_stage_label(row: Dict[str, str]) -> str:
    haystack = " ".join(
        [
            str(row.get("_artifact", "")),
            str(row.get("_run_dir", "")),
            str(row.get("_variant", "")),
        ]
    ).lower()
    if "coarse" in haystack:
        return "coarse"
    if "mid" in haystack or "5ns" in haystack or "5 ns" in haystack or "step5" in haystack:
        return "5 ns"
    if "0.125" in haystack or "125ps" in haystack or "refine3" in haystack or "refine_3" in haystack:
        return "0.125 ns"
    if "0.5" in haystack or "500ps" in haystack or "refine2" in haystack or "refine_2" in haystack:
        return "0.5 ns"
    if "1.0" in haystack or "1ns" in haystack or "1 ns" in haystack or "refine1" in haystack or "refine_1" in haystack:
        return "1.0 ns"
    return ""


def first_gds_path(base_dir: Path) -> Optional[Path]:
    gds_dir = base_dir / "final" / "gds"
    if not gds_dir.exists():
        return None
    files = sorted(gds_dir.glob("*.gds"))
    return files[0] if files else None


def first_render_path(base_dir: Path) -> Optional[Path]:
    renders_dir = base_dir / "renders"
    if not renders_dir.exists():
        return None
    for pattern in ("*.png", "*.jpg", "*.jpeg", "*.webp"):
        files = sorted(renders_dir.glob(pattern))
        if files:
            return files[0]
    return None


def raw_row_key(raw_key: str) -> str:
    return f"_raw__{raw_key}"

def raw_metric_value(row: Dict[str, Any], raw_key: str) -> Any:
    return row.get(raw_row_key(raw_key), "")


def pretty_raw_metric_label(raw_key: str) -> str:
    pieces = [piece.replace("_", " ").strip() for piece in raw_key.split("__") if piece.strip()]
    return " / ".join(piece.title() for piece in pieces)


def raw_metric_sort_priority(raw_key: str) -> Tuple[int, str]:
    priorities = [
        ("clock__", 0),
        ("timing__", 0),
        ("power__", 1),
        ("design__", 2),
        ("floorplan__", 2),
        ("place__", 3),
        ("route__", 4),
        ("cts__", 5),
        ("drc__", 6),
        ("klayout__", 6),
        ("magic__", 6),
        ("lvs__", 6),
        ("antenna__", 6),
        ("ir__", 6),
    ]
    for prefix, rank in priorities:
        if raw_key.startswith(prefix):
            return (rank, raw_key)
    return (99, raw_key)


def iter_raw_metrics(row: Dict[str, Any]) -> List[Tuple[str, Any]]:
    items: List[Tuple[str, Any]] = []
    for key, value in row.items():
        if not key.startswith("_raw__"):
            continue
        if value in ("", None, "None"):
            continue
        raw_key = key[len("_raw__") :]
        items.append((raw_key, value))
    items.sort(key=lambda item: raw_metric_sort_priority(item[0]))
    return items


def pick_raw_metric_items(
    row: Dict[str, Any],
    prefixes: Tuple[str, ...],
    consumed: Set[str],
    *,
    limit: int = 8,
    catch_all: bool = False,
) -> List[Tuple[str, Any]]:
    selected: List[Tuple[str, Any]] = []
    for raw_key, value in iter_raw_metrics(row):
        if raw_key in consumed:
            continue
        matches = True if catch_all else any(raw_key.startswith(prefix) for prefix in prefixes)
        if not matches:
            continue
        consumed.add(raw_key)
        selected.append((pretty_raw_metric_label(raw_key), value))
        if len(selected) >= limit:
            break
    return selected



def collect_rows(artifacts_root: Path) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    seen: Set[Path] = set()
    for pattern in ("**/ci_out/*/clk_*ns_*/metrics.csv", "**/*/clk_*ns_*/metrics.csv"):
        for csv_path in sorted(artifacts_root.glob(pattern)):
            if csv_path in seen:
                continue
            seen.add(csv_path)
            row = read_csv_row(csv_path)
            if not row:
                continue
            base_dir = csv_path.parent
            meta_path = base_dir / "run_meta.json"
            meta = load_json(meta_path)
            started = parse_attempt_started(base_dir / "attempt_started.txt")
            raw_metrics = load_json(base_dir / "metrics_raw.json")
            raw_flat = flatten_scalar_metrics(raw_metrics)
            failure_summary = load_json(base_dir / "failure_summary.json")

            row["_variant"] = str(meta.get("variant", base_dir.parent.name))
            row["_artifact"] = str(meta.get("artifact_name", ""))
            row["_run_dir"] = base_dir.name
            row["_base_dir"] = str(base_dir)
            row["_clock_requested"] = str(meta.get("clock_ns_requested", row.get("clock_ns", "")))
            row["_github_run_id"] = str(meta.get("github_run_id", ""))
            row["_synth_strategy_override"] = str(meta.get("synth_strategy_override", ""))
            row["_attempt_number"] = started.get("attempt", "")
            row["_attempt_started_at"] = started.get("started_at", "")
            row["_metrics_raw_present"] = "yes" if raw_metrics else "no"
            row["_raw_metric_count"] = str(len(raw_flat))
            row["status"] = classify_status(row)
            row["selection_reason"] = explain_row(row)
            meta_stage = str(meta.get("stage_label", "")).strip()
            started_stage = str(started.get("stage_label", "")).strip()
            row["_stage_label"] = meta_stage or started_stage or infer_stage_label(row)
            row["_failure_summary_present"] = "yes" if failure_summary else "no"
            row["_failure_reason"] = str(failure_summary.get("reason", ""))
            row["_failure_phase"] = str(failure_summary.get("likely_failure_phase", ""))
            row["_failure_openlane_rc"] = str(failure_summary.get("openlane_rc", ""))
            row["_failure_config_rc"] = str(failure_summary.get("config_generation_rc", ""))
            row["_failure_summary"] = failure_summary
            row["_openlane_run_present"] = "yes" if (base_dir / "openlane_run").exists() else "no"
            gds = first_gds_path(base_dir)
            rnd = first_render_path(base_dir)
            row["_gds_path"] = str(gds) if gds else ""
            row["_render_path"] = str(rnd) if rnd else ""
            for raw_key, raw_value in raw_flat.items():
                row[raw_row_key(raw_key)] = raw_value
            rows.append(row)
    return rows


def find_first(root: Path, patterns: Sequence[str]) -> Optional[Path]:
    for pattern in patterns:
        matches = sorted(root.glob(pattern))
        if matches:
            return matches[0]
    return None

def collect_precheck(artifacts_root: Path) -> Dict[str, Any]:
    rtl_status: Dict[str, Any] = {}
    yosys_status: Dict[str, Any] = {}
    rtl_root: Optional[Path] = None
    yosys_root: Optional[Path] = None

    for status_path in sorted(artifacts_root.glob("**/status.json")):
        maybe = load_json(status_path)
        tool = str(maybe.get("tool") or "").strip().lower()

        if tool == "icarus" and not rtl_status:
            rtl_status = maybe
            rtl_root = status_path.parent
        elif tool == "yosys" and not yosys_status:
            yosys_status = maybe
            yosys_root = status_path.parent

    data: Dict[str, Any] = {
        "icarus": rtl_status or {"tool": "icarus", "status": "MISSING", "passed": False, "enabled": False},
        "yosys": yosys_status or {"tool": "yosys", "status": "MISSING", "passed": False, "enabled": False},
        "top_module": rtl_status.get("top_module") or yosys_status.get("top_module") or "",
        "testbench_top": rtl_status.get("testbench_top") or "",
        "vcd_present": bool(rtl_status.get("vcd_present", False)),
        "vcd_name": rtl_status.get("vcd_name") or "rtl_precheck.vcd",
        "rtl_root": str(rtl_root) if rtl_root else "",
        "yosys_root": str(yosys_root) if yosys_root else "",
    }

    if rtl_root:
        data["compile_log"] = str(rtl_root / "compile.log")
        data["run_log"] = str(rtl_root / "run.log")
        data["vcd_path"] = str(rtl_root / data["vcd_name"])
        data["rtl_meta"] = str(rtl_root / "precheck_meta.json")
        if not Path(data["vcd_path"]).exists():
            data["vcd_present"] = False
    else:
        data["compile_log"] = ""
        data["run_log"] = ""
        data["vcd_path"] = ""
        data["rtl_meta"] = ""

    if yosys_root:
        synth_name = f"{data['top_module']}_synth.v" if data["top_module"] else ""
        data["yosys_log"] = str(yosys_root / "yosys.log")
        data["yosys_stat_txt"] = str(yosys_root / "stat.txt")
        data["yosys_stat_json"] = str(yosys_root / "stat.json")
        data["yosys_netlist"] = str(yosys_root / synth_name) if synth_name else ""
        data["yosys_meta"] = str(yosys_root / "precheck_meta.json")
    else:
        data["yosys_log"] = ""
        data["yosys_stat_txt"] = ""
        data["yosys_stat_json"] = ""
        data["yosys_netlist"] = ""
        data["yosys_meta"] = ""

    data["gate_ok"] = (
        bool(data["icarus"].get("passed") or data["icarus"].get("status") == "SKIP")
        and bool(data["yosys"].get("passed") or data["yosys"].get("status") == "SKIP")
    )
    return data

def sanitize_site_component(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", str(value or "").strip())
    safe = re.sub(r"-+", "-", safe).strip("-.")
    return safe or "snapshot"


def normalize_site_subdir(site_subdir: str) -> str:
    parts = [sanitize_site_component(part) for part in str(site_subdir or "").split("/") if str(part).strip()]
    return "/".join(parts)


def copy_tree_if_exists(src: Path, dst: Path) -> None:
    if not src.exists():
        return
    if src.is_dir():
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def copy_file_if_exists(src: Path, dst: Path) -> None:
    if not src.exists() or not src.is_file():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def publish_run_site_artifact(base_dir: Path, row: Dict[str, str], site_artifact_dir: Path) -> Dict[str, str]:
    published: Dict[str, str] = {}
    site_artifact_dir.mkdir(parents=True, exist_ok=True)

    small_files = (
        "metrics.csv",
        "metrics.md",
        "metrics_raw.json",
        "run_meta.json",
        "attempt_started.txt",
        "attempt_manifest.json",
        "failure_summary.md",
        "failure_summary.json",
        "README.txt",
        "viewer.html",
        "index.html",
    )

    for name in small_files:
        src = base_dir / name
        if src.exists():
            copy_file_if_exists(src, site_artifact_dir / name)
            published[name] = str(site_artifact_dir / name)

    render_path = Path(row["_render_path"]) if row.get("_render_path") else None
    if render_path and render_path.exists():
        dst = site_artifact_dir / "renders" / render_path.name
        copy_file_if_exists(render_path, dst)
        published["render_path"] = str(dst)

    gds_path = Path(row["_gds_path"]) if row.get("_gds_path") else None
    published["gds_exists"] = "yes" if gds_path and gds_path.exists() else "no"
    published["gds_published"] = "no"

    if gds_path and gds_path.exists():
        dst = site_artifact_dir / "final" / "gds" / gds_path.name
        copy_file_if_exists(gds_path, dst)
        if dst.exists():
            published["gds_path"] = str(dst)
            published["gds_published"] = "yes"

    return published


def publish_precheck_site_artifacts(precheck: Dict[str, Any], snapshot_root: Path) -> Dict[str, str]:
    published: Dict[str, str] = {}

    rtl_root = Path(precheck["rtl_root"]) if precheck.get("rtl_root") else None
    if rtl_root and rtl_root.exists():
        rtl_site = snapshot_root / "precheck" / "rtl"
        for name in (
            "status.json",
            "precheck_meta.json",
            "compile.log",
            "run.log",
        ):
            copy_file_if_exists(rtl_root / name, rtl_site / name)
        vcd_name = Path(str(precheck.get("vcd_name") or "rtl_precheck.vcd")).name
        if precheck.get("vcd_present"):
            copy_file_if_exists(rtl_root / vcd_name, rtl_site / vcd_name)
            if (rtl_site / vcd_name).exists():
                published["vcd_path"] = str(rtl_site / vcd_name)
        if (rtl_site / "compile.log").exists():
            published["compile_log"] = str(rtl_site / "compile.log")
        if (rtl_site / "run.log").exists():
            published["run_log"] = str(rtl_site / "run.log")

    yosys_root = Path(precheck["yosys_root"]) if precheck.get("yosys_root") else None
    if yosys_root and yosys_root.exists():
        yosys_site = snapshot_root / "precheck" / "yosys"
        for name in (
            "status.json",
            "precheck_meta.json",
            "yosys.log",
            "stat.txt",
            "stat.json",
        ):
            copy_file_if_exists(yosys_root / name, yosys_site / name)
        if precheck.get("top_module"):
            synth_name = f"{precheck['top_module']}_synth.v"
            copy_file_if_exists(yosys_root / synth_name, yosys_site / synth_name)
            if (yosys_site / synth_name).exists():
                published["yosys_netlist"] = str(yosys_site / synth_name)
        if (yosys_site / "yosys.log").exists():
            published["yosys_log"] = str(yosys_site / "yosys.log")
        if (yosys_site / "stat.txt").exists():
            published["yosys_stat_txt"] = str(yosys_site / "stat.txt")
        if (yosys_site / "stat.json").exists():
            published["yosys_stat_json"] = str(yosys_site / "stat.json")

    return published


def write_summary_csv(path: Path, rows: List[Dict[str, str]]) -> None:
    base_keys = [
        "_variant",
        "_run_dir",
        "_artifact",
        "_clock_requested",
        "_stage_label",
        "clock_ns",
        "setup_wns_ns",
        "setup_tns_ns",
        "core_area_um2",
        "power_total_W",
        "drc_errors",
        "lvs_errors",
        "antenna_violations",
        "status",
        "selection_reason",
    ]
    raw_keys = sorted({key for row in rows for key in row.keys() if key.startswith("_raw__")})
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=base_keys + raw_keys)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in base_keys + raw_keys})


def write_summary_md(path: Path, rows: List[Dict[str, str]], precheck: Dict[str, Any]) -> None:
    lines = [
        "## Precheck summary",
        "",
        f"- Icarus: {precheck.get('icarus', {}).get('status', 'MISSING')}",
        f"- Yosys: {precheck.get('yosys', {}).get('status', 'MISSING')}",
        f"- Top module: {precheck.get('top_module', '')}",
        f"- TB top: {precheck.get('testbench_top', '')}",
        f"- VCD present: {'yes' if precheck.get('vcd_present') else 'no'}",
        "",
        "## Selection Criteria",
        "",
        "1. Clean signoff plus non-negative setup timing wins.",
        "2. If no full PASS exists, clean signoff wins over signoff violations.",
        "3. Among comparable runs, lower requested clock period is preferred.",
        "4. Setup WNS/TNS are used as tie-breakers.",
        "",
    ]
    if not rows:
        lines += ["No ASIC run metrics were collected for this snapshot.", ""]
    else:
        best = sorted(rows, key=best_sort_key)[0]
        lines += [
            f"Selected best run: {best.get('_variant', '')} / {best.get('_run_dir', '')}",
            "",
            "| Variant | Stage | Clock (ns) | Status | Remarks |",
            "|---|---:|---:|---|---|",
        ]
        for row in sorted(rows, key=best_sort_key):
            lines.append(
                f"| {row.get('_variant','')} | {row.get('_stage_label','')} | {row.get('clock_ns','')} | {row.get('status','')} | {row.get('selection_reason','').replace('|','/')} |"
            )
        lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def write_best_json(path: Path, rows: List[Dict[str, str]]) -> Dict[str, Any]:
    best = sorted(rows, key=best_sort_key)[0] if rows else {}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(best, indent=2), encoding="utf-8")
    return best


def package_best_bundle(best_bundle_dir: Path, best: Dict[str, Any], precheck: Dict[str, Any]) -> None:
    best_bundle_dir.mkdir(parents=True, exist_ok=True)
    if best:
        base_dir = Path(best["_base_dir"])
        for name in (
            "metrics.csv",
            "metrics.md",
            "metrics_raw.json",
            "run_meta.json",
            "attempt_started.txt",
            "attempt_manifest.json",
            "viewer.html",
            "index.html",
            "README.txt",
            "failure_summary.md",
            "failure_summary.json",
        ):
            src = base_dir / name
            if src.exists():
                shutil.copy2(src, best_bundle_dir / name)
        copy_tree_if_exists(base_dir / "renders", best_bundle_dir / "renders")
        copy_tree_if_exists(base_dir / "final" / "gds", best_bundle_dir / "final" / "gds")
        copy_tree_if_exists(base_dir / "openlane_run", best_bundle_dir / "openlane_run")

    rtl_root = Path(precheck["rtl_root"]) if precheck.get("rtl_root") else None
    yosys_root = Path(precheck["yosys_root"]) if precheck.get("yosys_root") else None
    if rtl_root and rtl_root.exists():
        copy_tree_if_exists(rtl_root, best_bundle_dir / "precheck" / "rtl")
    if yosys_root and yosys_root.exists():
        copy_tree_if_exists(yosys_root, best_bundle_dir / "precheck" / "yosys")


def rel_href(path: Path, root: Path) -> str:
    try:
        rel = path.relative_to(root)
    except ValueError:
        rel = Path(os.path.relpath(path, root))
    return urllib.parse.quote(str(rel).replace(os.sep, "/"))


def badge_html(status: str) -> str:
    s = str(status or "").upper()
    cls = {
        "PASS": "pass",
        "TIMING_FAIL": "timing",
        "SIGNOFF_FAIL": "signoff",
        "SIGNOFF_AND_TIMING_FAIL": "mixed",
        "FLOW_FAIL": "flow",
        "WARN": "mixed",
        "FAIL": "flow",
        "SKIP": "flow",
        "MISSING": "flow",
        "UNKNOWN": "flow",
    }.get(s, "flow")
    return f'<span class="badge {cls}">{html.escape(s or "UNKNOWN")}</span>'

def value_or_dash(v: Any) -> str:
    if isinstance(v, bool):
        s = "yes" if v else "no"
    else:
        s = "" if v is None else str(v)
    return html.escape(s) if s not in {"", "None"} else "—"


def kv_rows(items: List[Tuple[str, Any]]) -> str:
    return "".join(
        f"<tr><td>{html.escape(k)}</td><td>{value_or_dash(v)}</td></tr>"
        for k, v in items
    )


def metric_group_html(title: str, items: List[Tuple[str, Any]]) -> str:
    return (
        f'<section class="metric-group table-card">'
        f'<div class="table-head"><h3>{html.escape(title)}</h3></div>'
        f'<div class="kv-wrap"><table class="kv-table">'
        f'<colgroup><col class="kv-key"><col class="kv-value"></colgroup>'
        f"<tr><th>Field</th><th>Value</th></tr>{kv_rows(items)}</table></div>"
        f"</section>"
    )



def write_redirect_page(path: Path, target: str, title: str, description: str) -> None:
    safe_title = html.escape(title)
    safe_description = html.escape(description)
    safe_target = html.escape(target)
    content = f"""<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta http-equiv=\"refresh\" content=\"0; url={safe_target}\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>{safe_title}</title>
  <style>
    body{{font-family:Inter,Segoe UI,Arial,sans-serif;background:#f4ecdf;margin:0;min-height:100vh;display:grid;place-items:center;color:#2a2116}}
    .card{{max-width:720px;background:rgba(255,248,238,.94);border:1px solid rgba(116,92,62,.22);border-radius:18px;padding:24px;box-shadow:0 18px 45px rgba(110,84,53,.12)}}
    a{{color:#8b5e3c;text-decoration:none;font-weight:700}}
  </style>
</head>
<body>
  <div class=\"card\">
    <h1>{safe_title}</h1>
    <p>{safe_description}</p>
    <p><a href=\"{safe_target}\">Open the explorer snapshot</a></p>
  </div>
</body>
</html>"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def pages_base_url(repo_slug: str) -> str:
    slug = str(repo_slug or "").strip()
    if "/" not in slug:
        return ""
    owner, repo = slug.split("/", 1)
    return f"https://{owner}.github.io/{repo}"


def build_surfer_url(vcd_url: str) -> str:
    return f"{SURFER_WEB_APP_URL}?load_url={urllib.parse.quote(vcd_url, safe='')}"


def write_run_page(run_dir: Path, row: Dict[str, str], snapshot_prefix: str) -> None:
    metrics_path = Path(row.get("_site_metrics_path") or (Path(row["_base_dir"]) / "metrics.csv"))
    metrics_href = rel_href(metrics_path, run_dir)
    failure_summary_href = rel_href(Path(row["_site_failure_summary_path"]), run_dir) if row.get("_site_failure_summary_path") else ""
    raw_metrics_href = rel_href(Path(row["_site_metrics_raw_path"]), run_dir) if row.get("_site_metrics_raw_path") else ""
    meta_href = rel_href(Path(row["_site_run_meta_path"]), run_dir) if row.get("_site_run_meta_path") else ""
    snapshot_root = run_dir.parents[1]
    back_href = rel_href(snapshot_root / "index.html", run_dir)
    css_href = rel_href(snapshot_root / "assets" / "explorer.css", run_dir)

    actions = [
        f'<a class="btn secondary" href="{back_href}">Back to Explorer</a>',
        f'<a class="btn" href="{metrics_href}">Open metrics.csv</a>',
    ]
    if raw_metrics_href:
        actions.append(f'<a class="btn secondary" href="{raw_metrics_href}">Open metrics_raw.json</a>')
    if meta_href:
        actions.append(f'<a class="btn secondary" href="{meta_href}">Open run_meta.json</a>')
    if failure_summary_href:
        actions.append(f'<a class="btn secondary" href="{failure_summary_href}">Open Failure Summary</a>')
    if row.get("_gds_exists") == "yes":
        actions.append(f'<a class="btn secondary" href="{TT_GDS_VIEWER_URL}" target="_blank" rel="noopener">Open GDS Viewer</a>')

    consumed_raw: Set[str] = set()

    timing_items: List[Tuple[str, Any]] = [
        ("Clock requested", f"{row.get('_clock_requested', '')} ns"),
        ("Clock reported", f"{row.get('clock_ns_reported', row.get('clock_ns', ''))} ns"),
        ("Setup WNS", f"{row.get('setup_wns_ns', '')} ns"),
        ("Setup TNS", f"{row.get('setup_tns_ns', '')} ns"),
        ("Hold WNS", f"{row.get('hold_wns_ns', '')} ns"),
        ("Hold TNS", f"{row.get('hold_tns_ns', '')} ns"),
    ]
    timing_items.extend(pick_raw_metric_items(row, ("clock__", "timing__"), consumed_raw, limit=10))

    physical_items: List[Tuple[str, Any]] = [
        ("Core area", row.get("core_area_um2", "")),
        ("Die area", row.get("die_area_um2", "")),
        ("Instances", row.get("instance_count", "")),
        ("Utilization", row.get("utilization_pct", "")),
        ("Wire length", row.get("wire_length_um", "")),
        ("Vias", row.get("vias_count", "")),
    ]
    physical_items.extend(
        pick_raw_metric_items(row, ("design__", "floorplan__", "place__", "route__", "cts__"), consumed_raw, limit=12)
    )

    power_items: List[Tuple[str, Any]] = [
        ("Total", row.get("power_total_W", "")),
        ("Internal", row.get("power_internal_W", "")),
        ("Switching", row.get("power_switching_W", "")),
        ("Leakage", row.get("power_leakage_W", "")),
        ("Source", row.get("power_source", "")),
        ("FAIR STA rpt", row.get("power_fair_sta_rpt", "")),
    ]
    power_items.extend(pick_raw_metric_items(row, ("power__",), consumed_raw, limit=10))

    signoff_items: List[Tuple[str, Any]] = [
        ("DRC", row.get("drc_errors", "")),
        ("KLayout DRC", row.get("drc_errors_klayout", "")),
        ("Magic DRC", row.get("drc_errors_magic", "")),
        ("LVS", row.get("lvs_errors", "")),
        ("Antenna", row.get("antenna_violations", "")),
        ("Worst IR drop", row.get("ir_drop_worst_V", "")),
    ]
    signoff_items.extend(
        pick_raw_metric_items(
            row,
            ("drc__", "klayout__", "magic__", "lvs__", "antenna__", "ir__"),
            consumed_raw,
            limit=12,
        )
    )

    additional_raw_items = pick_raw_metric_items(row, tuple(), consumed_raw, limit=24, catch_all=True)

    failure_section = ""
    failure_summary = row.get("_failure_summary", {})
    if row.get("status") == "FLOW_FAIL" and isinstance(failure_summary, dict) and failure_summary:
        checks = failure_summary.get("checks", {}) or {}
        failure_rows: List[Tuple[str, Any]] = [
            ("Primary reason", failure_summary.get("reason", row.get("_failure_reason", ""))),
            ("Likely failing phase", failure_summary.get("likely_failure_phase", row.get("_failure_phase", ""))),
            ("OpenLane return code", failure_summary.get("openlane_rc", row.get("_failure_openlane_rc", ""))),
            ("Config generation return code", failure_summary.get("config_generation_rc", row.get("_failure_config_rc", ""))),
            ("Config generated", checks.get("config_generated", "")),
            ("OpenLane invoked", checks.get("openlane_invoked", "")),
            ("Run directory found", checks.get("run_dir_found", "")),
            ("metrics.csv present", checks.get("metrics_csv_present", "")),
            ("metrics_raw.json present", checks.get("metrics_raw_present", "")),
            ("Valid timing present", checks.get("timing_present", "")),
            ("GDS present", checks.get("gds_present", "")),
            ("OpenLane run copied", checks.get("openlane_run_present", "")),
            ("Viewer HTML present", checks.get("viewer_present", "")),
        ]
        failure_section = (
            '<section class="card span-12">'
            '<div class="metrics-strip">'
            f'{metric_group_html("Failure Diagnostic", failure_rows)}'
            "</div>"
            "</section>"
        )

    meta_rows = [
        ("Variant", row.get("_variant")),
        ("Run folder", row.get("_run_dir")),
        ("Artifact label", row.get("_artifact")),
        ("Stage label", row.get("_stage_label")),
        ("Attempt number", row.get("_attempt_number")),
        ("GitHub run ID", row.get("_github_run_id")),
        ("Synthesis override", row.get("_synth_strategy_override")),
        ("OpenLane run copied", row.get("_openlane_run_present")),
        ("metrics_raw.json present", row.get("_metrics_raw_present")),
        ("Raw metric count", row.get("_raw_metric_count")),
        ("Failure summary present", row.get("_failure_summary_present")),
        ("Likely failure phase", row.get("_failure_phase")),
        ("Status", row.get("status")),
        ("Remarks", row.get("selection_reason"))
    ]

    raw_group = metric_group_html("Additional Raw Metrics", additional_raw_items) if additional_raw_items else ""

    content = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(row.get('_variant',''))} / {html.escape(row.get('_run_dir',''))}</title>
  <link rel="stylesheet" href="{css_href}">
</head>
<body>
  <div class="wrap">
    <section class="hero">
      <div class="hero-head">
        <div class="hero-copy">
          <p class="eyebrow">Per-run details</p>
          <h1>{html.escape(row.get('_variant',''))} / {html.escape(row.get('_run_dir',''))}</h1>
          <p class="muted">{badge_html(row.get('status',''))} &nbsp; Remarks: {html.escape(row.get('selection_reason',''))}</p>
        </div>
        <div class="actions">{''.join(actions)}</div>
      </div>
    </section>

    <div class="grid">
      {failure_section}

      <section class="card span-12">
        <h2>Metrics by Category</h2>
        <div class="metrics-strip">
          {metric_group_html("Timing", timing_items)}
          {metric_group_html("Physical", physical_items)}
          {metric_group_html("Power (W)", power_items)}
          {metric_group_html("Signoff", signoff_items)}
          {raw_group}
        </div>
      </section>

      <section class="card span-12 table-card">
        <div class="table-head"><h2>Metadata</h2></div>
        <div class="kv-wrap">
          <table class="kv-table">
            <colgroup><col class="kv-key"><col class="kv-value"></colgroup>
            <tr><th>Field</th><th>Value</th></tr>
            {kv_rows(meta_rows)}
          </table>
        </div>
      </section>
    </div>
  </div>
</body>
</html>"""
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "index.html").write_text(content, encoding="utf-8")


def build_site(
    site_root: Path,
    rows: List[Dict[str, str]],
    precheck: Dict[str, Any],
    explorer_settings: Optional[Dict[str, str]] = None,
    *,
    repo_slug: str = "",
    run_id: str = "",
    site_subdir: str = "",
) -> None:
    site_root.mkdir(parents=True, exist_ok=True)
    explorer_settings = explorer_settings or {}
    normalized_site_subdir = normalize_site_subdir(site_subdir)
    snapshot_root = site_root / normalized_site_subdir if normalized_site_subdir else site_root
    snapshot_root.mkdir(parents=True, exist_ok=True)
    if normalized_site_subdir:
        write_redirect_page(site_root / "index.html", f"{normalized_site_subdir}/index.html", "ASIC Flow Run Explorer", "Static explorer snapshot")
    (site_root / ".nojekyll").write_text("\n", encoding="utf-8")

    assets_dir = snapshot_root / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    css = """
    :root{
      color-scheme:light dark;
      --bg:#f4ecdf;
      --bg-grad-1:#f8f1e7;
      --bg-grad-2:#efe4d3;
      --panel:rgba(255,250,243,.82);
      --panel-strong:rgba(255,248,238,.94);
      --panel-soft:rgba(255,255,255,.46);
      --border:rgba(116,92,62,.16);
      --border-strong:rgba(116,92,62,.22);
      --text:#2f2418;
      --muted:#716250;
      --accent:#8b5e3c;
      --accent-2:#b6845e;
      --shadow:0 18px 45px rgba(110,84,53,.12);
      --pass-bg:rgba(73,143,96,.14);
      --pass-fg:#285a38;
      --timing-bg:rgba(190,143,45,.16);
      --timing-fg:#7d5b13;
      --signoff-bg:rgba(180,83,72,.14);
      --signoff-fg:#7b2f28;
      --mixed-bg:rgba(135,96,166,.14);
      --mixed-fg:#5b3f77;
      --flow-bg:rgba(120,115,108,.14);
      --flow-fg:#504a44;
      --radius-xl:28px;
      --radius-lg:20px;
      --radius-md:14px
    }
    *{box-sizing:border-box}
    body{
      margin:0;
      background:
        radial-gradient(circle at top left,var(--bg-grad-1)0%,transparent 36%),
        radial-gradient(circle at top right,var(--bg-grad-2)0%,transparent 28%),
        linear-gradient(180deg,var(--bg-grad-1)0%,var(--bg)100%);
      color:var(--text);
      font:15px/1.6 Inter,Segoe UI,Roboto,Helvetica,Arial,sans-serif
    }
    a{color:var(--accent);text-decoration:none}
    img{max-width:100%;border-radius:14px;border:1px solid var(--border)}
    .wrap{max-width:min(96vw,1800px);margin:0 auto;padding:24px 12px 36px}
    .hero{
      background:var(--panel-strong);
      border:1px solid var(--border-strong);
      border-radius:var(--radius-xl);
      padding:30px;
      box-shadow:var(--shadow);
      margin-bottom:22px
    }
    .hero-head{display:flex;justify-content:space-between;align-items:flex-start;gap:16px}
    .hero-copy{max-width:1100px}
    .hero-copy p{margin:0 0 8px 0}
    .settings-list{
      margin:10px 0 0;
      padding:0;
      list-style:none;
      display:grid;
      gap:6px;
      color:var(--muted);
      font-size:14px
    }
    .settings-list strong{color:var(--text)}
    .grid{display:grid;grid-template-columns:repeat(12,1fr);gap:16px}
    .card{
      background:var(--panel);
      border:1px solid var(--border);
      border-radius:var(--radius-lg);
      padding:22px;
      box-shadow:var(--shadow)
    }
    .span-12{grid-column:span 12}
    .span-7{grid-column:span 7}
    .span-5{grid-column:span 5}
    .kpi-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
    .stat{
      background:var(--panel-soft);
      border:1px solid var(--border);
      border-radius:var(--radius-md);
      padding:16px
    }
    .stat .label{color:var(--muted);font-size:12px;text-transform:uppercase}
    .stat .value{font-size:28px;font-weight:700}
    .card h2{margin:0 0 12px 0}

    .badge{
      display:inline-flex;
      align-items:center;
      justify-content:center;
      min-width:112px;
      padding:6px 10px;
      border-radius:999px;
      font-size:12px;
      font-weight:700
    }
    .badge.pass{background:var(--pass-bg);color:var(--pass-fg)}
    .badge.timing{background:var(--timing-bg);color:var(--timing-fg)}
    .badge.signoff{background:var(--signoff-bg);color:var(--signoff-fg)}
    .badge.mixed{background:var(--mixed-bg);color:var(--mixed-fg)}
    .badge.flow{background:var(--flow-bg);color:var(--flow-fg)}

    /* Homepage-only smaller status badges */
    .wide-table .badge{
      min-width:84px;
      padding:5px 8px;
      font-size:10px
    }

    .btn{
      display:inline-flex;
      align-items:center;
      justify-content:center;
      padding:8px 12px;
      border-radius:10px;
      border:1px solid rgba(139,94,60,.20);
      background:rgba(139,94,60,.08);
      color:var(--text);
      font-weight:600;
      font-size:13px
    }
    .btn.secondary{border-color:var(--border-strong);background:rgba(255,255,255,.08)}
    .btn-sm{
      padding:6px 10px;
      font-size:12px;
      border-radius:9px
    }

    .actions{display:flex;gap:8px;flex-wrap:wrap}
    .inline-actions{
      display:flex;
      flex-direction:column;
      align-items:stretch;
      gap:6px;
    }
    
    .inline-actions .btn{
      width:100%;
      justify-content:center;
    }
    
    .muted{color:var(--muted)}
    .tag{
      display:inline-flex;
      align-items:center;
      padding:4px 10px;
      border-radius:999px;
      font-size:12px;
      font-weight:700;
      background:rgba(139,94,60,.12);
      color:var(--accent)
    }
    
    .table-card{padding:0;overflow:hidden}
    .section-gap-lg{margin-top:26px}

    .table-head{
      display:flex;
      justify-content:space-between;
      align-items:center;
      padding:18px 20px;
      border-bottom:1px solid var(--border)
    }
    .table-wrap{overflow:auto}
    .table-tools{
      display:flex;
      gap:12px;
      flex-wrap:wrap;
      align-items:end;
      padding:16px 20px 0
    }
    .table-tools label{
      display:grid;
      gap:6px;
      color:var(--muted);
      font-size:12px;
      font-weight:700;
      text-transform:uppercase
    }
    .table-tools select,.table-tools input[type="search"]{
      min-width:180px;
      padding:10px 12px;
      border-radius:10px;
      border:1px solid var(--border-strong);
      background:var(--panel-soft);
      color:var(--text);
      font:500 13px/1.2 Inter,Segoe UI,Roboto,Helvetica,Arial,sans-serif
    }
    .table-tools .inline-check{
      display:flex;
      align-items:center;
      gap:8px;
      font-size:13px;
      font-weight:600;
      text-transform:none;
      color:var(--text);
      padding-bottom:2px
    }
    .table-tools .summary{
      margin-left:auto;
      font-size:13px;
      color:var(--muted);
      padding-bottom:4px
    }

    .sort-btn{
      all:unset;
      cursor:pointer;
      font-weight:700;
      color:var(--text);
      display:inline-flex;
      align-items:center;
      gap:6px
    }
    .sort-btn:hover,.sort-btn.active{color:var(--accent)}
    .sort-indicator{font-size:11px;color:var(--muted)}

    .wide-table{
      width:100%;
      border-collapse:collapse;
      min-width:0
    }
    .wide-table th,.wide-table td{
      padding:14px 16px;
      border-bottom:1px solid var(--border);
      vertical-align:top
    }
    .wide-table th{
      background:rgba(255,248,240,.92);
      text-align:left;
      font-size:13px;
      white-space:nowrap
    }
    .wide-table td:last-child{
      white-space:normal;
    }
    .wide-table td:last-child,
    .wide-table th:last-child{
      padding-left:10px;
      padding-right:10px;
    }

    .best-row{background:rgba(139,94,60,.06)}
    .page{max-width:min(96vw,1800px);margin:0 auto;padding:24px 12px 36px}
    .eyebrow{
      margin:0 0 8px 0;
      color:var(--muted);
      font-size:12px;
      font-weight:700;
      letter-spacing:.08em;
      text-transform:uppercase
    }
    .metrics-strip{display:grid;grid-template-columns:1fr;gap:14px}
    .metric-group{
      background:var(--panel);
      border:1px solid var(--border);
      border-radius:var(--radius-lg);
      padding:0;
      overflow:hidden
    }
    .metric-group h3{margin:0;font-size:15px}
    .kv-wrap{overflow:hidden}
    .kv-table{
      width:100%;
      border-collapse:collapse;
      table-layout:fixed;
      min-width:0
    }
    .kv-table col.kv-key{width:38%}
    .kv-table col.kv-value{width:62%}
    .kv-table th,.kv-table td{
      padding:12px 16px;
      border-bottom:1px solid var(--border);
      vertical-align:top
    }
    .kv-table th{
      background:rgba(255,248,240,.92);
      text-align:left;
      font-size:13px
    }
    .kv-table td:first-child,.kv-table th:first-child{white-space:nowrap}
    .kv-table td:last-child,.kv-table th:last-child{word-break:break-word}
    .kv{width:100%;border-collapse:collapse}
    .kv th,.kv td{
      padding:10px;
      border-bottom:1px solid var(--border);
      text-align:left;
      vertical-align:top
    }
    .kv th{width:220px;color:var(--muted)}
    .empty{
      padding:18px;
      border:1px dashed var(--border);
      border-radius:16px;
      color:var(--muted);
      background:rgba(255,255,255,.55)
    }
    .waveform-embed iframe{
      width:100%;
      min-height:760px;
      border:1px solid rgba(116,92,62,.22);
      border-radius:16px;
      background:#fff
    }

    @media(max-width:1080px){
      .span-7,.span-5{grid-column:span 12}
      .kpi-grid{grid-template-columns:repeat(2,minmax(0,1fr))}
      .table-tools .summary{margin-left:0;width:100%}
    }

    @media(max-width:720px){
      .kpi-grid{grid-template-columns:1fr}
      .kv-table col.kv-key{width:42%}
      .kv-table col.kv-value{width:58%}
    }
    """
    (assets_dir / "explorer.css").write_text(css, encoding="utf-8")

    ordered = sorted(rows, key=best_sort_key)
    best = ordered[0] if ordered else {}
    runs_root = snapshot_root / "runs"
    runs_root.mkdir(parents=True, exist_ok=True)

    for row in ordered:
        base_dir = Path(row["_base_dir"])
        row_dir_name = sanitize_site_component(f"{row.get('_variant','variant')}-{row.get('_run_dir','run')}")
        row_site_dir = runs_root / row_dir_name
        site_artifact_dir = row_site_dir / "artifact"
        published = publish_run_site_artifact(base_dir, row, site_artifact_dir)
        row["_site_artifact_dir"] = str(site_artifact_dir)
        row["_site_metrics_path"] = published.get("metrics.csv", str(site_artifact_dir / "metrics.csv"))
        row["_site_metrics_raw_path"] = published.get("metrics_raw.json", "")
        row["_site_run_meta_path"] = published.get("run_meta.json", "")
        row["_site_failure_summary_path"] = published.get("failure_summary.json", "") or published.get(
            "failure_summary.md", "")
        row["_gds_exists"] = published.get("gds_exists", "no")
        row["_gds_published"] = published.get("gds_published", "no")
        row["_render_path"] = published.get("render_path", "")
        row["_gds_path"] = published.get("gds_path", "")
        row["_gds_href"] = rel_href(Path(published["gds_path"]), snapshot_root) if published.get("gds_path") else ""
        row["_row_href"] = rel_href(row_site_dir / "index.html", snapshot_root)
        write_run_page(row_site_dir, row, "/")

    published_precheck = publish_precheck_site_artifacts(precheck, snapshot_root)

    pages_base = pages_base_url(repo_slug)
    published_snapshot_prefix = pages_base.rstrip("/") if pages_base else ""
    if published_snapshot_prefix and run_id:
        published_snapshot_prefix = (
            f"{published_snapshot_prefix}/runs/"
            f"{urllib.parse.quote(str(run_id), safe='')}"
        )
    elif normalized_site_subdir and published_snapshot_prefix:
        published_snapshot_prefix = published_snapshot_prefix + "/" + urllib.parse.quote(normalized_site_subdir, safe="/")

    local_vcd_href = ""
    published_vcd = ""
    surfer_url = SURFER_WEB_APP_URL
    run_log_href = ""
    yosys_log_href = ""
    yosys_stat_href = ""
    yosys_netlist_href = ""

    if published_precheck.get("vcd_path"):
        local_vcd_href = rel_href(Path(published_precheck["vcd_path"]), snapshot_root)
        if published_snapshot_prefix:
            published_vcd = f"{published_snapshot_prefix}/{local_vcd_href}"
            surfer_url = build_surfer_url(published_vcd)
    if published_precheck.get("run_log"):
        run_log_href = rel_href(Path(published_precheck["run_log"]), snapshot_root)
    if published_precheck.get("yosys_log"):
        yosys_log_href = rel_href(Path(published_precheck["yosys_log"]), snapshot_root)
    if published_precheck.get("yosys_stat_txt"):
        yosys_stat_href = rel_href(Path(published_precheck["yosys_stat_txt"]), snapshot_root)
    elif published_precheck.get("yosys_stat_json"):
        yosys_stat_href = rel_href(Path(published_precheck["yosys_stat_json"]), snapshot_root)
    if published_precheck.get("yosys_netlist"):
        yosys_netlist_href = rel_href(Path(published_precheck["yosys_netlist"]), snapshot_root)

    def pretty_setting(value: Any, default: str = "—") -> str:
        text = str(value or "").strip()
        if not text:
            return default
        low = text.lower()
        if low in {"true", "1", "yes", "enabled", "enable"}:
            return "Enabled"
        if low in {"false", "0", "no", "disabled", "disable"}:
            return "Disabled"
        if low == "default (not overriden)":
            return "Default"
        return text

    run_id_label = str(run_id or "").strip() or "—"
    repo_slug_label = str(repo_slug or "").strip() or "—"

    settings_html = "".join([
        f"<li><strong>Synthesis strategy:</strong> {html.escape(pretty_setting(explorer_settings.get('synth_strategy'), 'Default'))}</li>",
        f"<li><strong>Antenna repair:</strong> {html.escape(pretty_setting(explorer_settings.get('antenna_repair')))}</li>",
        f"<li><strong>Heuristic diode insertion:</strong> {html.escape(pretty_setting(explorer_settings.get('heuristic_diode_insertion')))}</li>",
        f"<li><strong>Post-GRT design repair:</strong> {html.escape(pretty_setting(explorer_settings.get('post_grt_design_repair')))}</li>",
        f"<li><strong>Post-GRT resizer timing:</strong> {html.escape(pretty_setting(explorer_settings.get('post_grt_resizer_timing')))}</li>",
    ])

    stage_values = sorted({str(row.get("_stage_label", "")).strip() for row in ordered if str(row.get("_stage_label", "")).strip()})

    def pretty_stage_label(stage: str) -> str:
        mapping = {
            "coarse": "Coarse",
            "mid": "Mid",
            "refine-1": "Refine-1",
            "refine-2": "Refine-2",
            "refine-3": "Refine-3",
            "1.0 ns": "Refine-1",
            "0.5 ns": "Refine-2",
            "0.125 ns": "Refine-3",
            "5 ns": "Mid",
        }
        return mapping.get(stage, stage.title())

    stage_options_html = "".join(
        f'<option value="{html.escape(stage)}">{html.escape(pretty_stage_label(stage))}</option>'
        for stage in stage_values
    )

    waveform_actions: List[str] = []
    waveform_actions.append(f'<a class="btn" href="{html.escape(surfer_url)}" target="_blank" rel="noopener noreferrer">Surfer Waveform Viewer</a>')
    if local_vcd_href:
        waveform_actions.append(f'<a class="btn secondary" href="{local_vcd_href}">Download VCD</a>')
    if run_log_href:
        waveform_actions.append(f'<a class="btn secondary" href="{run_log_href}">Open Run Log</a>')
    if yosys_log_href:
        waveform_actions.append(f'<a class="btn secondary" href="{yosys_log_href}">Yosys Log</a>')
    if yosys_stat_href:
        waveform_actions.append(f'<a class="btn secondary" href="{yosys_stat_href}">Yosys Statistics</a>')
    if yosys_netlist_href:
        waveform_actions.append(f'<a class="btn secondary" href="{yosys_netlist_href}">Download Synthesized Netlist</a>')

    waveform_embed_html = ""
    if published_vcd:
        waveform_embed_html = (
            '<div class="waveform-embed" style="margin-top:16px;">'
            f'<iframe src="{html.escape(surfer_url)}" '
            'title="Embedded waveform viewer" '
            'loading="lazy" '
            'referrerpolicy="strict-origin-when-cross-origin"></iframe>'
            '</div>'
        )

    def sort_num_value(value: Any) -> str:
        n = to_float(value)
        return "" if n is None else str(n)

    rows_html: List[str] = []
    for idx, row in enumerate(ordered):
        run_text = f"{row.get('_variant', '')} / {row.get('_run_dir', '')}"
        run_href = str(row.get("_row_href", "#"))

        power_total = to_float(row.get("power_total_W"))
        power_total_display = f"{power_total:.6f}" if power_total is not None else html.escape(
            str(row.get("power_total_W", "")))

        gds_actions: List[str] = []

        if row.get("_gds_exists") == "yes":
            gds_actions.append(
                f'<a class="btn secondary btn-sm" href="{TT_GDS_VIEWER_URL}" target="_blank" rel="noopener">Viewer</a>'
            )

        if row.get("_gds_published") == "yes" and row.get("_gds_href"):
            gds_actions.append(
                f'<a class="btn secondary btn-sm" href="{html.escape(str(row.get("_gds_href", "")))}">Download GDS</a>'
            )
        elif row.get("_gds_exists") == "yes":
            gds_actions.append('<span class="muted">Artifact only</span>')

        gds_html = f'<div class="inline-actions">{"".join(gds_actions)}</div>' if gds_actions else "—"

        row_classes = "best-row" if idx == 0 else ""
        rows_html.append(
            f'''
            <tr class="{row_classes}"
                data-run="{html.escape(run_text)}"
                data-clock="{sort_num_value(row.get('clock_ns'))}"
                data-setup_wns="{sort_num_value(row.get('setup_wns_ns'))}"
                data-setup_tns="{sort_num_value(row.get('setup_tns_ns'))}"
                data-core_area="{sort_num_value(row.get('core_area_um2'))}"
                data-power_total="{sort_num_value(row.get('power_total_W'))}"
                data-drc="{sort_num_value(row.get('drc_errors'))}"
                data-lvs="{sort_num_value(row.get('lvs_errors'))}"
                data-antenna="{sort_num_value(row.get('antenna_violations'))}"
                data-ir_drop="{sort_num_value(row.get('ir_drop_worst_V'))}"
                data-status="{html.escape(str(row.get('status', '')))}"
                data-stage="{html.escape(str(row.get('_stage_label', '')))}"
                data-remarks="{html.escape(str(row.get('selection_reason', '')))}"
                data-selected="{'1' if idx == 0 else '0'}">
              <td data-sort="{html.escape(run_text)}">
                <a href="{html.escape(run_href)}">
                  {html.escape(run_text)}
                </a>
              </td>
              <td data-sort="{html.escape(str(row.get('clock_ns', '')))}">{html.escape(str(row.get('clock_ns', '')))}</td>
              <td data-sort="{html.escape(str(row.get('setup_wns_ns', '')))}">{html.escape(str(row.get('setup_wns_ns', '')))}</td>
              <td data-sort="{html.escape(str(row.get('setup_tns_ns', '')))}">{html.escape(str(row.get('setup_tns_ns', '')))}</td>
              <td data-sort="{html.escape(str(row.get('core_area_um2', '')))}">{html.escape(str(row.get('core_area_um2', '')))}</td>
              <td data-sort="{sort_num_value(row.get('power_total_W'))}">{power_total_display}</td>
              <td data-sort="{html.escape(str(row.get('drc_errors', '')))}">{html.escape(str(row.get('drc_errors', '')))}</td>
              <td data-sort="{html.escape(str(row.get('lvs_errors', '')))}">{html.escape(str(row.get('lvs_errors', '')))}</td>
              <td data-sort="{html.escape(str(row.get('antenna_violations', '')))}">{html.escape(str(row.get('antenna_violations', '')))}</td>
              <td data-sort="{html.escape(str(row.get('ir_drop_worst_V', '')))}">{html.escape(str(row.get('ir_drop_worst_V', '')))}</td>
              <td>{badge_html(row.get('status', ''))}</td>
              <td>{html.escape(str(row.get('selection_reason', '')))}</td>
              <td>{gds_html}</td>
            </tr>
            '''
        )

    sort_filter_script = """
<script>
(function () {
  const table = document.querySelector(".wide-table");
  if (!table) return;
  const tbody = table.querySelector("tbody");
  const headerButtons = Array.from(document.querySelectorAll(".sort-btn"));
  const statusFilter = document.getElementById("statusFilter");
  const stageFilter = document.getElementById("stageFilter");
  const searchFilter = document.getElementById("searchFilter");
  const pinSelected = document.getElementById("pinSelected");
  const visibleSummary = document.getElementById("visibleRowsSummary");
  const allRows = Array.from(tbody.querySelectorAll("tr"));
  let currentKey = "";
  let currentDir = "asc";
  const statusRank = {"PASS": 0, "TIMING_FAIL": 1, "SIGNOFF_FAIL": 2, "SIGNOFF_AND_TIMING_FAIL": 3, "FLOW_FAIL": 4};
  function getRowValue(row, key, type) {
    const raw = (row.dataset[key] || "").trim();
    if (type === "number") {
      if (raw === "") return Number.POSITIVE_INFINITY;
      const parsed = Number(raw);
      return Number.isFinite(parsed) ? parsed : Number.POSITIVE_INFINITY;
    }
    if (type === "status") {
      return Object.prototype.hasOwnProperty.call(statusRank, raw) ? statusRank[raw] : 999;
    }
    return raw.toLowerCase();
  }
  function updateHeaderState() {
    headerButtons.forEach((btn) => {
      const indicator = btn.querySelector(".sort-indicator");
      const isActive = btn.dataset.key === currentKey;
      btn.classList.toggle("active", isActive);
      btn.setAttribute("aria-sort", isActive ? (currentDir === "asc" ? "ascending" : "descending") : "none");
      if (indicator) indicator.textContent = isActive ? (currentDir === "asc" ? "▲" : "▼") : "↕";
    });
  }
  function applyFilters(rows) {
    const wantedStatus = statusFilter && statusFilter.value ? statusFilter.value : "";
    const wantedStage = stageFilter && stageFilter.value ? stageFilter.value : "";
    const term = searchFilter && searchFilter.value ? searchFilter.value.trim().toLowerCase() : "";
    return rows.filter((row) => {
      const statusOk = !wantedStatus || (row.dataset.status || "") === wantedStatus;
      const stageOk = !wantedStage || (row.dataset.stage || "") === wantedStage;
      const haystack = [row.dataset.run || "", row.dataset.status || "", row.dataset.stage || "", row.dataset.remarks || ""].join(" ").toLowerCase();
      const searchOk = !term || haystack.includes(term);
      return statusOk && stageOk && searchOk;
    });
  }
  function render() {
    let rows = applyFilters(allRows.slice());
    if (currentKey) {
      const activeBtn = headerButtons.find((btn) => btn.dataset.key === currentKey);
      const type = activeBtn ? (activeBtn.dataset.type || "text") : "text";
      rows.sort((a, b) => {
        const av = getRowValue(a, currentKey, type);
        const bv = getRowValue(b, currentKey, type);
        if (av < bv) return currentDir === "asc" ? -1 : 1;
        if (av > bv) return currentDir === "asc" ? 1 : -1;
        return 0;
      });
    }
    if (pinSelected && pinSelected.checked) {
      rows.sort((a, b) => Number(b.dataset.selected || "0") - Number(a.dataset.selected || "0"));
    }
    tbody.innerHTML = "";
    rows.forEach((row) => tbody.appendChild(row));
    if (visibleSummary) visibleSummary.textContent = "Showing " + rows.length + " of " + allRows.length + " runs";
    updateHeaderState();
  }
  headerButtons.forEach((btn) => {
    btn.addEventListener("click", () => {
      const key = btn.dataset.key || "";
      if (!key) return;
      if (currentKey === key) currentDir = currentDir === "asc" ? "desc" : "asc";
      else { currentKey = key; currentDir = "asc"; }
      render();
    });
  });
  [statusFilter, stageFilter, searchFilter, pinSelected].forEach((el) => {
    if (!el) return;
    el.addEventListener("input", render);
    el.addEventListener("change", render);
  });
  render();
})();
</script>
"""

    site_manifest = {
        "repo_slug": repo_slug,
        "run_id": run_id,
        "site_subdir": normalized_site_subdir,
        "entrypoint": f"{normalized_site_subdir + '/' if normalized_site_subdir else ''}index.html",
        "snapshot_root": str(snapshot_root.relative_to(site_root)) if snapshot_root != site_root else ".",
    }
    (site_root / "site_manifest.json").write_text(json.dumps(site_manifest, indent=2), encoding="utf-8")

    selection_block = (
        f'<section class="card span-7"><h2>Best Run</h2><p><strong>Run:</strong> {html.escape(str(best.get("_variant","")))} / {html.escape(str(best.get("_run_dir","")))}</p><p><strong>Clock:</strong> {html.escape(str(best.get("clock_ns","")))} ns</p><p><strong>Status:</strong> {badge_html(best.get("status",""))}</p><p><strong>Remarks:</strong> {html.escape(str(best.get("selection_reason","")))}</p></section>'
        if best else '<section class="card span-7"><h2>Best Run</h2><p class="muted">No ASIC run rows were collected for this snapshot.</p></section>'
    )

    index_html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ASIC Flow Run Explorer</title>
  <link rel="stylesheet" href="assets/explorer.css">
</head>
<body>
  <div class="wrap">
    <section class="hero">
      <div class="hero-head">
        <div class="hero-copy">
          <h1>ASIC Flow Run Explorer</h1>
          <p>Published summary of all collected runs, richer per-run metrics, and direct access to downloadable layout data.</p>
          <p><strong>Workflow:</strong> Icarus RTL simulation → VCD waveform viewer on Surfer → Yosys structural pre-check → existing ASIC comparison.</p>
          <p><strong>Snapshot run ID:</strong> {html.escape(run_id_label)}<br><strong>Repository:</strong> {html.escape(repo_slug_label)}</p>
          <ul class="settings-list">{settings_html}</ul>
        </div>
      </div>
    </section>

    <div class="grid">
      <section class="card span-5">
        <h2>Selection Criteria</h2>
        <ol>
          <li>Clean signoff plus non-negative setup timing wins.</li>
          <li>If no full PASS exists, clean signoff wins over signoff violations.</li>
          <li>Among comparable runs, lower requested clock period is preferred.</li>
          <li>Setup WNS/TNS are used as tie-breakers.</li>
        </ol>
      </section>

      {selection_block}

      <section class="card span-12">
        <h2>Waveform Viewer</h2>
        <div class="actions">{''.join(waveform_actions)}</div>
        {waveform_embed_html if waveform_embed_html else ('' if local_vcd_href else '<div class="empty">No published VCD was found for this snapshot.</div>')}
      </section>

      <section class="card span-12">
        <h2>Run overview</h2>
        <div class="kpi-grid">
          <div class="stat"><div class="label">Total runs</div><div class="value">{len(ordered)}</div></div>
          <div class="stat"><div class="label">PASS runs</div><div class="value">{sum(1 for r in ordered if r.get('status') == 'PASS')}</div></div>
          <div class="stat"><div class="label">Non-pass runs</div><div class="value">{sum(1 for r in ordered if r.get('status') != 'PASS')}</div></div>
          <div class="stat"><div class="label">Best clock</div><div class="value">{html.escape(str(best.get('clock_ns', '')))}</div></div>
        </div>
      </section>
    </div>

    <section class="card table-card section-gap-lg">
      <div class="table-head"><h2>Run Comparison Table</h2><span>Top row is the selected best run</span></div>
      <div class="table-tools">
        <label>Status
          <select id="statusFilter">
            <option value="">All</option>
            <option value="PASS">PASS</option>
            <option value="TIMING_FAIL">TIMING_FAIL</option>
            <option value="SIGNOFF_FAIL">SIGNOFF_FAIL</option>
            <option value="SIGNOFF_AND_TIMING_FAIL">SIGNOFF_AND_TIMING_FAIL</option>
            <option value="FLOW_FAIL">FLOW_FAIL</option>
          </select>
        </label>
        <label>Stage
          <select id="stageFilter">
            <option value="">All</option>
            {stage_options_html}
          </select>
        </label>
        <label>Search
          <input id="searchFilter" type="search" placeholder="Run, remarks, status...">
        </label>
        <label class="inline-check">
          <input type="checkbox" id="pinSelected" checked>
          Keep selected run on top
        </label>
        <div class="summary" id="visibleRowsSummary"></div>
      </div>
      <div class="table-wrap">
        <table class="wide-table">
          <thead>
            <tr>
            <th><button class="sort-btn" data-key="run" data-type="text" aria-sort="none">Run <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="clock" data-type="number" aria-sort="none">Clock (ns) <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="setup_wns" data-type="number" aria-sort="none">Setup WNS (ns) <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="setup_tns" data-type="number" aria-sort="none">Setup TNS (ns) <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="core_area" data-type="number" aria-sort="none">Core Area (μm²) <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="power_total" data-type="number" aria-sort="none">Total Power (W) <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="drc" data-type="number" aria-sort="none">DRC <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="lvs" data-type="number" aria-sort="none">LVS <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="antenna" data-type="number" aria-sort="none">Antenna <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="ir_drop" data-type="number" aria-sort="none">IR Drop (V) <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="status" data-type="status" aria-sort="none">Status <span class="sort-indicator">↕</span></button></th>
            <th><button class="sort-btn" data-key="remarks" data-type="text" aria-sort="none">Remarks <span class="sort-indicator">↕</span></button></th>
            <th>GDS</th>
            </tr>
          </thead>
          <tbody>{''.join(rows_html) if rows_html else '<tr><td colspan="14" class="muted">No ASIC run rows were collected for this snapshot.</td></tr>'}</tbody>
        </table>
      </div>
    </section>
  </div>
  {sort_filter_script}
</body>
</html>"""
    (snapshot_root / "index.html").write_text(index_html, encoding="utf-8")

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts-root", type=Path, required=True)
    ap.add_argument("--summary-md", type=Path, required=True)
    ap.add_argument("--summary-csv", type=Path, required=True)
    ap.add_argument("--best-json", type=Path, required=True)
    ap.add_argument("--best-bundle-dir", type=Path, default=Path("best-layout-bundle"))
    ap.add_argument("--site-dir", type=Path, default=Path("_site"))
    ap.add_argument("--site-subdir", default="")
    ap.add_argument("--repo-slug", default="")
    ap.add_argument("--run-id", default="")
    ap.add_argument("--summary-synth-strategy", default="")
    ap.add_argument("--summary-antenna-repair", default="")
    ap.add_argument("--summary-heuristic-diode-insertion", default="")
    ap.add_argument("--summary-post-grt-design-repair", default="")
    ap.add_argument("--summary-post-grt-resizer-timing", default="")
    args = ap.parse_args()

    rows = collect_rows(args.artifacts_root)
    precheck = collect_precheck(args.artifacts_root)
    write_summary_csv(args.summary_csv, rows)
    write_summary_md(args.summary_md, rows, precheck)
    best = write_best_json(args.best_json, rows)
    package_best_bundle(args.best_bundle_dir, best, precheck)
    build_site(
        args.site_dir,
        rows,
        precheck,
        explorer_settings={
            "synth_strategy": args.summary_synth_strategy,
            "antenna_repair": args.summary_antenna_repair,
            "heuristic_diode_insertion": args.summary_heuristic_diode_insertion,
            "post_grt_design_repair": args.summary_post_grt_design_repair,
            "post_grt_resizer_timing": args.summary_post_grt_resizer_timing,
        },
        repo_slug=args.repo_slug,
        run_id=args.run_id,
        site_subdir=args.site_subdir,
    )

if __name__ == "__main__":
    main()

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
        "## Best run selection",
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
    return urllib.parse.quote(str(path.relative_to(root)).replace(os.sep, "/"))


def badge_html(status: str) -> str:
    s = str(status or "").upper()
    cls = {
        "PASS": "pass",
        "WARN": "warn",
        "FAIL": "fail",
        "SKIP": "skip",
        "TIMING_FAIL": "fail",
        "SIGNOFF_FAIL": "fail",
        "SIGNOFF_AND_TIMING_FAIL": "fail",
        "FLOW_FAIL": "fail",
        "MISSING": "skip",
    }.get(s, "skip")
    return f'<span class="badge {cls}">{html.escape(s or "UNKNOWN")}</span>'


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
    render_href = rel_href(Path(row["_render_path"]), run_dir) if row.get("_render_path") else ""
    gds_href = rel_href(Path(row["_gds_path"]), run_dir) if row.get("_gds_path") else ""
    metrics_path = Path(row.get("_site_metrics_path") or (Path(row["_base_dir"]) / "metrics.csv"))
    metrics_href = rel_href(metrics_path, run_dir)
    failure_summary_href = rel_href(Path(row["_site_failure_summary_path"]), run_dir) if row.get("_site_failure_summary_path") else ""
    raw_metrics_href = rel_href(Path(row["_site_metrics_raw_path"]), run_dir) if row.get("_site_metrics_raw_path") else ""
    meta_href = rel_href(Path(row["_site_run_meta_path"]), run_dir) if row.get("_site_run_meta_path") else ""
    details = [
        ("Variant", row.get("_variant", "")),
        ("Stage", row.get("_stage_label", "")),
        ("Requested clock", f"{row.get('_clock_requested','')} ns"),
        ("Reported clock", f"{row.get('clock_ns','')} ns"),
        ("Setup WNS", row.get("setup_wns_ns", "")),
        ("Setup TNS", row.get("setup_tns_ns", "")),
        ("Core area", row.get("core_area_um2", "")),
        ("Total power", row.get("power_total_W", "")),
        ("DRC", row.get("drc_errors", "")),
        ("LVS", row.get("lvs_errors", "")),
        ("Antenna", row.get("antenna_violations", "")),
        ("Published on Pages", "Lightweight explorer assets only"),
        ("Heavy backend outputs", "Kept in GitHub Actions artifacts, not GitHub Pages"),
    ]
    actions = [
        f'<a class="btn" href="../index.html">Back to explorer</a>',
        f'<a class="btn" href="{metrics_href}">Open metrics.csv</a>',
    ]
    if raw_metrics_href:
        actions.append(f'<a class="btn" href="{raw_metrics_href}">Open metrics_raw.json</a>')
    if meta_href:
        actions.append(f'<a class="btn" href="{meta_href}">Open run_meta.json</a>')
    if failure_summary_href:
        actions.append(f'<a class="btn" href="{failure_summary_href}">Open failure summary</a>')
    if gds_href:
        actions.append(f'<a class="btn" href="{gds_href}">Download GDS</a>')
        actions.append(f'<a class="btn" href="{TT_GDS_VIEWER_URL}" target="_blank" rel="noopener">Open GDS viewer</a>')
    elif row.get("_gds_exists") == "yes":
        actions.append(f'<a class="btn" href="{TT_GDS_VIEWER_URL}" target="_blank" rel="noopener">Open GDS viewer homepage</a>')
    preview = f'<img src="{render_href}" alt="layout preview">' if render_href else '<div class="empty">No rendered layout preview found for this run.</div>'
    gds_note = (
        '<p class="muted">Heavy ASIC outputs, including most GDS assets, are intentionally kept out of GitHub Pages so the explorer stays below the Pages size limit. Use the workflow artifacts for full backend outputs.</p>'
        if row.get("_gds_exists") == "yes" and not gds_href
        else ''
    )
    table_rows = "".join(f"<tr><th>{html.escape(k)}</th><td>{html.escape(v)}</td></tr>" for k, v in details)
    content = f"""<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>{html.escape(row.get('_variant',''))} / {html.escape(row.get('_run_dir',''))}</title>
  <link rel=\"stylesheet\" href=\"../assets/explorer.css\">
</head>
<body>
  <main class=\"page\">
    <section class=\"hero\">
      <div>
        <p class=\"eyebrow\">Per-run details</p>
        <h1>{html.escape(row.get('_variant',''))} / {html.escape(row.get('_run_dir',''))}</h1>
        <p class=\"muted\">{badge_html(row.get('status',''))} &nbsp; Remarks: {html.escape(row.get('selection_reason',''))}</p>
      </div>
      <div class=\"actions\">{''.join(actions)}</div>
    </section>
    <section class=\"card\">
      <h2>Metrics by category</h2>
      <table class=\"kv\">{table_rows}</table>
    </section>
    <section class=\"card\">
      <h2>Layout preview</h2>
      {preview}
      {gds_note}
    </section>
  </main>
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
:root{color-scheme:light dark;--bg:#f4ecdf;--bg-2:#efe4d3;--panel:rgba(255,250,243,.90);--panel-2:rgba(255,255,255,.95);--border:rgba(116,92,62,.20);--text:#2b2218;--muted:#6a5741;--accent:#8b5e3c;--pass:#1f7a45;--warn:#a86e10;--fail:#a12b2b;--skip:#6f7680;--shadow:0 18px 45px rgba(110,84,53,.10)}
*{box-sizing:border-box} body{margin:0;font-family:Inter,Segoe UI,Arial,sans-serif;background:linear-gradient(180deg,var(--bg),var(--bg-2));color:var(--text)} a{color:var(--accent);text-decoration:none} img{max-width:100%;border-radius:14px;border:1px solid var(--border)} .page{max-width:1280px;margin:0 auto;padding:24px}.hero,.card{background:var(--panel);border:1px solid var(--border);border-radius:22px;box-shadow:var(--shadow)} .hero{padding:26px 28px;display:grid;gap:16px} .eyebrow{margin:0 0 8px 0;color:var(--muted);font-weight:700;text-transform:uppercase;letter-spacing:.08em;font-size:.78rem} h1,h2,h3{margin:0 0 12px 0}.muted{color:var(--muted)} .actions{display:flex;flex-wrap:wrap;gap:10px}.btn{display:inline-flex;align-items:center;justify-content:center;padding:10px 14px;border-radius:12px;border:1px solid var(--border);background:var(--panel-2);font-weight:700}.grid{display:grid;gap:16px}.card{padding:20px}.status-strip{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}.pill{padding:12px 14px;border-radius:16px;background:var(--panel-2);border:1px solid var(--border)} .pill .k{display:block;color:var(--muted);font-size:.8rem;margin-bottom:4px}.badge{display:inline-flex;padding:6px 10px;border-radius:999px;color:#fff;font-weight:800;font-size:.8rem;letter-spacing:.03em}.badge.pass{background:var(--pass)}.badge.warn{background:var(--warn)}.badge.fail{background:var(--fail)}.badge.skip{background:var(--skip)} .iframe-wrap{aspect-ratio:16/9;border:1px solid var(--border);border-radius:16px;overflow:hidden;background:#fff}.iframe-wrap iframe{width:100%;height:100%;border:0} .empty{padding:24px;border:1px dashed var(--border);border-radius:16px;color:var(--muted);background:rgba(255,255,255,.55)} .table-wrap{overflow:auto}.table{width:100%;border-collapse:collapse}.table th,.table td{padding:12px 10px;border-bottom:1px solid var(--border);text-align:left;vertical-align:top}.table th{font-size:.9rem;color:var(--muted);position:sticky;top:0;background:rgba(255,248,238,.98)} .filters{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px}.filters input,.filters select{padding:10px 12px;border-radius:12px;border:1px solid var(--border);background:var(--panel-2);min-width:180px}.kv{width:100%;border-collapse:collapse}.kv th,.kv td{padding:10px;border-bottom:1px solid var(--border);text-align:left;vertical-align:top}.kv th{width:220px;color:var(--muted)} .best{outline:2px solid rgba(139,94,60,.28)} @media (min-width:960px){.hero{grid-template-columns:1.6fr .9fr;align-items:center}} 
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
        row["_site_failure_summary_path"] = published.get("failure_summary.json", "") or published.get("failure_summary.md", "")
        row["_gds_exists"] = published.get("gds_exists", "no")
        row["_gds_published"] = published.get("gds_published", "no")
        if published.get("render_path"):
            row["_render_path"] = published["render_path"]
        else:
            row["_render_path"] = ""
        row["_gds_path"] = ""
        row["_row_href"] = rel_href(row_site_dir / "index.html", snapshot_root)
        write_run_page(row_site_dir, row, "/")

    published_precheck = publish_precheck_site_artifacts(precheck, snapshot_root)

    pages_base = pages_base_url(repo_slug)
    published_vcd = ""
    surfer_url = ""
    local_vcd_href = ""
    compile_log_href = ""
    run_log_href = ""
    yosys_log_href = ""
    yosys_stat_href = ""
    yosys_netlist_href = ""
    published_snapshot_prefix = pages_base.rstrip("/") if pages_base else ""
    if normalized_site_subdir and published_snapshot_prefix:
        published_snapshot_prefix = (
                published_snapshot_prefix
                + "/"
                + urllib.parse.quote(normalized_site_subdir, safe="/")
        )

    if published_precheck.get("vcd_path"):
        local_vcd_href = rel_href(Path(published_precheck["vcd_path"]), snapshot_root)
        if published_snapshot_prefix:
            published_vcd = f"{published_snapshot_prefix}/{local_vcd_href}"
            surfer_url = build_surfer_url(published_vcd)
    if published_precheck.get("compile_log"):
        compile_log_href = rel_href(Path(published_precheck["compile_log"]), snapshot_root)
    if published_precheck.get("run_log"):
        run_log_href = rel_href(Path(published_precheck["run_log"]), snapshot_root)
    if published_precheck.get("yosys_log"):
        yosys_log_href = rel_href(Path(published_precheck["yosys_log"]), snapshot_root)
    if published_precheck.get("yosys_stat_txt"):
        yosys_stat_href = rel_href(Path(published_precheck["yosys_stat_txt"]), snapshot_root)
    if published_precheck.get("yosys_netlist"):
        yosys_netlist_href = rel_href(Path(published_precheck["yosys_netlist"]), snapshot_root)

    stage_options = sorted({row.get("_stage_label", "") for row in ordered if row.get("_stage_label")})
    stage_options_html = "".join(f'<option value="{html.escape(x)}">{html.escape(x)}</option>' for x in stage_options)

    settings_rows = "".join(
        f"<tr><th>{html.escape(k.replace('_',' ').title())}</th><td>{html.escape(str(v or ''))}</td></tr>"
        for k, v in explorer_settings.items()
    ) or '<tr><th>Settings</th><td>Workflow summary settings were not provided for this snapshot.</td></tr>'

    precheck_strip = f"""
<div class=\"status-strip\">
  <div class=\"pill\"><span class=\"k\">Icarus</span>{badge_html(precheck.get('icarus', {}).get('status', 'MISSING'))}</div>
  <div class=\"pill\"><span class=\"k\">Yosys</span>{badge_html(precheck.get('yosys', {}).get('status', 'MISSING'))}</div>
  <div class=\"pill\"><span class=\"k\">Top module</span>{html.escape(str(precheck.get('top_module','')))}</div>
  <div class=\"pill\"><span class=\"k\">TB top</span>{html.escape(str(precheck.get('testbench_top','') or '—'))}</div>
  <div class=\"pill\"><span class=\"k\">VCD present</span>{'Yes' if precheck.get('vcd_present') else 'No'}</div>
  <div class=\"pill\"><span class=\"k\">ASIC gating</span>{'Proceed' if precheck.get('gate_ok') else 'Stopped before ASIC'}</div>
</div>
"""

    waveform_actions = []
    if surfer_url:
        waveform_actions.append(f'<a class="btn" href="{html.escape(surfer_url)}" target="_blank" rel="noopener">Open VCD waveform viewer on Surfer</a>')
    if local_vcd_href:
        waveform_actions.append(f'<a class="btn" href="{local_vcd_href}">Download VCD</a>')
    if compile_log_href:
        waveform_actions.append(f'<a class="btn" href="{compile_log_href}">Open compile log</a>')
    if run_log_href:
        waveform_actions.append(f'<a class="btn" href="{run_log_href}">Open run log</a>')
    if yosys_log_href:
        waveform_actions.append(f'<a class="btn" href="{yosys_log_href}">Open Yosys log</a>')
    if yosys_stat_href:
        waveform_actions.append(f'<a class="btn" href="{yosys_stat_href}">Open stat.txt</a>')
    if yosys_netlist_href:
        waveform_actions.append(f'<a class="btn" href="{yosys_netlist_href}">Open synthesized netlist</a>')
    waveform_body = (
        f'<div class="iframe-wrap"><iframe src="{html.escape(surfer_url)}" title="Surfer waveform viewer" loading="lazy"></iframe></div>'
        if surfer_url
        else '<div class="empty">The VCD was not published for this snapshot, so the embedded Surfer view is unavailable.</div>'
    )

    best_block = (
        f"<div class=\"card best\"><h2>Chosen best run</h2><p><strong>Run:</strong> {html.escape(str(best.get('_variant','')))} / {html.escape(str(best.get('_run_dir','')))}</p><p><strong>Clock:</strong> {html.escape(str(best.get('clock_ns','')))} ns</p><p><strong>Status:</strong> {badge_html(best.get('status',''))}</p><p><strong>Remarks:</strong> {html.escape(str(best.get('selection_reason','')))}</p></div>"
        if best
        else '<div class="card"><h2>Chosen best run</h2><p class="muted">No ASIC attempt metrics were collected for this snapshot.</p></div>'
    )

    rows_html = []
    for idx, row in enumerate(ordered):
        if row.get("_gds_path"):
            gds = '<a href="{}">GDS</a>'.format(rel_href(Path(row["_gds_path"]), snapshot_root))
            viewer = f'<a href="{TT_GDS_VIEWER_URL}" target="_blank" rel="noopener">Viewer</a>'
        elif row.get("_gds_exists") == "yes":
            gds = 'Artifact only'
            viewer = f'<a href="{TT_GDS_VIEWER_URL}" target="_blank" rel="noopener">Homepage</a>'
        else:
            gds = '—'
            viewer = '—'
        classes = 'best' if idx == 0 else ''
        rows_html.append(
            f"<tr class=\"{classes}\" data-status=\"{html.escape(row.get('status',''))}\" data-stage=\"{html.escape(row.get('_stage_label',''))}\">"
            f"<td>{'Selected' if idx == 0 else ''}</td>"
            f"<td><a href=\"{html.escape(row.get('_row_href',''))}\">{html.escape(row.get('_variant',''))} / {html.escape(row.get('_run_dir',''))}</a></td>"
            f"<td>{html.escape(row.get('clock_ns',''))}</td>"
            f"<td>{html.escape(row.get('setup_wns_ns',''))}</td>"
            f"<td>{html.escape(row.get('setup_tns_ns',''))}</td>"
            f"<td>{html.escape(row.get('core_area_um2',''))}</td>"
            f"<td>{html.escape(row.get('power_total_W',''))}</td>"
            f"<td>{html.escape(row.get('drc_errors',''))}</td>"
            f"<td>{html.escape(row.get('lvs_errors',''))}</td>"
            f"<td>{html.escape(row.get('antenna_violations',''))}</td>"
            f"<td>{html.escape(row.get('ir_drop_worst_V',''))}</td>"
            f"<td>{badge_html(row.get('status',''))}</td>"
            f"<td>{html.escape(row.get('selection_reason',''))}</td>"
            f"<td>{gds}</td>"
            f"<td>{viewer}</td>"
            "</tr>"
        )

    sort_filter_script = """
<script>
(() => {
  const q = document.getElementById('searchBox');
  const s = document.getElementById('statusFilter');
  const g = document.getElementById('stageFilter');
  const rows = Array.from(document.querySelectorAll('tbody tr'));
  function apply(){
    const needle = (q.value || '').toLowerCase();
    const status = s.value;
    const stage = g.value;
    for(const row of rows){
      const txt = row.innerText.toLowerCase();
      const okText = !needle || txt.includes(needle);
      const okStatus = !status || row.dataset.status === status;
      const okStage = !stage || row.dataset.stage === stage;
      row.style.display = (okText && okStatus && okStage) ? '' : 'none';
    }
  }
  [q,s,g].forEach(el => el && el.addEventListener('input', apply));
  apply();
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

    title_run = f"GitHub run {run_id}" if str(run_id).strip() else "current snapshot"
    best_text = (
        f"<p><strong>Selected best run:</strong> {html.escape(str(best.get('_variant','')))} / {html.escape(str(best.get('_run_dir','')))}</p>"
        if best else "<p class=\"muted\">No ASIC best run is available because no metrics.csv files were collected.</p>"
    )

    index_html = f"""<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>ASIC Flow Run Explorer</title>
  <link rel=\"stylesheet\" href=\"assets/explorer.css\">
</head>
<body>
  <main class=\"page grid\">
    <section class=\"hero\">
      <div>
        <p class=\"eyebrow\">Variant-driven Sky130 + OpenLane2 / LibreLane explorer</p>
        <h1>ASIC Flow Run Explorer</h1>
        <p class=\"muted\">Snapshot: {html.escape(title_run)}. This page now shows the front-end precheck sequence first: Icarus RTL simulation → VCD waveform viewer on Surfer → Yosys structural pre-check → existing ASIC comparison.</p>
      </div>
      <div class=\"actions\">{''.join(waveform_actions[:1]) if waveform_actions else ''}</div>
    </section>

    <section class=\"card\">
      <h2>Precheck status</h2>
      {precheck_strip}
    </section>

    <section class=\"card\">
      <h2>Embedded waveform</h2>
      <p class=\"muted\">The summary surface links the first stage directly to the VCD waveform on Surfer before the structural Yosys check and the ASIC matrix results.</p>
      <div class=\"actions\">{''.join(waveform_actions)}</div>
      {waveform_body}
    </section>

    {best_block}

    <section class=\"card\">
      <h2>Explorer settings</h2>
      <table class=\"kv\">{settings_rows}</table>
    </section>

    <section class=\"card\">
      <h2>Selection order</h2>
      <ol>
        <li>Clean signoff plus non-negative setup timing wins.</li>
        <li>If no full PASS exists, clean signoff wins over signoff violations.</li>
        <li>Among comparable runs, lower requested clock period is preferred.</li>
        <li>Setup WNS/TNS are used as tie-breakers.</li>
      </ol>
      {best_text}
    </section>

    <section class=\"card\">
      <h2>All runs</h2>
      <div class=\"filters\">
        <select id=\"statusFilter\"><option value=\"\">Status: All</option><option>PASS</option><option>TIMING_FAIL</option><option>SIGNOFF_FAIL</option><option>SIGNOFF_AND_TIMING_FAIL</option><option>FLOW_FAIL</option></select>
        <select id=\"stageFilter\"><option value=\"\">Stage: All</option>{stage_options_html}</select>
        <input id=\"searchBox\" placeholder=\"Search runs, remarks, metrics\">
      </div>
      <div class=\"table-wrap\">
        <table class=\"table\">
          <thead>
            <tr>
              <th>Selected</th><th>Run</th><th>Clock (ns)</th><th>Setup WNS</th><th>Setup TNS</th><th>Core area</th><th>Total power</th><th>DRC</th><th>LVS</th><th>Antenna</th><th>IR drop</th><th>Status</th><th>Remarks</th><th>GDS</th><th>GDS Viewer</th>
            </tr>
          </thead>
          <tbody>{''.join(rows_html) if rows_html else '<tr><td colspan="15" class="muted">No ASIC run rows were collected for this snapshot.</td></tr>'}</tbody>
        </table>
      </div>
    </section>
  </main>
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

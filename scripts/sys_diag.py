#!/usr/bin/env python3
# devops-portfolio/scripts/sys_diag.py
"""Lightweight Linux system diagnostics. Python stdlib only.

Inspects CPU load, RAM, disk, and zombie/defunct processes, then emits a
clean JSON report to stdout. Intended for EC2 hosts (Ubuntu/RHEL).

Usage:
    python3 sys_diag.py            # pretty JSON report
    python3 sys_diag.py --compact  # single-line JSON (log-friendly)
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess


def sh(cmd):
    """Run a shell command, return stripped stdout (empty string on failure)."""
    try:
        return subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=10
        ).stdout.strip()
    except Exception:
        return ""


def cpu():
    """Load averages + per-CPU normalized load."""
    one, five, fifteen = os.getloadavg()
    cores = os.cpu_count() or 1
    return {
        "cores": cores,
        "load_1m": round(one, 2),
        "load_5m": round(five, 2),
        "load_15m": round(fifteen, 2),
        "load_1m_per_core": round(one / cores, 2),
    }


def memory():
    """Parse /proc/meminfo (values in kB)."""
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, _, rest = line.partition(":")
            info[key.strip()] = int(rest.strip().split()[0])
    total = info["MemTotal"]
    avail = info.get("MemAvailable", info["MemFree"])
    swap_total = info.get("SwapTotal", 0)
    swap_free = info.get("SwapFree", 0)
    return {
        "total_mb": total // 1024,
        "available_mb": avail // 1024,
        "used_mb": (total - avail) // 1024,
        "used_pct": round((total - avail) / total * 100, 1),
        "swap_total_mb": swap_total // 1024,
        "swap_used_pct": (
            round((swap_total - swap_free) / swap_total * 100, 1)
            if swap_total else 0.0
        ),
    }


def disk():
    """Usage for common mount points that exist."""
    out = {}
    for part in ("/", "/var", "/tmp", "/home"):
        if os.path.ismount(part) or part == "/":
            if os.path.exists(part):
                total, used, free = shutil.disk_usage(part)
                out[part] = {
                    "total_gb": round(total / 2 ** 30, 1),
                    "used_gb": round(used / 2 ** 30, 1),
                    "free_gb": round(free / 2 ** 30, 1),
                    "used_pct": round(used / total * 100, 1),
                }
    return out


def zombies():
    """Detect zombie/defunct processes by scanning /proc/<pid>/stat."""
    found = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat") as f:
                data = f.read()
            # /proc/<pid>/stat layout: pid (comm) state ppid ...
            # comm may contain spaces/parens, so slice on the outer parens.
            comm = data[data.find("(") + 1: data.rfind(")")]
            state = data[data.rfind(")") + 2]
            if state == "Z":
                ppid = data[data.rfind(")") + 2:].split()[1]
                found.append({"pid": int(pid), "comm": comm, "ppid": int(ppid)})
        except (FileNotFoundError, ProcessLookupError, IndexError, ValueError):
            continue
    return {"count": len(found), "processes": found}


def top_procs(limit=6):
    """Top processes by CPU as structured rows."""
    raw = sh(f"ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -{limit + 1}")
    rows = []
    for line in raw.splitlines()[1:]:
        cols = line.split(None, 3)
        if len(cols) == 4:
            rows.append({
                "pid": int(cols[0]),
                "comm": cols[1],
                "cpu_pct": float(cols[2]),
                "mem_pct": float(cols[3]),
            })
    return rows


def build_report():
    return {
        "ts": datetime.datetime.utcnow().isoformat() + "Z",
        "host": os.uname().nodename,
        "kernel": os.uname().release,
        "cpu": cpu(),
        "memory": memory(),
        "disk": disk(),
        "zombies": zombies(),
        "top_processes": top_procs(),
    }


def main():
    parser = argparse.ArgumentParser(description="Linux system diagnostics (JSON).")
    parser.add_argument("--compact", action="store_true", help="single-line JSON")
    args = parser.parse_args()
    report = build_report()
    if args.compact:
        print(json.dumps(report, separators=(",", ":")))
    else:
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

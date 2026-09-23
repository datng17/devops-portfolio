#!/usr/bin/env python3
"""Probes Nginx, app, and DB endpoints. Exits non-zero on failure (cron/alarm friendly)."""
import os
import sys
import urllib.request

BASE = os.getenv("APP_BASE_URL", "https://test.name.vn")

CHECKS = [
    ("nginx->app health", f"{BASE}/health", 200),
    ("app db health", f"{BASE}/health/db", 200),
]


def probe(url, expect):
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status == expect
    except Exception as e:  # noqa: BLE001
        print(f"  error: {e}")
        return False


def main():
    failed = 0
    for name, url, expect in CHECKS:
        ok = probe(url, expect)
        print(f"[{'OK' if ok else 'FAIL'}] {name} ({url})")
        failed += 0 if ok else 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

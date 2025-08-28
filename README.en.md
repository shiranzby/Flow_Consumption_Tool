[简体中文](README.md) | [English](README.en.md)

# Flow Consumption Tool

Scheduled, rate‑limited, multi-threaded downstream traffic generator to keep a controlled baseline of download traffic for safer & smoother NAS sync, PT (BitTorrent) usage, and to maintain ISP / gateway behaviors.

> Use only in lawful, compliant scenarios. Educational & personal optimization only. Not for billing circumvention, abusive consumption, or impacting others.

## Feature Summary
- Multi-thread concurrency: primary traffic threads (THREADS) + dedicated large-file threads (EXTRA_BACKUP_THREAD)
- Daily time windows: 3 segments; 3rd may roll past midnight
- Tiered URL strategy: primary → secondary → rotating large-file list
- Retry with backoff: RETRY_COUNT / RETRY_DELAY
- Per-download rate limiting: `curl --limit-rate` (MB/s)
- Mixed workload: fallback to large files; extra thread ensures continuous large file flow
- Separate counters & 1GB boundary logging with average Mbps
- High precision timing via `date +%s.%N`
- systemd integration: install/uninstall, auto-restart, enable on boot
- Interactive menu: speed test, status, live logs
- Thread-safe accounting via `flock`
- Resilient to time parsing failures / curl errors / BusyBox reduced precision

## Architecture (Single Script)
1. Config (env overrides via `/etc/default/continuous_download`)
2. Menu (install, uninstall, speed test, status, logs)
3. Time Windows (compute next/rollover)
4. Download wrapper (curl + size + duration + exit code)
5. Accounting (main vs large-file totals; 1GB step output)
6. Thread orchestration (priority chain + dedicated large-file loop)
7. Service integration (systemd unit, env file, lock/state files)
8. Signal handling (graceful STOP)

Process Flow:
1. Threads wait until within a valid window
2. Primary threads: primary → secondary → large-file fallback
3. Large-file thread cycles `BACKUP_URLS`
4. Success updates counters; 1GB boundary triggers log
5. Window end waits next; SIGINT/SIGTERM triggers exit
6. systemd restarts unexpected termination

## Platforms / Dependencies
Recommended: Ubuntu / Debian / any Linux with systemd + GNU coreutils.

Required: bash, curl, flock (util-linux), systemd, GNU date.

## Quick Start
```bash
git clone git@github.com:shiranzby/Flow_Consumption_Tool.git
cd Flow_Consumption_Tool
chmod +x continuous_download.sh
./continuous_download.sh
```

## Disclaimer
Provided "AS IS" without any warranty. Use at your own risk.

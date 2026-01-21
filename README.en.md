# Flow Consumption Tool (v2.1)

[简体中文](README.md) | English

A continuous, time-windowed, rate-limited, multi-threaded download traffic consumption script.

**Primary Uses:**
*   Maintain downstream bandwidth usage to stabilize QoS or rate adaptation algorithms.
*   Keep the connection active ("background heartbeat") to maintain NAT mappings or prevent ISP idle disconnects.
*   Balance request frequency and traffic volume using a mix of small and large files.

> **Disclaimer**: This project is provided "as is" without warranty of any kind. Use at your own risk. Please ensure your usage complies with your ISP's terms of service and local laws. Not intended for malicious use.

---

## Feature Overview

*   **Multi-threaded downloads**: main threads (THREADS) + dedicated large-file thread (EXTRA_BACKUP_THREAD).
*   **Time windows**: three daily windows, can cross midnight.
*   **Tiered URL strategy**: main URL -> secondary URL -> rotating backup large files.
*   **Retry logic**: RETRY_COUNT / RETRY_DELAY based retries.
*   **Total bandwidth limit**: LIMIT_MBPS caps total bandwidth and is split across active threads.
*   **Logs & stats**: runtime log + hourly/daily traffic stats logs (with simple rotation).
*   **Smart memory guard**: reduce threads on high memory usage, restore on recovery.
*   **Real-time dashboard**: total speed, thread state, memory and IP info.
*   **Dual speed tests**: passive RX monitor + active mirror download test.
*   **Service mode**: Systemd and OpenWrt Procd install/uninstall/autostart.

## Platform / Dependencies

Recommended: Ubuntu / Debian / other systemd + GNU coreutils distros; OpenWrt (Procd).

Required: bash, curl, flock(util-linux), systemd or procd, GNU date, awk.

## Quick Start

```bash
chmod +x Flow_Consumption_Tool_v2.1.sh
./Flow_Consumption_Tool_v2.1.sh
```

## Menu Options
1. **Install service**: Auto-install to Systemd or OpenWrt Procd.
2. **Uninstall service**: Stop service and remove files.
3. **Refresh config**: Update threads / speed limit and restart.
4. **Edit time windows**: Update three windows and restart.
5. **Monitor real-time RX**: Passive interface monitoring.
6. **Active speed test**: Mirror-based active download test.
7. **Service status**: Check running status.
8. **View logs**: Follow service logs.
9. **Real-time dashboard**: View total speed and thread status.

# Flow Consumption Tool (v1.1)

[简体中文](README.md) | English

A continuous, time-windowed, rate-limited, multi-threaded download traffic consumption script.

**Primary Uses:**
*   Maintain downstream bandwidth usage to stabilize QoS or rate adaptation algorithms.
*   Keep the connection active ("background heartbeat") to maintain NAT mappings or prevent ISP idle disconnects.
*   Balance request frequency and traffic volume using a mix of small and large files.

## v1.1 New Features

1.  **Traffic Logging & Statistics**
    *   **Hourly Log (`traffic_hourly.log`)**: Records bytes downloaded and avg speed every hour. Keeps ~7 days history.
        *   Format: `hh/mm/ss-hh/mm/ss Traffic: XX GB, Avg Speed: XX MB/s`.
    *   **Daily Log (`traffic_daily.log`)**: Daily summary of total traffic and average speed. Keeps 30 days history.
        *   Format: `yyyy/mm/dd: Total Traffic XX GB, Avg Speed XX MB/s`.

2.  **Total Speed Limit (Shared Bandwidth)**
    *   The `LIMIT_MBPS` setting now caps the **TOTAL** bandwidth usage across all threads.
    *   Bandwidth is dynamically divided among active threads (e.g., 20MB/s limit / 4 threads = 5MB/s per thread).

3.  **Memory Protection**
    *   Automatically reduces thread count when system memory usage exceeds 90% and restores it when usage drops below 80%.

## Quick Start

```bash
chmod +x Flow_Consumption_Tool_v1.1.sh
./Flow_Consumption_Tool_v1.1.sh
```

Use the interactive menu to install as a systemd service for background execution.

## Configuration

You can modify the variables at the top of the script:
*   `THREADS`: Number of main threads.
*   `LIMIT_MBPS`: Total bandwidth limit in MB/s.
*   `START_TIME`/`END_TIME`: Time windows for operation.
*   `LOGFILE`: Path for system logs (default `/var/log/continuous_download.log`).

## Disclaimer

This project is provided "as is" without warranty of any kind. Use at your own risk. Please ensure your usage complies with your ISP's terms of service and local laws. Not intended for malicious use.

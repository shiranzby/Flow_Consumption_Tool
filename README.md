# Flow Consumption Tool / 流量消耗工具 (v1.1)

简体中文 | [English](#english-version)

连续、按时间窗口、可限速的多线程下行流量消耗脚本，主要用途：

*   在受运营商 / 旁路网关 / 家宽 QoS / 速率自适应影响的场景中，保持一定的下行占用，稳定带宽曲线；
*   维持家庭宽带长期有下行活动，降低上行大流量（如 NAS 远程同步、PT 下载）时被判定为异常的概率；
*   在需要维持运营商 NAT 映射或旁路网关策略（如智能限速、节能休眠等）激活状态时，提供“背景心跳”型数据流；
*   通过主/备用小文件 + 大文件组合下载，平衡频繁连接与持续大流量的需求。

> **免责声明**：本项目按“自用现状”提供，不对可用性或特定用途适用性做任何保证。请务必在合法、合规、且不违反运营商/平台服务条款的前提下使用。本工具仅供学习与自用网络优化，不建议用于规避计费、恶意消耗或影响他人服务。

---

## v1.1 版本更新特性 (New Features)

本版本 (v1.1) 在原版基础上进行了重要功能增强：

1.  **详细的流量日志监控 (Traffic Logging & Stats)**
    *   脚本同级目录下自动生成日志文件，方便每日核对。
    *   **小时级日志 (`traffic_hourly.log`)**：记录每小时的流量使用情况。
        *   格式：`hh/mm/ss-hh/mm/ss 消耗流量共 XX GB 平均每秒 XX MB`。
        *   未启动检测：若某时段流量极低，标记为“没启动”。
        *   自动维护：保留最近约 7 天的数据。
    *   **天级汇总日志 (`traffic_daily.log`)**：记录每天的总消耗。
        *   格式：`yyyy/mm/dd：消耗流量共 XX GB 平均每秒速度 XX MB`。
        *   自动维护：保留最近 30 天的数据。

2.  **总量限速模式 (Total Bandwidth Limit)**
    *   **变更**：将原先的“单线程限速”改为“**总限速均分**”。
    *   **逻辑**：设定 `LIMIT_MBPS` 为总带宽限制，脚本会自动根据当前活跃的线程数计算每个线程的限速值，并精确到小数点后两位。
    *   **示例**：设置限速 20MB/s，若当前有 4 个线程工作，则每个线程自动限速 5MB/s。

3.  **内存智能保护 (Smart Memory Monitor)**
    *   内置监控模块，当系统内存占用超过 90% 时自动减少并发下载线程数，防止低配机器卡死；内存恢复正常 (<80%) 后自动恢复并发数。

---

## 功能特性概览

*   **多线程并发**：主刷流量线程 (THREADS) + 额外大文件专用线程 (EXTRA_BACKUP_THREAD)。
*   **时间窗口控制**：支持三个每日循环窗口，可跨天运行 (如 13:00~次日01:00)。
*   **分级 URL 策略**：主 URL 优先 -> 备用主 URL -> 备用大文件轮询 (减少单一特征流)。
*   **失败重试机制**：按 RETRY_COUNT / RETRY_DELAY 自动重试。
*   **统计提示**：主与大文件累计分离，跨越 1GB 打印含平均速度提示。
*   **systemd 服务化**：安装/卸载、自动重启、开机自启。
*   **交互菜单**：测速 / 状态 / 日志跟踪。
*   **线程安全**：`flock` 防并发写。

## 适用平台 / 依赖

推荐：Ubuntu / Debian / 其他 systemd + GNU coreutils Linux 发行版。

必须：bash, curl, flock(util-linux), systemd, GNU date, awk。

## 快速开始

```bash
# 赋予执行权限
chmod +x Flow_Consumption_Tool_v1.1.sh

# 直接运行进入菜单（前台）
./Flow_Consumption_Tool_v1.1.sh
```

### 菜单选项
1.  **安装服务**：将脚本部署到系统路径并注册 systemd 服务，支持开机自启。
2.  **卸载服务**：停止服务并清理文件。
3.  **临时测速**：测试当前出口带宽。
4.  **服务状态**：查看 systemctl status。
5.  **查看日志**：实时追踪 journalctl -f 日志。

---

<a name="english-version"></a>
# Flow Consumption Tool (v1.1)

[简体中文](#flow-consumption-tool-流量消耗工具-v11) | English

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

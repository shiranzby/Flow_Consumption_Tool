#!/usr/bin/env bash
# continuous_download.sh

# ========== 整体架构概述 ==========
# 本脚本是一个流量消耗工具，用于在指定时间窗口内连续下载文件以消耗网络流量。
# 脚本功能实现：多线程下载、时间窗口、限速、主/备用优先、大文件线程、1GB 提示等
# 模块划分：
# - 配置模块：定义所有可配置参数，如线程数、URL、时间窗口等。
# - 菜单模块：提供交互式菜单，用于安装/卸载服务、测速、查看状态和日志。
# - 时间窗口模块：计算当前时间是否在允许下载的时间窗口内。
# - 下载模块：执行实际的下载任务，包括重试、限速和流量统计。
# - 线程管理模块：启动和管理多个下载线程，包括主线程和大文件专用线程。
# - 保活机制：通过 systemd 服务实现自动重启和后台运行。
# - 状态持久化：使用临时文件记录累计下载字节数。
# - 日志与监控：输出下载进度、速度和错误信息。

set -euo pipefail

# ---------- 交互式菜单与安装/卸载/测速/状态/日志 功能 ----------
SERVICE_NAME="continuous_download"
DEST_BIN="/usr/local/bin/${SERVICE_NAME}.sh"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_PATH="/etc/default/${SERVICE_NAME}"

# === 配置区（移动到文件顶部，便于快速修改） ===
# 并发与线程配置
# THREADS: 主刷流量线程数（同时刷主URL/备用主/备用大文件）
# EXTRA_BACKUP_THREAD: 额外的专用大文件线程数（一般为1）
THREADS=${THREADS:-4}
EXTRA_BACKUP_THREAD=${EXTRA_BACKUP_THREAD:-1}

# 刷流量时间窗口（每天循环）
# 格式 HH:MM，第三个窗口 END_TIME_3 可为次日时间（如 '01:00'）
START_TIME_1="02:00"
END_TIME_1="05:30"
START_TIME_2="05:31"
END_TIME_2="9:00"
START_TIME_3="13:00"
END_TIME_3="19:00"

# URL 配置：主 URL（优先），备用主 URL（次优先），备用大文件列表（最后）
MAIN_URL="${MAIN_URL:-https://img.mcloud.139.com/material_prod/material_media/20221128/1669626861087.png}"
SECONDARY_URL="${SECONDARY_URL:-https://img.cmvideo.cn/publish/noms/2023/12/06/1O4SHFIFR36BD.gif}"
# updated: 使用国内大厂镜像源的 Ubuntu ISO 替代失效链接
BACKUP_URLS=(
  "https://mirrors.cloud.tencent.com/centos/7/updates/x86_64/Packages/thunderbird-115.12.1-1.el7.centos.x86_64.rpm"
  "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04.3/ubuntu-24.04.3-desktop-amd64.iso"
  "https://mirrors.huaweicloud.com/ubuntu-releases/24.04.3/ubuntu-24.04.3-desktop-amd64.iso"
)

# 限速（MB/s）
LIMIT_MBPS=${LIMIT_MBPS:-15}

# 重试与间隔（秒）
RETRY_COUNT=${RETRY_COUNT:-2}           # 单次下载失败重试次数
RETRY_DELAY=${RETRY_DELAY:-5}           # 失败后等待秒数再重试
SLEEP_BETWEEN_DOWNLOADS=${SLEEP_BETWEEN_DOWNLOADS:-3}  # 每次下载后的短暂停顿

# 下载细节
CHUNK_SIZE=${CHUNK_SIZE:-65536}         # 每次读取字节（curl 已处理流式下载，此项保留作兼容）
LOG_INTERVAL_BYTES=${LOG_INTERVAL_BYTES:-1073741824}  # 达到多少字节输出一次（默认 1GB）

# 日志文件（绝对路径更可靠，systemd 下建议写入 /var/log）
LOGFILE=${LOGFILE:-/var/log/continuous_download.log}

# 临时文件路径（用于状态持久化和锁）
LOCKFILE=${LOCKFILE:-/tmp/continuous_download.lock}
MAINTOTAL_FILE=${MAINTOTAL_FILE:-/tmp/continuous_main_total.bytes}
BACKUPTOTAL_FILE=${BACKUPTOTAL_FILE:-/tmp/continuous_backup_total.bytes}
# 新增：用于存储当前动态允许的主线程数
THREADS_FILE=${THREADS_FILE:-/tmp/continuous_active_threads}

# === 配置区结束 ===

# ========== 菜单模块 ==========
# 提供交互式菜单，用于用户选择操作，如安装服务、卸载、测速等。
# 依赖：无外部依赖，仅使用内置命令。

usage_menu() {
  cat <<EOF
请选择操作（输入数字并回车）：
 1) 安装服务（复制脚本到 ${DEST_BIN}，创建 systemd unit，设置开机自启）
 2) 卸载服务（停止并移除 unit 与安装文件）
 3) 临时测速（测出口带宽，单位 MB/s 输入，默认 5 秒）
 4) 服务状态
 5) 查看日志（实时追踪）
 0) 退出
EOF
}

# 检查当前用户是否为 root，如果不是则检查是否有 sudo 可用。
# 输入：无
# 输出：如果需要 sudo，返回 0；否则返回 1 并输出错误信息。
ensure_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "本操作需要 sudo 权限，将以 sudo 执行..."
    if ! command -v sudo >/dev/null 2>&1; then
      echo "错误：系统没有 sudo，请切换到 root 用户再运行此项。" >&2
      return 1
    fi
  fi
  return 0
}

# 以 root 身份运行命令：root 直接执行，非 root 尝试 sudo，否则返回 2
# 输入：命令及其参数
# 输出：执行结果，如果失败返回错误码。
run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return $?
  fi
  echo "错误：当前非 root 且系统没有 sudo，无法执行需要提权的操作： $*" >&2
  return 2
}

# 交互式安装服务：复制脚本、创建环境文件、写入 systemd unit 并启动服务。
install_service_interactive() {
  echo "安装服务：将脚本复制到 ${DEST_BIN} 并设置 systemd unit"
  read -p "请输入限速 (MB/s, 默认 ${LIMIT_MBPS:-15}): " speed_input
  speed_input=${speed_input:-${LIMIT_MBPS:-15}}
  # 保证为数字（可能是浮点）
  if ! echo "$speed_input" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    echo "无效输入，使用默认 ${LIMIT_MBPS:-15}"
    speed_input=${LIMIT_MBPS:-15}
  fi

  # 复制脚本（确保目标目录存在）
  dest_dir=$(dirname "$DEST_BIN")
  if [ ! -d "$dest_dir" ]; then
    if ! run_as_root mkdir -p "$dest_dir" 2>/dev/null; then
      echo "错误：无法创建安装目录 $dest_dir（没有权限或目标不可写）。请手动创建或以 root 运行安装。" >&2
      return 2
    fi
  fi
  if ensure_sudo; then
    run_as_root cp -f "$(readlink -f "$0")" "$DEST_BIN"
    run_as_root chmod +x "$DEST_BIN"
    echo "已复制脚本到 $DEST_BIN"

    # 写 environment 文件（覆盖或创建）
    run_as_root tee "$ENV_PATH" > /dev/null <<EOF
# /etc/default/${SERVICE_NAME}
# 由安装脚本生成，可以用来覆盖脚本内变量
LIMIT_MBPS=${speed_input}
# 可选：THREADS=4
EOF
    echo "已写入环境文件 $ENV_PATH (LIMIT_MBPS=${speed_input})"

    # 写入 systemd unit
  run_as_root tee "$UNIT_PATH" > /dev/null <<'UNIT_EOF'
[Unit]
Description=流量消耗工具
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/continuous_download.sh
Restart=always
RestartSec=5
KillMode=control-group
EnvironmentFile=-/etc/default/continuous_download

[Install]
WantedBy=multi-user.target
UNIT_EOF

  run_as_root systemctl daemon-reload
  run_as_root systemctl enable --now "${SERVICE_NAME}.service"
  echo "服务已安装并尝试启动。"
  run_as_root systemctl status --no-pager "${SERVICE_NAME}.service" || true
  else
    echo "未安装：缺少 sudo 或 root 权限。"
  fi
}

# 交互式卸载服务：停止服务、移除 unit 和文件。
uninstall_service_interactive() {
  if ! ensure_sudo; then
    return 1
  fi
  read -p "确认删除 ${SERVICE_NAME} 服务及文件？输入 yes 确认：" confirm
  if [ "$confirm" != "yes" ]; then
    echo "取消卸载。"
    return 0
  fi
  run_as_root systemctl disable --now "${SERVICE_NAME}.service" || true
  run_as_root rm -f "$UNIT_PATH" "$DEST_BIN" "$ENV_PATH"
  run_as_root systemctl daemon-reload || true
  echo "已卸载服务并移除文件。"
}

# 获取默认出口网口
# 输入：无
# 输出：默认网口名称，如 eth0。
get_default_iface() {
  if command -v ip >/dev/null 2>&1; then
    ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
  else
    route -n 2>/dev/null | awk '/^0.0.0.0/ {print $8; exit}'
  fi
}

# 交互式测速：测量指定网口的出口带宽。
test_iface_interactive() {
  dur=${1:-5}
  echo "默认测速持续时间: ${dur}s"
  iface=$(get_default_iface)
  if [ -z "$iface" ]; then
    echo "无法探测默认出口网口。"
    return 1
  fi
  tx="/sys/class/net/${iface}/statistics/tx_bytes"
  if [ ! -r "$tx" ]; then
    echo "无法读取 $tx，请检查权限或网口名 (iface=$iface)"
    return 1
  fi
  echo "测量出口网口: $iface, 持续 ${dur}s..."
  prev=$(cat "$tx")
  prev_ts=$(date +%s.%N)
  sleep "$dur"
  now=$(cat "$tx")
  now_ts=$(date +%s.%N)
  delta=$((now - prev))
  elapsed=$(awk "BEGIN {printf \"%.6f\", $now_ts - $prev_ts}")
  mbps=$(awk "BEGIN {if ($elapsed>0) printf \"%.2f\", ($delta*8)/($elapsed*1024*1024); else print \"0.00\"}")
  echo "$(date '+%F %T') iface=$iface out=${delta}B elapsed=${elapsed}s ${mbps}Mbps"
}

# 交互式查看服务状态。
status_service_interactive() {
  if ensure_sudo; then
    sudo systemctl status --no-pager "${SERVICE_NAME}.service" || true
  else
    echo "请使用 root 或 sudo 查看服务状态。"
  fi
}

# 交互式查看日志：使用 journalctl 实时追踪服务日志。
view_logs_interactive() {
  if ensure_sudo; then
    echo "按 Ctrl-C 退出日志追踪"
    sudo journalctl -u "${SERVICE_NAME}.service" -f
  else
    echo "请使用 root 或 sudo 查看日志。"
  fi
}

# ========== 菜单主循环 ==========
# 仅在无参数且 stdin 是 TTY（交互式终端）时显示菜单，避免 systemd 启动时进入交互流程
if [ "$#" -eq 0 ] && [ -t 0 ]; then
  while true; do
    usage_menu
    read -p "选择: " choice
    case "$choice" in
      1) install_service_interactive; exit 0;;
      2) uninstall_service_interactive; exit 0;;
      3) read -p "测速持续秒数(默认5): " t; t=${t:-5}; test_iface_interactive "$t"; continue;;
      4) status_service_interactive; continue;;
      5) view_logs_interactive; continue;;
      0) echo "退出"; exit 0;;
      *) echo "无效选项";;
    esac
  done
fi

# ========== 初始化模块 ==========
# 设置信号处理，用于优雅退出。

# 初始化
mkdir -p "$(dirname "$MAINTOTAL_FILE")"
: > "$MAINTOTAL_FILE"
: > "$BACKUPTOTAL_FILE"
echo "$THREADS" > "$THREADS_FILE" # 初始化允许的线程数为最大值

STOP=0
trap 'STOP=1' SIGINT SIGTERM

# ========== 时间窗口模块 ==========
# 计算下载时间窗口，确保只在指定时间段内运行下载任务。

# 根据字符串时间返回当天/次日 epoch 秒（GNU date）
epoch_for() {
  # $1 like "2025-08-23 02:00" or "02:00"
  date -d "$1" +%s 2>/dev/null
}

# 计算下一个窗口开始/结束（返回两个 epoch 值）
get_next_window() {
  local now_epoch today s1 e1 s2 e2 s3 e3
  now_epoch=$(date +%s)
  today=$(date +%F)

  s1=$(epoch_for "$today $START_TIME_1")
  e1=$(epoch_for "$today $END_TIME_1")
  s2=$(epoch_for "$today $START_TIME_2")
  e2=$(epoch_for "$today $END_TIME_2")
  s3=$(epoch_for "$today $START_TIME_3")
  e3=$(epoch_for "$today $END_TIME_3")

  # 设默认值以免空字符串参与算术
  s1=${s1:-0}; e1=${e1:-0}; s2=${s2:-0}; e2=${e2:-0}; s3=${s3:-0}; e3=${e3:-0}

  # 若第三个窗口的结束时间小于等于开始时间，说明跨天，需要加 86400
  if [ "$e3" -le "$s3" ]; then
    e3=$((e3 + 86400))
  fi

  if [ "$now_epoch" -lt "$e1" ]; then
    echo "$s1 $e1"
  elif [ "$now_epoch" -lt "$s2" ]; then
    echo "$s2 $e2"
  elif [ "$now_epoch" -lt "$e2" ]; then
    echo "$s2 $e2"
  elif [ "$now_epoch" -lt "$s3" ]; then
    echo "$s3 $e3"
  elif [ "$now_epoch" -lt "$e3" ]; then
    echo "$s3 $e3"
  else
    # 返回次日第一个窗口
    echo $((s1 + 86400)) $((e1 + 86400))
  fi
}

# 获取高精度时间戳（支持 GNU date 的 %N，BusyBox 不支持时退回到秒精度）
get_time() {
  # 返回秒.纳秒 的浮点字符串
  t=$(date +%s.%N 2>/dev/null || true)
  if [[ "$t" =~ ^[0-9]+\.[0-9]+$ ]]; then
    printf "%s" "$t"
    return 0
  fi
  s=$(date +%s 2>/dev/null || echo 0)
  printf "%s.000000000" "$s"
}

# ========== 下载模块 ==========
# 执行下载任务，包括限速、重试和流量统计。

# 使用 curl 下载到 /dev/null，返回 size bytes 和 duration(seconds)
# 输出：size duration
download_one() {
  local url="$1"
  local start_ts end_ts size_raw size duration rc
  
  # --- 动态限速逻辑 (改成总限速 LIMIT_MBPS 均分) ---
  local cur_threads
  cur_threads=$(cat "$THREADS_FILE" 2>/dev/null || echo "$THREADS")
  if ! [[ "$cur_threads" =~ ^[0-9]+$ ]]; then cur_threads=$THREADS; fi
  
  # 总活跃线程 = 主线程数 + 额外大文件线程
  local total_active=$((cur_threads + EXTRA_BACKUP_THREAD))
  if [ "$total_active" -lt 1 ]; then total_active=1; fi
  
  # 计算单线程限速 (MB/s)，保留2位小数
  local per_thread_limit_mb
  per_thread_limit_mb=$(awk "BEGIN {printf \"%.2f\", $LIMIT_MBPS / $total_active}")
  
  # 转为字节传递给 curl 以保证兼容性 (同时遵循了基于 2位小数 MB 的计算结果)
  local per_thread_limit_bytes
  per_thread_limit_bytes=$(awk "BEGIN {printf \"%.0f\", $per_thread_limit_mb * 1024 * 1024}")
  # ------------------------------------------------

  start_ts=$(get_time)
  # 先保存 curl 的原始输出，以便正确获取退出码
  # 使用计算出的 per_thread_limit_bytes
  size_raw=$(curl -s --max-time 120 --limit-rate "${per_thread_limit_bytes}" -w "%{size_download}" -o /dev/null "$url" 2>/dev/null)
  rc=$?
  end_ts=$(get_time)
  # 计算持续时间（浮点数秒），如果计算失败则回退为 0
  duration=$(awk "BEGIN { if (($end_ts - $start_ts) > 0) printf \"%.6f\", ($end_ts - $start_ts); else print 0 }")
  # 只保留数字（防止环境或 curl 在输出中混入其它字符）
  size=$(printf "%s" "$size_raw" | tr -cd '0-9')
  if [ -z "$size" ]; then
    size="-1"
  fi
  if [ "$rc" -ne 0 ] || [ "$size" = "-1" ]; then
    echo "-1 $duration"
    return 1
  fi
  echo "$size $duration"
  return 0
}

# 原子更新主累计并在跨越每 GB 时打印（显示触发链接与该次下载平均速度）
update_main_total() {
  local add_bytes=$1
  local url="$2"
  local duration="$3"
  # 使用 flock + 文件保护
  exec 9>"$LOCKFILE"
  flock -x 9
  prev=$(cat "$MAINTOTAL_FILE" 2>/dev/null || echo 0)
  new=$((prev + add_bytes))
  echo "$new" > "$MAINTOTAL_FILE"
  prev_div=$((prev / LOG_INTERVAL_BYTES))
  new_div=$((new / LOG_INTERVAL_BYTES))
  flock -u 9
  exec 9>&-
  if [ "$new_div" -gt "$prev_div" ]; then
    # 计算该次下载的平均速度 Mbps
    if awk "BEGIN {exit ($duration <= 0)}"; then
      avg_speed=$(awk "BEGIN {printf \"%.2f\", ($add_bytes*8)/($duration*1024*1024)}")
    else
      avg_speed="0.00"
    fi
    printf "[主URL累计] 已下载 %.2f GB, 当前链接: %s, 本次平均速度: %s Mbps\n" "$(awk "BEGIN {printf \"%.2f\", $new/1024/1024/1024}")" "$url" "$avg_speed"
  fi
}

# 原子更新大文件累计并在跨越每 GB 时打印（显示当前文件平均速度）
update_backup_total() {
  local add_bytes=$1
  local url="$2"
  local duration="$3"
  exec 9>"$LOCKFILE"
  flock -x 9
  prev=$(cat "$BACKUPTOTAL_FILE" 2>/dev/null || echo 0)
  new=$((prev + add_bytes))
  echo "$new" > "$BACKUPTOTAL_FILE"
  prev_div=$((prev / LOG_INTERVAL_BYTES))
  new_div=$((new / LOG_INTERVAL_BYTES))
  flock -u 9
  exec 9>&-
  if [ "$new_div" -gt "$prev_div" ]; then
    if awk "BEGIN {exit ($duration <= 0)}"; then
      avg_speed=$(awk "BEGIN {printf \"%.2f\", ($add_bytes*8)/($duration*1024*1024)}")
    else
      avg_speed="0.00"
    fi
    printf "[大文件累计] 已下载 %.2f GB, 当前链接: %s, 本次文件平均速度: %s Mbps\n" "$(awk "BEGIN {printf \"%.2f\", $new/1024/1024/1024}")" "$url" "$avg_speed"
  fi
}

# ========== 线程管理模块 ==========
# 启动和管理下载线程，包括主线程和大文件专用线程，实现并发下载和保活。

# 线程工作函数（主线程逻辑）
thread_worker() {
  local id="$1"
  local backup_index="$id"
  while [ "$STOP" -eq 0 ]; do
    # --- 新增动态内存限制检测 ---
    # 读取当前允许的最大线程数，如果本线程ID >= 允许数，则暂停不工作
    allowed_threads=$(cat "$THREADS_FILE" 2>/dev/null || echo "$THREADS")
    # 确保 allowed_threads 是数字
    if ! [[ "$allowed_threads" =~ ^[0-9]+$ ]]; then allowed_threads=$THREADS; fi
    
    if [ "$id" -ge "$allowed_threads" ]; then
      # 当前内存紧张，暂停此线程
      sleep 5
      continue
    fi
    # -------------------------

    read start_epoch end_epoch < <(get_next_window)
    # 验证返回值为整数，若非整数，使用安全回退值
    if ! [[ "$start_epoch" =~ ^[0-9]+$ ]]; then
      start_epoch=$(date +%s)
    fi
    if ! [[ "$end_epoch" =~ ^[0-9]+$ ]]; then
      end_epoch=$((start_epoch + 3600))
    fi
    now_epoch=$(date +%s)
    if [ "$now_epoch" -lt "$start_epoch" ]; then
      sleep $((start_epoch - now_epoch))
    fi
    # 在窗口内循环
    while [ "$(date +%s)" -lt "$end_epoch" ] && [ "$STOP" -eq 0 ]; do
      # 1) 主 URL
      attempt=0
      success=0
      while [ $attempt -le $RETRY_COUNT ] && [ "$(date +%s)" -lt "$end_epoch" ] && [ "$STOP" -eq 0 ]; do
        attempt=$((attempt+1))
        read size dur < <(download_one "$MAIN_URL" 2>/dev/null) || { size=-1; dur=0; }
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 0 ]; then
          update_main_total "$size" "$MAIN_URL" "$dur"
          success=1
          break
        else
          if [ $attempt -le $RETRY_COUNT ] && [ "$STOP" -eq 0 ]; then
            sleep "$RETRY_DELAY"
          fi
        fi
      done
      if [ $success -eq 1 ]; then
        continue
      fi

      # 2) 备用主 URL
      attempt=0
      success=0
      while [ $attempt -le $RETRY_COUNT ] && [ "$(date +%s)" -lt "$end_epoch" ] && [ "$STOP" -eq 0 ]; do
        attempt=$((attempt+1))
        read size dur < <(download_one "$SECONDARY_URL" 2>/dev/null) || { size=-1; dur=0; }
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 0 ]; then
          update_main_total "$size" "$SECONDARY_URL" "$dur"
          success=1
          break
        else
          if [ $attempt -le $RETRY_COUNT ] && [ "$STOP" -eq 0 ]; then
            sleep "$RETRY_DELAY"
          fi
        fi
      done
      if [ $success -eq 1 ]; then
        continue
      fi

      # 3) 两个主都失败 -> 备用大文件轮询（也计入主累计，按原脚本）
      url="${BACKUP_URLS[$((backup_index % ${#BACKUP_URLS[@]}))]}"
      backup_index=$((backup_index+1))      attempt=0
      file_bytes=0
      file_duration=0
      while [ $attempt -le $RETRY_COUNT ] && [ "$(date +%s)" -lt "$end_epoch" ] && [ "$STOP" -eq 0 ]; do
        attempt=$((attempt+1))
        read size dur < <(download_one "$url" 2>/dev/null) || { size=-1; dur=0; }
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 0 ]; then
          file_bytes=$((file_bytes + size))
          file_duration=$(awk "BEGIN {print $file_duration + $dur}")
          update_main_total "$size" "$url" "$dur"
          break
        else
          if [ $attempt -le $RETRY_COUNT ] && [ "$STOP" -eq 0 ]; then
            sleep "$RETRY_DELAY"
          fi
        fi
      done

      # 备用大文件下载后等待（如有剩余窗口时间）
      now_epoch=$(date +%s)
      if [ "$now_epoch" -ge "$end_epoch" ] || [ "$STOP" -ne 0 ]; then
        break
      fi
      sleep_time=$SLEEP_BETWEEN_DOWNLOADS
      rem=$((end_epoch - now_epoch))
      # 确保 rem 为非负整数（有些环境可能返回非法字符串）
      if ! [[ "$rem" =~ ^-?[0-9]+$ ]]; then
        rem=0
      fi
      if [ "$rem" -lt 0 ]; then
        rem=0
      fi
      if [ "$rem" -lt "$sleep_time" ]; then
        sleep_time="$rem"
      fi
      if [ "$sleep_time" -gt 0 ]; then
        sleep "$sleep_time"
      fi
    done
    # 窗口结束后，回到外层循环以等待下一个窗口
  done
}

# 专用大文件线程（单独累计 backup_total）
backup_thread_worker() {
  local backup_index=0
  echo "[专用大文件线程] 启动：线程索引起始=${backup_index}" 
  while [ "$STOP" -eq 0 ]; do
    read start_epoch end_epoch < <(get_next_window)
    now_epoch=$(date +%s)
    if [ "$now_epoch" -lt "$start_epoch" ]; then
      sleep $((start_epoch - now_epoch))
    fi
    while [ "$(date +%s)" -lt "$end_epoch" ] && [ "$STOP" -eq 0 ]; do
      url="${BACKUP_URLS[$((backup_index % ${#BACKUP_URLS[@]}))]}"
      backup_index=$((backup_index+1))
      attempt=0
      file_bytes=0
      file_duration=0
      while [ $attempt -le $RETRY_COUNT ] && [ "$(date +%s)" -lt "$end_epoch" ] && [ "$STOP" -eq 0 ]; do
        attempt=$((attempt+1))
        read size dur < <(download_one "$url" 2>/dev/null) || { size=-1; dur=0; }
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 0 ]; then
          file_bytes=$((file_bytes + size))
          file_duration=$(awk "BEGIN {print $file_duration + $dur}")
          update_backup_total "$size" "$url" "$dur"
          # 记录此文件（或分段）下载情况到日志：字节、耗时、平均速度
          if awk "BEGIN {exit ($dur <= 0)}"; then
            avg_speed=$(awk "BEGIN {printf \"%.2f\", ($size*8)/($dur*1024*1024)}")
          else
            avg_speed="0.00"
          fi
          printf "[专用大文件线程] 下载完成: %d bytes, 耗时: %.3f s, 平均速度: %s Mbps, 链接: %s\n" "$size" "$dur" "$avg_speed" "$url"
          break
        else
          if [ $attempt -le $RETRY_COUNT ] && [ "$STOP" -eq 0 ]; then
            sleep "$RETRY_DELAY"
          fi
        fi
      done
      now_epoch=$(date +%s)
      if [ "$now_epoch" -ge "$end_epoch" ] || [ "$STOP" -ne 0 ]; then
        break
      fi
      sleep_time=$SLEEP_BETWEEN_DOWNLOADS
      rem=$((end_epoch - now_epoch))
      if ! [[ "$rem" =~ ^-?[0-9]+$ ]]; then
        rem=0
      fi
      if [ "$rem" -lt "$sleep_time" ]; then
        sleep_time="$rem"
      fi
      if [ "$sleep_time" -gt 0 ]; then
        sleep "$sleep_time"
      fi
    done
  done
}

# ========== 流量日志监控模块 ==========
# 记录每小时和每天的流量统计到脚本所在目录的日志文件中。
monitor_stats() {
  # 确定日志路径
  local script_path="${BASH_SOURCE[0]:-$0}"
  local script_dir
  if [ -L "$script_path" ]; then
    script_dir=$(dirname "$(readlink -f "$script_path")")
  else
    script_dir=$(dirname "$script_path")
  fi
  # 简单处理：如果取不到绝对路径，依靠 cwd
  [ -z "$script_dir" ] && script_dir="."
  
  local hourly_log="${script_dir}/traffic_hourly.log"
  local daily_log="${script_dir}/traffic_daily.log"
  
  local last_check_time
  last_check_time=$(date +%s)
  
  # 初始流量
  local m b last_bytes
  m=$(cat "$MAINTOTAL_FILE" 2>/dev/null || echo 0)
  b=$(cat "$BACKUPTOTAL_FILE" 2>/dev/null || echo 0)
  last_bytes=$((m + b))
  
  local last_hour_str
  last_hour_str=$(date +%H)
  local last_day_str
  last_day_str=$(date +%d)
  local period_start_str
  period_start_str=$(date '+%H:%M:%S')
  
  local last_log_day=""
  local day_total_bytes=0

  echo "[Monitor Stats] 流量监控已启动"

  while [ "$STOP" -eq 0 ]; do
    sleep 60
    
    local now_sec now_hour_str now_day_str
    now_sec=$(date +%s)
    now_hour_str=$(date +%H) # 00-23
    now_day_str=$(date +%d)
    
    # 检测小时变化
    if [ "$now_hour_str" != "$last_hour_str" ]; then
      local period_end_str
      period_end_str=$(date -d "@$now_sec" '+%H:%M:%S')
      
      # 计算流量差
      m=$(cat "$MAINTOTAL_FILE" 2>/dev/null || echo 0)
      b=$(cat "$BACKUPTOTAL_FILE" 2>/dev/null || echo 0)
      local current_total=$((m + b))
      local delta=0
      
      if [ "$current_total" -lt "$last_bytes" ]; then
         delta=$current_total
      else
         delta=$((current_total - last_bytes))
      fi
      
      day_total_bytes=$((day_total_bytes + delta))
      
      local duration=$((now_sec - last_check_time))
      [ "$duration" -lt 1 ] && duration=1
      
      # 计算 Hourly 数据
      local speed_mb
      speed_mb=$(awk "BEGIN {printf \"%.2f\", ($delta / 1024 / 1024) / $duration}")
      
      local traffic_str
      if [ "$delta" -ge 1073741824 ]; then
         traffic_str=$(awk "BEGIN {printf \"%.2f GB\", $delta / 1024 / 1024 / 1024}")
      else
         traffic_str=$(awk "BEGIN {printf \"%.2f MB\", $delta / 1024 / 1024}")
      fi
      
      local log_line
      # 判定没启动: 流量极小
      if [ "$delta" -le 1024 ]; then
         log_line="${period_start_str}-${period_end_str} 没启动"
      else
         log_line="${period_start_str}-${period_end_str} 消耗流量共 ${traffic_str} 平均每秒 ${speed_mb} MB"
      fi
      
      # 写入 Hourly Log
      {
         local today_fmt
         today_fmt=$(date '+%Y/%m/%d')
         if [ "$last_log_day" != "$today_fmt" ]; then
            echo "$today_fmt"
            last_log_day="$today_fmt"
         fi
         echo "$log_line"
      } >> "$hourly_log"
      
      # 简易 Log Rotation (保留约 7 天 -> 300行)
      if [ -f "$hourly_log" ] && [ $(wc -l < "$hourly_log") -gt 300 ]; then
             if tail -n 300 "$hourly_log" > "${hourly_log}.tmp" 2>/dev/null; then
               mv "${hourly_log}.tmp" "$hourly_log"
             fi
      fi
      
      # 检测跨天 -> Daily Log
      if [ "$now_day_str" != "$last_day_str" ]; then
         local yesterday_fmt
         yesterday_fmt=$(date -d "yesterday" '+%Y/%m/%d')
         
         local day_gb
         day_gb=$(awk "BEGIN {printf \"%.2f\", $day_total_bytes / 1024 / 1024 / 1024}")
         local day_speed
         day_speed=$(awk "BEGIN {printf \"%.2f\", ($day_total_bytes / 1024 / 1024) / 86400}")
         
         echo "${yesterday_fmt}：消耗流量共 ${day_gb} GB 平均每秒速度 ${day_speed} MB" >> "$daily_log"
         
         day_total_bytes=0
         last_day_str=$now_day_str
         
         # Rotation (保留 30 天)
         if [ -f "$daily_log" ] && [ $(wc -l < "$daily_log") -gt 35 ]; then
             if tail -n 30 "$daily_log" > "${daily_log}.tmp" 2>/dev/null; then
               mv "${daily_log}.tmp" "$daily_log"
             fi
         fi
      fi
      
      # 更新状态
      last_bytes=$current_total
      last_check_time=$now_sec
      last_hour_str=$now_hour_str
      period_start_str=$period_end_str
    fi
  done
}

# ========== 内存监控模块 ==========
# 每5秒运行一次，根据内存占用动态调整允许的线程数
monitor_memory() {
  local last_reduce_time=0
  local current_limit=$THREADS
  
  echo "[Memory Monitor] 启动内存监控，目标控制在 80%-90% 之间"

  while [ "$STOP" -eq 0 ]; do
    # 获取内存使用百分比 (支持 free 命令的不同版本)
    # 使用 awk 计算: used / total * 100
    mem_percent=$(free | awk '/Mem:/{printf("%.0f"), $3/$2 * 100}')
    
    now_ts=$(date +%s)
    
    # 逻辑判断
    if [ "$mem_percent" -gt 95 ]; then
      # 极限超过 95%，紧急降级，每次强制减少1个，不等待冷却
      if [ "$current_limit" -gt 1 ]; then
        current_limit=$((current_limit - 1))
        echo "[Memory Monitor] 警告: 内存 ${mem_percent}% (>95%)，紧急减少线程至 ${current_limit}"
        last_reduce_time=$now_ts
      fi
      
    elif [ "$mem_percent" -gt 90 ]; then
      # 超过 90%，需要减少。每 30 秒允许减少一次
      if [ "$current_limit" -gt 1 ]; then
        if [ $((now_ts - last_reduce_time)) -ge 30 ]; then
          current_limit=$((current_limit - 1))
          last_reduce_time=$now_ts
          echo "[Memory Monitor] 内存 ${mem_percent}% (>90%)，减少主线程数至 ${current_limit}，冷却30秒..."
        fi
      fi
      
    elif [ "$mem_percent" -lt 80 ]; then
      # 低于 80%，如果没达到配置上限，逐步恢复
      if [ "$current_limit" -lt "$THREADS" ]; then
         current_limit=$((current_limit + 1))
         echo "[Memory Monitor] 内存 ${mem_percent}% (<80%)，恢复主线程数至 ${current_limit}"
      fi
    fi

    # 更新控制文件
    echo "$current_limit" > "$THREADS_FILE"
    
    # 每5秒检测一次
    sleep 5
  done
}

# ========== 启动与等待模块 ==========
# 启动所有线程并等待它们完成，实现并发下载和优雅退出。

# 启动线程
echo "开始执行... $(date '+%F %T')"
echo "脚本启动: 多线程(${THREADS})刷主/备用主流量，额外${EXTRA_BACKUP_THREAD}线程轮流刷大文件，时间窗口为 ${START_TIME_1}-${END_TIME_1}, ${START_TIME_2}-${END_TIME_2}, ${START_TIME_3}-次日${END_TIME_3}，限速 ${LIMIT_MBPS}MB/s，每天循环往复"

# 启动内存监控后台进程
monitor_memory &
pids+=($!)

# 启动主线程
pids=()
for i in $(seq 0 $((THREADS-1))); do
  thread_worker "$i" &
  pids+=($!)
done

# 启动专用大文件线程
for i in $(seq 1 $EXTRA_BACKUP_THREAD); do
  backup_thread_worker &
  pids+=($!)
done

# 启动流量日志监控
monitor_stats &
pids+=($!)

# 等待子进程
wait_for_children() {
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
    fi
  done
}

wait_for_children

# 退出时打印累计（可选）
if [ -f "$MAINTOTAL_FILE" ]; then
  mt=$(cat "$MAINTOTAL_FILE")
  printf "退出：主累计 %.2f GB\n" "$(awk "BEGIN {printf \"%.2f\", $mt/1024/1024/1024}")"
fi
if [ -f "$BACKUPTOTAL_FILE" ]; then
  bt=$(cat "$BACKUPTOTAL_FILE")
  printf "退出：大文件累计 %.2f GB\n" "$(awk "BEGIN {printf \"%.2f\", $bt/1024/1024/1024}")"
fi
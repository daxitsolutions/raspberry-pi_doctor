#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="${SCRIPT_DIR}/$(basename "$0")"

APP_NAME="heardbit"
COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

INTERVAL=30
REPORT_LAST=30
JOURNAL_MAX=120
DATA_DIR="/tmp/heardbit"

TEMP_WARN_C=75
DISK_WARN_PCT=90
MEM_WARN_KB=120000
LOAD_PER_CORE_WARN=1.50

PID_FILE=""
METRICS_FILE=""
ALERTS_FILE=""
STATE_FILE=""
HEARTBEAT_FILE=""
RUNTIME_LOG_FILE=""
JOURNAL_EVENTS_FILE=""

usage() {
  printf '%s\n' \
    "Usage:" \
    "  ./heardbit.sh start [--interval N] [--data-dir DIR]" \
    "  ./heardbit.sh --start [--interval N] [--data-dir DIR]" \
    "  ./heardbit.sh stop|--stop [--data-dir DIR]" \
    "  ./heardbit.sh status|--status [--data-dir DIR]" \
    "  ./heardbit.sh report|--report [--last N] [--data-dir DIR]" \
    "  ./heardbit.sh clean|--clean [--data-dir DIR]" \
    "  ./heardbit.sh once|--once [--data-dir DIR]" \
    "  ./heardbit.sh run|--run [--interval N] [--data-dir DIR]" \
    "" \
    "Description:" \
    "  Daemon de surveillance renforcee (heartbeat/headbit) pour Raspberry Pi." \
    "  Il enregistre les constantes systeme et les dysfonctionnements detectes," \
    "  afin de consulter un rapport si la panne se reproduit."
}

normalize_command() {
  case "$COMMAND" in
    start|--start) COMMAND="start" ;;
    stop|--stop) COMMAND="stop" ;;
    status|--status) COMMAND="status" ;;
    report|--report) COMMAND="report" ;;
    clean|--clean) COMMAND="clean" ;;
    once|--once) COMMAND="once" ;;
    run|--run) COMMAND="run" ;;
    help|--help|-h) COMMAND="help" ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval)
        if [[ $# -lt 2 ]]; then
          echo "Valeur manquante pour --interval"
          exit 1
        fi
        INTERVAL="$2"
        shift 2
        ;;
      --data-dir)
        if [[ $# -lt 2 ]]; then
          echo "Valeur manquante pour --data-dir"
          exit 1
        fi
        DATA_DIR="$2"
        shift 2
        ;;
      --last)
        if [[ $# -lt 2 ]]; then
          echo "Valeur manquante pour --last"
          exit 1
        fi
        REPORT_LAST="$2"
        shift 2
        ;;
      --journal-max)
        if [[ $# -lt 2 ]]; then
          echo "Valeur manquante pour --journal-max"
          exit 1
        fi
        JOURNAL_MAX="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Option inconnue: $1"
        usage
        exit 1
        ;;
    esac
  done
}

require_int() {
  local value="$1"
  local name="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$name doit etre un entier positif."
    exit 1
  fi
}

init_paths() {
  PID_FILE="${DATA_DIR}/${APP_NAME}.pid"
  METRICS_FILE="${DATA_DIR}/metrics.csv"
  ALERTS_FILE="${DATA_DIR}/alerts.log"
  STATE_FILE="${DATA_DIR}/state.env"
  HEARTBEAT_FILE="${DATA_DIR}/heartbeat.state"
  RUNTIME_LOG_FILE="${DATA_DIR}/${APP_NAME}.runtime.log"
  JOURNAL_EVENTS_FILE="${DATA_DIR}/journal_events.log"
}

ensure_data_dir() {
  mkdir -p "$DATA_DIR"
  touch "$RUNTIME_LOG_FILE"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

now_epoch() {
  date +%s
}

sanitize_field() {
  local value="$1"
  value="${value//$'\n'/ }"
  value="${value//|/\/}"
  echo "$value"
}

is_running() {
  if [[ ! -f "$PID_FILE" ]]; then
    return 1
  fi
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

get_primary_iface() {
  local iface=""
  if command_exists ip; then
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
    if [[ -z "$iface" ]]; then
      iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
    fi
  fi
  if [[ -z "$iface" ]]; then
    if [[ -d /sys/class/net/eth0 ]]; then
      iface="eth0"
    elif [[ -d /sys/class/net/wlan0 ]]; then
      iface="wlan0"
    fi
  fi
  echo "$iface"
}

get_cpu_temp_c() {
  local raw
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    raw="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      awk -v t="$raw" 'BEGIN { printf "%.1f", t/1000 }'
      return
    fi
  fi
  echo "n/a"
}

get_mem_available_kb() {
  local value
  value="$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo "n/a"
  fi
}

get_disk_used_pct() {
  df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0"
}

get_load_triplet() {
  awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null || echo "0,0,0"
}

get_uptime_seconds() {
  awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0"
}

get_cores() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || echo "1"
}

get_vcgencmd_throttle() {
  if command_exists vcgencmd; then
    vcgencmd get_throttled 2>/dev/null | awk -F= '/throttled=/{print $2}' || true
    return
  fi
  echo ""
}

load_state() {
  LAST_JOURNAL_EPOCH=0
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  if [[ -z "${LAST_JOURNAL_EPOCH:-}" || ! "${LAST_JOURNAL_EPOCH:-}" =~ ^[0-9]+$ ]]; then
    LAST_JOURNAL_EPOCH=0
  fi
}

save_state() {
  local last_epoch="$1"
  printf 'LAST_JOURNAL_EPOCH=%s\n' "$last_epoch" > "$STATE_FILE"
}

write_metric_header_if_needed() {
  if [[ ! -f "$METRICS_FILE" ]]; then
    echo "timestamp,uptime_s,load1,load5,load15,mem_available_kb,disk_used_pct,cpu_temp_c,iface,operstate,carrier,rx_bytes,tx_bytes,throttled,journal_events,new_alerts" > "$METRICS_FILE"
  fi
}

log_alert() {
  local severity="$1"
  local category="$2"
  local message="$3"
  local evidence="$4"
  local ts
  ts="$(now_iso)"
  echo "${ts}|$(sanitize_field "$severity")|$(sanitize_field "$category")|$(sanitize_field "$message")|$(sanitize_field "$evidence")" >> "$ALERTS_FILE"
}

classify_journal_line() {
  local line="${1,,}"
  if [[ "$line" == *"under-voltage"* || "$line" == *"throttl"* || "$line" == *"thermal"* ]]; then
    echo "power"
  elif [[ "$line" == *"link is down"* || "$line" == *"deauth"* || "$line" == *"disassoc"* || "$line" == *"dhcp"* || "$line" == *"connection reset"* || "$line" == *"network unreachable"* ]]; then
    echo "network"
  elif [[ "$line" == *"oom"* || "$line" == *"out of memory"* || "$line" == *"killed process"* ]]; then
    echo "memory"
  elif [[ "$line" == *"i/o error"* || "$line" == *"ext4-fs"* || "$line" == *"read-only file system"* || "$line" == *"mmc"* ]]; then
    echo "storage"
  elif [[ "$line" == *"watchdog"* || "$line" == *"kernel panic"* || "$line" == *"soft lockup"* || "$line" == *"hard lockup"* || "$line" == *"hung task"* ]]; then
    echo "kernel"
  elif [[ "$line" == *"failed to start"* || "$line" == *"timed out"* || "$line" == *"segfault"* || "$line" == *"core dumped"* || "$line" == *"failed with result"* ]]; then
    echo "service"
  elif [[ "$line" == *"time has been changed"* || "$line" == *"clock jump"* || "$line" == *"timesyncd"* || "$line" == *"chronyd"* || "$line" == *"ntp"* ]]; then
    echo "time"
  elif [[ "$line" == *"usb"* && ( "$line" == *"reset"* || "$line" == *"disconnect"* ) ]]; then
    echo "usb"
  else
    echo "journal"
  fi
}

collect_journal_events() {
  local since_epoch="$1"
  local logs
  if command_exists journalctl; then
    logs="$(journalctl --since "@$since_epoch" -p warning..alert -n "$JOURNAL_MAX" --no-pager -o short-iso 2>/dev/null || true)"
    echo "$logs"
    return
  fi

  if [[ -r /var/log/syslog ]]; then
    tail -n 1500 /var/log/syslog 2>/dev/null | grep -Ei "(warn|error|critical|fatal|panic|timeout|oom|throttl|under-voltage)" | tail -n "$JOURNAL_MAX" || true
    return
  fi

  echo ""
}

write_heartbeat() {
  local status="$1"
  local anomalies="$2"
  local ts
  ts="$(now_iso)"
  printf 'timestamp=%s\nstatus=%s\nnew_alerts=%s\n' "$ts" "$status" "$anomalies" > "${HEARTBEAT_FILE}.tmp"
  mv "${HEARTBEAT_FILE}.tmp" "$HEARTBEAT_FILE"
}

sample_once() {
  local ts epoch iface operstate carrier rx tx temp_c mem_avail disk_used
  local load1 load5 load15 loads uptime_s cores load_limit throttle
  local journal_since journal_lines journal_count new_alerts cycle_status
  local journal_line category
  local throttle_norm

  ts="$(now_iso)"
  epoch="$(now_epoch)"
  iface="$(get_primary_iface)"
  temp_c="$(get_cpu_temp_c)"
  mem_avail="$(get_mem_available_kb)"
  disk_used="$(get_disk_used_pct)"
  loads="$(get_load_triplet)"
  load1="${loads%%,*}"
  loads="${loads#*,}"
  load5="${loads%%,*}"
  load15="${loads##*,}"
  uptime_s="$(get_uptime_seconds)"
  cores="$(get_cores)"
  load_limit="$(awk -v c="$cores" -v f="$LOAD_PER_CORE_WARN" 'BEGIN { printf "%.2f", c*f }')"
  throttle="$(get_vcgencmd_throttle)"

  operstate="n/a"
  carrier="n/a"
  rx="n/a"
  tx="n/a"
  if [[ -n "$iface" && -d "/sys/class/net/$iface" ]]; then
    operstate="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")"
    if [[ -r "/sys/class/net/$iface/carrier" ]]; then
      carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "n/a")"
    fi
    rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo "n/a")"
    tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo "n/a")"
  fi

  load_state
  journal_since="$LAST_JOURNAL_EPOCH"
  if (( journal_since == 0 )); then
    journal_since=$(( epoch - INTERVAL - 2 ))
  fi

  journal_lines="$(collect_journal_events "$journal_since")"
  journal_count="$(printf "%s\n" "$journal_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

  new_alerts=0

  if [[ "$temp_c" != "n/a" ]] && awk -v t="$temp_c" -v w="$TEMP_WARN_C" 'BEGIN { exit !(t>w) }'; then
    log_alert "WARN" "thermal" "Temperature CPU elevee" "temp=${temp_c}C seuil=${TEMP_WARN_C}C"
    new_alerts=$((new_alerts + 1))
  fi

  if [[ "$disk_used" =~ ^[0-9]+$ ]] && (( disk_used >= DISK_WARN_PCT )); then
    log_alert "WARN" "storage" "Partition / presque pleine" "disk_used=${disk_used}% seuil=${DISK_WARN_PCT}%"
    new_alerts=$((new_alerts + 1))
  fi

  if [[ "$mem_avail" =~ ^[0-9]+$ ]] && (( mem_avail <= MEM_WARN_KB )); then
    log_alert "WARN" "memory" "Memoire disponible basse" "mem_available_kb=${mem_avail} seuil=${MEM_WARN_KB}"
    new_alerts=$((new_alerts + 1))
  fi

  if awk -v l="$load1" -v max="$load_limit" 'BEGIN { exit !(l>max) }'; then
    log_alert "WARN" "load" "Charge CPU elevee" "load1=${load1} seuil=${load_limit} (cores=${cores})"
    new_alerts=$((new_alerts + 1))
  fi

  if [[ -n "$iface" && "$operstate" != "up" ]]; then
    log_alert "WARN" "network" "Interface reseau non-up" "iface=${iface} operstate=${operstate}"
    new_alerts=$((new_alerts + 1))
  fi

  if [[ "$carrier" =~ ^[0-9]+$ ]] && (( carrier == 0 )); then
    log_alert "WARN" "network" "Perte de carrier reseau" "iface=${iface} carrier=${carrier}"
    new_alerts=$((new_alerts + 1))
  fi

  if [[ -n "$throttle" ]]; then
    throttle_norm="${throttle#0x}"
    if [[ "$throttle_norm" =~ ^[0-9a-fA-F]+$ ]] && (( 16#$throttle_norm != 0 )); then
      log_alert "WARN" "power" "Drapeaux throttling/sous-tension detectes" "vcgencmd=${throttle}"
      new_alerts=$((new_alerts + 1))
    fi
  fi

  if [[ "$journal_count" =~ ^[0-9]+$ ]] && (( journal_count > 0 )); then
    printf "%s\n" "$journal_lines" | sed '/^[[:space:]]*$/d' | tail -n "$JOURNAL_MAX" >> "$JOURNAL_EVENTS_FILE"
    while IFS= read -r journal_line; do
      if [[ -z "$(printf "%s" "$journal_line" | sed 's/[[:space:]]//g')" ]]; then
        continue
      fi
      category="$(classify_journal_line "$journal_line")"
      log_alert "WARN" "$category" "Journal warning/error detecte" "$journal_line"
      new_alerts=$((new_alerts + 1))
    done <<< "$(printf "%s\n" "$journal_lines" | sed '/^[[:space:]]*$/d' | tail -n 15)"
  fi

  cycle_status="OK"
  if (( new_alerts > 0 )); then
    cycle_status="ALERT"
  fi
  write_heartbeat "$cycle_status" "$new_alerts"

  write_metric_header_if_needed
  echo "${ts},${uptime_s},${load1},${load5},${load15},${mem_avail},${disk_used},${temp_c},${iface:-n/a},${operstate},${carrier},${rx},${tx},${throttle:-n/a},${journal_count},${new_alerts}" >> "$METRICS_FILE"

  save_state $((epoch + 1))
}

run_loop() {
  trap 'exit 0' INT TERM
  echo "[$(now_iso)] heardbit run: interval=${INTERVAL}s data_dir=${DATA_DIR}" >> "$RUNTIME_LOG_FILE"
  while true; do
    sample_once
    sleep "$INTERVAL"
  done
}

start_daemon() {
  if is_running; then
    echo "heardbit deja actif (pid=$(cat "$PID_FILE"))."
    exit 0
  fi
  nohup "$SELF_PATH" run --interval "$INTERVAL" --data-dir "$DATA_DIR" --journal-max "$JOURNAL_MAX" >> "$RUNTIME_LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  sleep 0.2
  if kill -0 "$pid" 2>/dev/null; then
    echo "heardbit demarre en arriere-plan (pid=$pid)."
    echo "Donnees: $DATA_DIR"
  else
    echo "Echec du demarrage heardbit. Voir: $RUNTIME_LOG_FILE"
    exit 1
  fi
}

stop_daemon() {
  if ! is_running; then
    echo "heardbit n'est pas actif."
    rm -f "$PID_FILE"
    exit 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true
  sleep 0.3
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  echo "heardbit arrete."
}

show_status() {
  if is_running; then
    echo "heardbit: RUNNING (pid=$(cat "$PID_FILE"))"
  else
    echo "heardbit: STOPPED"
  fi
  if [[ -f "$HEARTBEAT_FILE" ]]; then
    echo "heartbeat:"
    cat "$HEARTBEAT_FILE"
  else
    echo "heartbeat: aucun"
  fi
  echo "data_dir: $DATA_DIR"
}

show_report() {
  echo "===== heardbit report ====="
  show_status
  echo

  if [[ -f "$ALERTS_FILE" ]]; then
    local total
    total="$(wc -l < "$ALERTS_FILE" | tr -d ' ')"
    echo "Total alertes enregistrees: $total"
    echo "Repartition par categorie:"
    awk -F'|' 'NF>=3 {c[$3]++} END {for (k in c) printf "- %s: %d\n", k, c[k]}' "$ALERTS_FILE" | sort
    echo
    echo "Dernieres alertes (max ${REPORT_LAST}):"
    tail -n "$REPORT_LAST" "$ALERTS_FILE"
  else
    echo "Aucune alerte enregistree."
  fi

  echo
  if [[ -f "$METRICS_FILE" ]]; then
    echo "Dernieres mesures (max 10):"
    tail -n 10 "$METRICS_FILE"
  else
    echo "Aucune metrique enregistree."
  fi

  echo
  if [[ -f "$JOURNAL_EVENTS_FILE" ]]; then
    echo "Derniers evenements journal (max 20):"
    tail -n 20 "$JOURNAL_EVENTS_FILE"
  else
    echo "Aucun evenement journal sauvegarde."
  fi
}

clean_data() {
  local running_pid=""
  if is_running; then
    running_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    stop_daemon
  fi

  if [[ -d "$DATA_DIR" ]]; then
    rm -rf "${DATA_DIR:?}/"*
  fi
  mkdir -p "$DATA_DIR"

  if [[ -n "$running_pid" ]]; then
    echo "heardbit etait actif (pid=$running_pid) et a ete arrete."
  fi
  echo "Nettoyage termine: $DATA_DIR"
}

main() {
  normalize_command
  parse_args "$@"
  require_int "$INTERVAL" "interval"
  require_int "$REPORT_LAST" "last"
  require_int "$JOURNAL_MAX" "journal-max"
  init_paths

  case "$COMMAND" in
    start)
      ensure_data_dir
      touch "$ALERTS_FILE" "$JOURNAL_EVENTS_FILE"
      start_daemon
      ;;
    run)
      ensure_data_dir
      touch "$ALERTS_FILE" "$JOURNAL_EVENTS_FILE"
      run_loop
      ;;
    stop)
      stop_daemon
      ;;
    status)
      show_status
      ;;
    report)
      show_report
      ;;
    clean)
      clean_data
      ;;
    once)
      ensure_data_dir
      touch "$ALERTS_FILE" "$JOURNAL_EVENTS_FILE"
      sample_once
      echo "Echantillon collecte. Voir: $DATA_DIR"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      echo "Commande inconnue: $COMMAND"
      usage
      exit 1
      ;;
  esac
}

main "$@"

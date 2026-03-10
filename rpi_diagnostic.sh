#!/usr/bin/env bash
set -euo pipefail

MODE="noob"
WINDOW="2 hours ago"
MAX_LINES=200

print_help() {
  cat <<'EOF'
Usage: ./rpi_diagnostic.sh [--noob|--advanced] [--help]

Options:
  --noob       Diagnostic simple (par defaut)
  --advanced   Diagnostic detaille
  --help       Affiche cette aide
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --noob)
      MODE="noob"
      ;;
    --advanced)
      MODE="advanced"
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      echo "Option inconnue: $1"
      print_help
      exit 1
      ;;
  esac
  shift
done

SECONDS=0

collect_logs() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -p err..alert --since "$WINDOW" -n "$MAX_LINES" --no-pager -o short-iso 2>/dev/null || true
    return
  fi

  if [[ -r /var/log/syslog ]]; then
    tail -n 1000 /var/log/syslog 2>/dev/null \
      | grep -Ei "(error|fail|critical|fatal|panic)" \
      | tail -n "$MAX_LINES" || true
    return
  fi

  echo ""
}

count_pattern() {
  local pattern="$1"
  printf "%s\n" "$LOGS" | grep -Eic "$pattern" || true
}

log_level() {
  local score="$1"
  if (( score == 0 )); then
    echo "OK"
  elif (( score <= 5 )); then
    echo "ATTENTION"
  else
    echo "CRITIQUE"
  fi
}

human_temp() {
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    local raw
    raw="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")"
    if [[ -n "$raw" && "$raw" =~ ^[0-9]+$ ]]; then
      awk -v t="$raw" 'BEGIN { printf "%.1fC", t/1000 }'
      return
    fi
  fi
  echo "n/a"
}

LOGS="$(collect_logs)"
TOTAL_ERRORS="$(printf "%s\n" "$LOGS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

STORAGE_COUNT="$(count_pattern 'I/O error|EXT4-fs error|mmc[0-9]|read-only file system|blk_update_request')"
MEMORY_COUNT="$(count_pattern 'out of memory|oom-killer|Killed process .* out of memory')"
THERMAL_POWER_COUNT="$(count_pattern 'under-voltage|throttl|overheat|temperature')"
NETWORK_COUNT="$(count_pattern 'network.*down|dhcp.*fail|link is down|wlan.*disassoc|failed to resolve')"
SERVICE_COUNT="$(count_pattern 'Failed to start|timed out|dependency failed|segfault|core dumped')"
KERNEL_COUNT="$(count_pattern 'kernel panic|BUG:|Call Trace|watchdog')"

RISK_SCORE=$(( STORAGE_COUNT + MEMORY_COUNT + THERMAL_POWER_COUNT + NETWORK_COUNT + SERVICE_COUNT + KERNEL_COUNT ))
RISK_LEVEL="$(log_level "$RISK_SCORE")"
CPU_TEMP="$(human_temp)"

print_noob() {
  echo "Raspberry Pi Doctor (mode noob)"
  echo "Etat global: $RISK_LEVEL"
  echo "Erreurs recentes analysees: $TOTAL_ERRORS (fenetre: $WINDOW, max: $MAX_LINES)"
  echo "Temperature CPU: $CPU_TEMP"
  echo
  echo "Problemes detectes:"

  if (( TOTAL_ERRORS == 0 )); then
    echo "- Aucun probleme systeme recent critique."
    echo
    echo "Conseil: surveiller normalement, aucun signal fort detecte."
    return
  fi

  if (( STORAGE_COUNT > 0 )); then
    echo "- Stockage: erreurs disque/carte SD detectees."
  fi
  if (( MEMORY_COUNT > 0 )); then
    echo "- Memoire: saturation possible (OOM)."
  fi
  if (( THERMAL_POWER_COUNT > 0 )); then
    echo "- Temperature/alimentation: possible chauffe ou sous-tension."
  fi
  if (( NETWORK_COUNT > 0 )); then
    echo "- Reseau: instabilite ou coupures detectees."
  fi
  if (( SERVICE_COUNT > 0 )); then
    echo "- Services: demarrages en echec ou crashs."
  fi
  if (( KERNEL_COUNT > 0 )); then
    echo "- Noyau: messages graves detectes."
  fi

  echo
  echo "Actions conseillees:"
  echo "1. Redemarrer puis relancer le script pour voir si les erreurs reviennent."
  echo "2. Verifier alimentation (5V stable) et refroidissement."
  echo "3. Si stockage touche, sauvegarder et tester/remplacer la carte SD."
}

print_advanced() {
  echo "Raspberry Pi Doctor (mode advanced)"
  echo "Etat global: $RISK_LEVEL"
  echo "Erreurs recentes analysees: $TOTAL_ERRORS (fenetre: $WINDOW, max: $MAX_LINES)"
  echo "Temperature CPU: $CPU_TEMP"
  echo
  echo "Comptage par categorie:"
  echo "- stockage      : $STORAGE_COUNT"
  echo "- memoire       : $MEMORY_COUNT"
  echo "- thermique/pwr : $THERMAL_POWER_COUNT"
  echo "- reseau        : $NETWORK_COUNT"
  echo "- services      : $SERVICE_COUNT"
  echo "- noyau         : $KERNEL_COUNT"
  echo
  echo "Top messages (normalises):"
  if [[ -n "$(printf "%s\n" "$LOGS" | sed '/^[[:space:]]*$/d')" ]]; then
    printf "%s\n" "$LOGS" \
      | awk '{$1=$2=""; sub(/^  */,""); print}' \
      | sed '/^[[:space:]]*$/d' \
      | sort \
      | uniq -c \
      | sort -nr \
      | head -n 8
  else
    echo "Aucun message d'erreur recent."
  fi

  echo
  echo "Dernieres erreurs brutes:"
  if [[ -n "$(printf "%s\n" "$LOGS" | sed '/^[[:space:]]*$/d')" ]]; then
    printf "%s\n" "$LOGS" | tail -n 12
  else
    echo "Aucune."
  fi
}

if [[ "$MODE" == "advanced" ]]; then
  print_advanced
else
  print_noob
fi

echo
echo "Temps d'execution: ${SECONDS}s"

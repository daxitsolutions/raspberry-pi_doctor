#!/usr/bin/env bash
set -euo pipefail

MODE="noob"
WINDOW="2 hours ago"
MAX_LINES=200
DEEP_WINDOW="7 days ago"
DEEP_MAX_LINES=6000
DEEP_PREV_BOOT_MAX=300

print_help() {
  printf '%s\n' \
    "Usage: ./doctor.sh [--noob|--advanced|--deep] [--help]" \
    "" \
    "Options:" \
    "  --noob       Diagnostic simple (par defaut)" \
    "  --advanced   Diagnostic detaille" \
    "  --deep       Analyse poussee des causes d'indisponibilite" \
    "  --help       Affiche cette aide"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --noob)
      MODE="noob"
      ;;
    --advanced)
      MODE="advanced"
      ;;
    --deep)
      MODE="deep"
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

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

collect_logs_priority() {
  local since="$1"
  local max_lines="$2"
  local priority="$3"

  if command_exists journalctl; then
    journalctl -p "$priority" --since "$since" -n "$max_lines" --no-pager -o short-iso 2>/dev/null || true
    return
  fi

  if [[ -r /var/log/syslog ]]; then
    tail -n $(( max_lines * 6 )) /var/log/syslog 2>/dev/null \
      | grep -Ei "(warn|error|fail|critical|fatal|panic|segfault|timeout|oom|throttl|under-voltage)" \
      | tail -n "$max_lines" || true
    return
  fi

  echo ""
}

collect_logs_all() {
  local since="$1"
  local max_lines="$2"

  if command_exists journalctl; then
    journalctl --since "$since" -n "$max_lines" --no-pager -o short-iso 2>/dev/null || true
    return
  fi

  if [[ -r /var/log/syslog ]]; then
    tail -n "$max_lines" /var/log/syslog 2>/dev/null || true
    return
  fi

  echo ""
}

collect_prev_boot_logs() {
  if command_exists journalctl; then
    journalctl -b -1 -p warning..alert -n "$DEEP_PREV_BOOT_MAX" --no-pager -o short-iso 2>/dev/null || true
    return
  fi

  echo ""
}

count_non_empty_lines() {
  local logs="$1"
  printf "%s\n" "$logs" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

count_pattern_in_logs() {
  local logs="$1"
  local pattern="$2"
  printf "%s\n" "$logs" | grep -Eic "$pattern" || true
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

deep_level() {
  local score="$1"
  if (( score == 0 )); then
    echo "OK"
  elif (( score <= 15 )); then
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

human_uptime() {
  if [[ -r /proc/uptime ]]; then
    local sec d h m
    sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")"
    d=$(( sec / 86400 ))
    h=$(( (sec % 86400) / 3600 ))
    m=$(( (sec % 3600) / 60 ))
    printf "%dj %02dh%02d" "$d" "$h" "$m"
    return
  fi
  echo "n/a"
}

vcgencmd_raw() {
  if command_exists vcgencmd; then
    vcgencmd get_throttled 2>/dev/null | awk -F= '/throttled=/{print $2}' || true
    return
  fi
  echo ""
}

append_flag_message() {
  local bit="$1"
  local text="$2"
  local value="$3"
  if (( (value & (1 << bit)) != 0 )); then
    if [[ -n "$THROTTLE_FLAGS" ]]; then
      THROTTLE_FLAGS="${THROTTLE_FLAGS}; ${text}"
    else
      THROTTLE_FLAGS="${text}"
    fi
  fi
}

decode_throttle_flags() {
  local raw="$1"
  THROTTLE_FLAGS=""
  THROTTLE_HISTORY_FLAG=0
  THROTTLE_SUMMARY=""

  if [[ -z "$raw" ]]; then
    THROTTLE_SUMMARY="n/a"
    return
  fi

  local hex="${raw#0x}"
  if [[ -z "$hex" || ! "$hex" =~ ^[0-9a-fA-F]+$ ]]; then
    THROTTLE_SUMMARY="indisponible ($raw)"
    return
  fi

  local value=$((16#$hex))
  if (( value == 0 )); then
    THROTTLE_SUMMARY="aucun evenement"
    return
  fi

  append_flag_message 0 "sous-tension en cours" "$value"
  append_flag_message 1 "freq CPU limitee en cours" "$value"
  append_flag_message 2 "throttling en cours" "$value"
  append_flag_message 3 "limite temperature en cours" "$value"
  append_flag_message 16 "sous-tension detectee dans le passe" "$value"
  append_flag_message 17 "freq CPU limitee dans le passe" "$value"
  append_flag_message 18 "throttling detecte dans le passe" "$value"
  append_flag_message 19 "temperature limite detectee dans le passe" "$value"

  if (( (value & (1 << 16)) != 0 || (value & (1 << 18)) != 0 || (value & (1 << 19)) != 0 )); then
    THROTTLE_HISTORY_FLAG=1
  fi

  if [[ -z "$THROTTLE_FLAGS" ]]; then
    THROTTLE_SUMMARY="flags non interpretes ($raw)"
  else
    THROTTLE_SUMMARY="$THROTTLE_FLAGS"
  fi
}

collect_service_snapshot() {
  SERVICE_SNAPSHOT=""
  SERVICE_DOWN_COUNT=0
  INACTIVE_SERVICES=""

  if ! command_exists systemctl; then
    SERVICE_SNAPSHOT="systemctl indisponible"
    return
  fi

  local units=(
    ssh
    sshd
    networking
    NetworkManager
    dhcpcd
    wpa_supplicant
    systemd-networkd
    systemd-resolved
  )

  local found=0
  local unit load active
  for unit in "${units[@]}"; do
    load="$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)"
    if [[ "$load" == "not-found" || -z "$load" ]]; then
      continue
    fi
    found=1
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    SERVICE_SNAPSHOT="${SERVICE_SNAPSHOT}- ${unit}: ${active}"$'\n'
    if [[ "$active" != "active" ]]; then
      SERVICE_DOWN_COUNT=$(( SERVICE_DOWN_COUNT + 1 ))
      INACTIVE_SERVICES="${INACTIVE_SERVICES}${unit}"$'\n'
    fi
  done

  if (( found == 0 )); then
    SERVICE_SNAPSHOT="aucun service reseau/ssh standard detecte"
  fi
}

explain_alert_line() {
  local category="$1"
  local raw_line="$2"
  local line="${raw_line,,}"

  case "$category" in
    network)
      if [[ "$line" == *"link is down"* || "$line" == *"link down"* || "$line" == *"carrier lost"* ]]; then
        echo "Perte du lien reseau (physique ou driver), la machine peut devenir injoignable."
      elif [[ "$line" == *"deauth"* || "$line" == *"disassoc"* || "$line" == *"ctrl-event-disconnected"* ]]; then
        echo "Deconnexion Wi-Fi (deauth/disassoc), souvent due au signal, AP ou roaming."
      elif [[ "$line" == *"dhcp"* && ( "$line" == *"fail"* || "$line" == *"timeout"* || "$line" == *"timed out"* || "$line" == *"no lease"* ) ]]; then
        echo "Echec DHCP: perte d'IP possible, donc indisponibilite reseau."
      elif [[ "$line" == *"network unreachable"* || "$line" == *"connection reset"* ]]; then
        echo "Transport reseau instable ou route indisponible."
      elif [[ "$line" == *"eth"* && "$line" == *"reset"* ]]; then
        echo "Interface ethernet resetee (driver/NIC/cable), cause frequente de coupure courte."
      else
        echo "Evenement reseau anormal detecte dans les logs."
      fi
      ;;
    power)
      if [[ "$line" == *"under-voltage"* ]]; then
        echo "Sous-tension detectee: le RPi peut throttler ou deconnecter des peripheriques."
      elif [[ "$line" == *"throttl"* ]]; then
        echo "Throttling actif ou passe: performances degradees et instabilite possible."
      elif [[ "$line" == *"overheat"* || "$line" == *"thermal"* || "$line" == *"temperature"* ]]; then
        echo "Contrainte thermique: risque de baisse de frequence ou comportement erratique."
      else
        echo "Signal alimentation/thermique suspect."
      fi
      ;;
    kernel)
      if [[ "$line" == *"watchdog"* ]]; then
        echo "Watchdog declenche: le systeme ne repondait plus correctement."
      elif [[ "$line" == *"hung task"* || "$line" == *"blocked for more than"* ]]; then
        echo "Blocage long d'un thread/processus, possible freeze partiel."
      elif [[ "$line" == *"rcu"* && "$line" == *"stall"* ]]; then
        echo "Stall noyau (RCU): forte suspicion de saturation noyau/driver."
      elif [[ "$line" == *"kernel panic"* || "$line" == *"soft lockup"* || "$line" == *"hard lockup"* ]]; then
        echo "Evenement noyau severe pouvant provoquer reboot ou indisponibilite."
      else
        echo "Anomalie noyau detectee."
      fi
      ;;
    storage)
      if [[ "$line" == *"i/o error"* || "$line" == *"buffer i/o error"* ]]; then
        echo "Erreur d'entree/sortie: acces stockage instable (SD/disque)."
      elif [[ "$line" == *"read-only file system"* ]]; then
        echo "Systeme de fichiers passe en lecture seule apres erreur."
      elif [[ "$line" == *"mmc"* && ( "$line" == *"timeout"* || "$line" == *"error"* || "$line" == *"retry"* ) ]]; then
        echo "Timeout/erreur MMC: carte SD potentiellement en cause."
      elif [[ "$line" == *"ext4-fs"* ]]; then
        echo "Alerte EXT4: integrite/fiabilite du systeme de fichiers a verifier."
      else
        echo "Anomalie stockage detectee."
      fi
      ;;
    memory)
      if [[ "$line" == *"oom-killer"* || "$line" == *"out of memory"* || "$line" == *"killed process"* ]]; then
        echo "Memoire saturee: processus tues par le noyau, impact direct sur disponibilite."
      else
        echo "Evenement memoire anormal."
      fi
      ;;
    services)
      if [[ "$line" == *"failed to start"* ]]; then
        echo "Demarrage du service en echec."
      elif [[ "$line" == *"start request repeated too quickly"* ]]; then
        echo "Boucle de restart: systemd limite les tentatives."
      elif [[ "$line" == *"timed out"* ]]; then
        echo "Timeout de demarrage/arret, le service peut rester indisponible."
      elif [[ "$line" == *"segfault"* || "$line" == *"core dumped"* ]]; then
        echo "Crash applicatif du service."
      elif [[ "$line" == *"main process exited"* || "$line" == *"failed with result"* ]]; then
        echo "Processus principal termine anormalement."
      else
        echo "Anomalie de service detectee."
      fi
      ;;
    time)
      if [[ "$line" == *"time has been changed"* || "$line" == *"clock jump"* ]]; then
        echo "Saut d'horloge: peut casser sessions TLS, DNS cache ou jobs."
      elif [[ "$line" == *"timesyncd"* || "$line" == *"chronyd"* || "$line" == *"ntp"* ]]; then
        echo "Synchronisation horaire instable ou corrective."
      else
        echo "Anomalie de synchronisation temporelle."
      fi
      ;;
    usb)
      if [[ "$line" == *"usb"* && "$line" == *"reset"* ]]; then
        echo "Reset USB detecte: possible coupure NIC USB ou peripherique."
      elif [[ "$line" == *"device descriptor read"* ]]; then
        echo "Probleme enumeration USB, souvent alimentation/cable/peripherique."
      elif [[ "$line" == *"usb disconnect"* ]]; then
        echo "Peripherique USB deconnecte pendant fonctionnement."
      else
        echo "Evenement USB suspect."
      fi
      ;;
    *)
      echo "Evenement suspect detecte."
      ;;
  esac
}

print_investigation_from_logs() {
  local label="$1"
  local count="$2"
  local category="$3"
  local pattern="$4"
  local logs="$5"
  local max_items="${6:-8}"
  local matched

  if (( count <= 0 )); then
    return
  fi

  echo
  echo "Investigation poussee: $label"
  matched="$(printf "%s\n" "$logs" | grep -Ei "$pattern" | tail -n "$max_items" || true)"
  if [[ -z "$(printf "%s\n" "$matched" | sed '/^[[:space:]]*$/d')" ]]; then
    echo "- Aucun extrait de log disponible pour ce signal."
    return
  fi

  while IFS= read -r line; do
    if [[ -z "$(printf "%s" "$line" | sed 's/[[:space:]]//g')" ]]; then
      continue
    fi
    echo "- Ligne: $line"
    echo "  Cause probable: $(explain_alert_line "$category" "$line")"
  done <<< "$matched"
}

investigate_inactive_services() {
  local unit active substate service_logs
  if (( SERVICE_DOWN_COUNT <= 0 )); then
    return
  fi

  echo
  echo "Investigation poussee: services critiques inactifs"

  if [[ -z "$(printf "%s\n" "$INACTIVE_SERVICES" | sed '/^[[:space:]]*$/d')" ]]; then
    echo "- Alerte active mais la liste des services inactifs est indisponible."
    return
  fi

  while IFS= read -r unit; do
    if [[ -z "$unit" ]]; then
      continue
    fi

    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    substate="$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)"
    echo "- Source alerte: systemctl is-active $unit => ${active:-unknown} (SubState: ${substate:-n/a})"

    service_logs=""
    if command_exists journalctl; then
      service_logs="$(journalctl -u "$unit" --since "$DEEP_WINDOW" -p warning..alert -n 6 --no-pager -o short-iso 2>/dev/null || true)"
    elif [[ -r /var/log/syslog ]]; then
      service_logs="$(tail -n 3000 /var/log/syslog 2>/dev/null | grep -Ei "$unit|failed|timeout|segfault|restart|dependency failed|start request repeated" | tail -n 6 || true)"
    fi

    if [[ -n "$(printf "%s\n" "$service_logs" | sed '/^[[:space:]]*$/d')" ]]; then
      while IFS= read -r line; do
        if [[ -z "$(printf "%s" "$line" | sed 's/[[:space:]]//g')" ]]; then
          continue
        fi
        echo "  Ligne: $line"
        echo "  Cause probable: $(explain_alert_line "services" "$line")"
      done <<< "$service_logs"
    else
      echo "  Aucun warning/error recent sur $unit dans la fenetre $DEEP_WINDOW."
    fi
  done <<< "$INACTIVE_SERVICES"
}

LOGS="$(collect_logs_priority "$WINDOW" "$MAX_LINES" "err..alert")"
TOTAL_ERRORS="$(count_non_empty_lines "$LOGS")"

STORAGE_COUNT="$(count_pattern_in_logs "$LOGS" 'I/O error|EXT4-fs error|mmc[0-9]|read-only file system|blk_update_request')"
MEMORY_COUNT="$(count_pattern_in_logs "$LOGS" 'out of memory|oom-killer|Killed process .* out of memory')"
THERMAL_POWER_COUNT="$(count_pattern_in_logs "$LOGS" 'under-voltage|throttl|overheat|temperature')"
NETWORK_COUNT="$(count_pattern_in_logs "$LOGS" 'network.*down|dhcp.*fail|link is down|wlan.*disassoc|failed to resolve')"
SERVICE_COUNT="$(count_pattern_in_logs "$LOGS" 'Failed to start|timed out|dependency failed|segfault|core dumped')"
KERNEL_COUNT="$(count_pattern_in_logs "$LOGS" 'kernel panic|BUG:|Call Trace|watchdog')"

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
    echo "Conseil: relancer en --deep si tu suspectes des coupures reseau ou alimentation intermittentes."
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
  echo "4. En cas de coupures intermittentes, lancer ./doctor.sh --deep."
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

print_deep() {
  local deep_logs deep_prev_boot_logs deep_suspect_logs
  local deep_total deep_storage deep_memory deep_power deep_network deep_service deep_kernel deep_time deep_usb
  local prev_boot_warn_count uptime_str uptime_sec recent_reboot_flag deep_score deep_status uptime_known
  local throttle_raw investigation_done
  local p_storage p_memory p_power p_network p_service p_kernel p_time p_usb p_suspect

  p_storage='I/O error|EXT4-fs (warning|error)|Buffer I/O error|mmc[0-9].*(error|timeout|retry)|read-only file system|blk_update_request'
  p_memory='out of memory|oom-killer|invoked oom-killer|Killed process .* out of memory|memory cgroup out of memory'
  p_power='under-voltage|throttl|overheat|thermal|voltage normalised|hardware temperature'
  p_network='link is down|link down|deauth|disassoc|CTRL-EVENT-DISCONNECTED|carrier lost|dhcp.*(fail|timeout|timed out|no lease)|network unreachable|connection reset|wlan[0-9].*(disconnect|deauth)|eth[0-9].*(down|reset)'
  p_service='Failed to start|start request repeated too quickly|Main process exited|timed out|dependency failed|Failed with result|segfault|core dumped'
  p_kernel='kernel panic|BUG:|Call Trace|watchdog|hung task|rcu.*stalled|soft lockup|hard LOCKUP|blocked for more than'
  p_time='Time has been changed|clock jump|timesyncd.*(timed out|synchron)|chronyd.*(step|offset)|NTP.*(step|offset)'
  p_usb='usb [0-9-]+: reset|xHCI host controller|device descriptor read|USB disconnect'
  p_suspect='under-voltage|throttl|overheat|link is down|deauth|disassoc|carrier lost|dhcp|oom|segfault|watchdog|kernel panic|I/O error|read-only file system|Failed to start|timed out|connection reset|network unreachable'

  deep_logs="$(collect_logs_all "$DEEP_WINDOW" "$DEEP_MAX_LINES")"
  deep_prev_boot_logs="$(collect_prev_boot_logs)"
  deep_total="$(count_non_empty_lines "$deep_logs")"

  deep_storage="$(count_pattern_in_logs "$deep_logs" "$p_storage")"
  deep_memory="$(count_pattern_in_logs "$deep_logs" "$p_memory")"
  deep_power="$(count_pattern_in_logs "$deep_logs" "$p_power")"
  deep_network="$(count_pattern_in_logs "$deep_logs" "$p_network")"
  deep_service="$(count_pattern_in_logs "$deep_logs" "$p_service")"
  deep_kernel="$(count_pattern_in_logs "$deep_logs" "$p_kernel")"
  deep_time="$(count_pattern_in_logs "$deep_logs" "$p_time")"
  deep_usb="$(count_pattern_in_logs "$deep_logs" "$p_usb")"

  prev_boot_warn_count="$(count_non_empty_lines "$deep_prev_boot_logs")"
  uptime_str="$(human_uptime)"
  uptime_sec="0"
  uptime_known=0
  if [[ -r /proc/uptime ]]; then
    uptime_sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")"
    if [[ "$uptime_sec" =~ ^[0-9]+$ ]]; then
      uptime_known=1
    fi
  fi
  recent_reboot_flag=0
  if (( uptime_known == 1 )) && (( uptime_sec < 86400 )); then
    recent_reboot_flag=1
  fi

  throttle_raw="$(vcgencmd_raw)"
  decode_throttle_flags "$throttle_raw"

  collect_service_snapshot

  deep_score=$(( deep_storage * 3 + deep_memory * 2 + deep_power * 3 + deep_network * 3 + deep_service * 2 + deep_kernel * 4 + deep_time + deep_usb + prev_boot_warn_count / 8 + SERVICE_DOWN_COUNT * 4 + recent_reboot_flag * 2 + THROTTLE_HISTORY_FLAG * 5 ))
  deep_status="$(deep_level "$deep_score")"

  deep_suspect_logs="$(printf "%s\n" "$deep_logs" | grep -Ei "$p_suspect" | tail -n 20 || true)"

  echo "Raspberry Pi Doctor (mode deep)"
  echo "Etat indisponibilite: $deep_status"
  echo "Analyse large: $DEEP_WINDOW (max: $DEEP_MAX_LINES lignes)"
  echo "Lignes de logs inspectees: $deep_total"
  echo "Temperature CPU: $CPU_TEMP"
  echo "Uptime: $uptime_str"
  if [[ -n "$throttle_raw" ]]; then
    echo "Power flags Raspberry Pi (vcgencmd): $throttle_raw"
    echo "Interpretation: $THROTTLE_SUMMARY"
  else
    echo "Power flags Raspberry Pi (vcgencmd): n/a"
  fi
  echo
  echo "Signaux pouvant mener a l'indisponibilite:"
  echo "- reseau (flap/coupure): $deep_network"
  echo "- alimentation/thermique: $deep_power"
  echo "- noyau/hang/watchdog: $deep_kernel"
  echo "- stockage I/O/SD: $deep_storage"
  echo "- memoire OOM: $deep_memory"
  echo "- services critiques: $deep_service"
  echo "- sauts de temps/NTP: $deep_time"
  echo "- USB/NIC resets: $deep_usb"
  echo "- warnings boot precedent: $prev_boot_warn_count"
  echo "- services critiques inactifs (etat actuel): $SERVICE_DOWN_COUNT"
  if (( uptime_known == 0 )); then
    echo "- reboot recent detecte (uptime < 24h): n/a"
  elif (( recent_reboot_flag == 1 )); then
    echo "- reboot recent detecte (uptime < 24h): oui"
  else
    echo "- reboot recent detecte (uptime < 24h): non"
  fi

  echo
  echo "Etat actuel des services critiques:"
  printf "%s\n" "$SERVICE_SNAPSHOT"

  investigation_done=0
  if (( deep_network > 0 || deep_power > 0 || deep_kernel > 0 || deep_storage > 0 || deep_memory > 0 || deep_service > 0 || deep_time > 0 || deep_usb > 0 || prev_boot_warn_count > 0 || SERVICE_DOWN_COUNT > 0 || THROTTLE_HISTORY_FLAG == 1 )); then
    echo
    echo "Investigations poussees (signaux > 0):"
  fi

  if (( deep_network > 0 )); then
    investigation_done=1
    print_investigation_from_logs "reseau (flap/coupure)" "$deep_network" "network" "$p_network" "$deep_logs" 10
  fi
  if (( deep_power > 0 )); then
    investigation_done=1
    print_investigation_from_logs "alimentation/thermique" "$deep_power" "power" "$p_power" "$deep_logs" 10
  fi
  if (( THROTTLE_HISTORY_FLAG == 1 )); then
    investigation_done=1
    echo
    echo "Investigation poussee: historique de throttling RPi"
    echo "- Source alerte: vcgencmd get_throttled => ${throttle_raw:-n/a}"
    echo "  Cause probable: $(explain_alert_line "power" "$THROTTLE_SUMMARY")"
  fi
  if (( deep_kernel > 0 )); then
    investigation_done=1
    print_investigation_from_logs "noyau/hang/watchdog" "$deep_kernel" "kernel" "$p_kernel" "$deep_logs" 8
  fi
  if (( deep_storage > 0 )); then
    investigation_done=1
    print_investigation_from_logs "stockage I/O/SD" "$deep_storage" "storage" "$p_storage" "$deep_logs" 8
  fi
  if (( deep_memory > 0 )); then
    investigation_done=1
    print_investigation_from_logs "memoire OOM" "$deep_memory" "memory" "$p_memory" "$deep_logs" 8
  fi
  if (( deep_service > 0 )); then
    investigation_done=1
    print_investigation_from_logs "services critiques (crash/timeouts)" "$deep_service" "services" "$p_service" "$deep_logs" 10
  fi
  if (( SERVICE_DOWN_COUNT > 0 )); then
    investigation_done=1
    investigate_inactive_services
  fi
  if (( deep_time > 0 )); then
    investigation_done=1
    print_investigation_from_logs "sauts de temps/NTP" "$deep_time" "time" "$p_time" "$deep_logs" 6
  fi
  if (( deep_usb > 0 )); then
    investigation_done=1
    print_investigation_from_logs "USB/NIC resets" "$deep_usb" "usb" "$p_usb" "$deep_logs" 6
  fi
  if (( prev_boot_warn_count > 0 )); then
    investigation_done=1
    print_investigation_from_logs "warnings boot precedent" "$prev_boot_warn_count" "kernel" "." "$deep_prev_boot_logs" 8
  fi

  if (( investigation_done == 0 )); then
    echo
    echo "Investigations poussees (signaux > 0):"
    echo "- Aucun signal > 0, pas d'investigation supplementaire."
  fi

  echo
  echo "Evenements suspects recents:"
  if [[ -n "$(printf "%s\n" "$deep_suspect_logs" | sed '/^[[:space:]]*$/d')" ]]; then
    printf "%s\n" "$deep_suspect_logs"
  else
    echo "Aucun evenement suspect sur la fenetre deep."
  fi

  echo
  echo "Resume des causes probables:"
  if (( deep_network == 0 && deep_power == 0 && deep_kernel == 0 && deep_storage == 0 && deep_memory == 0 && deep_service == 0 && SERVICE_DOWN_COUNT == 0 && THROTTLE_HISTORY_FLAG == 0 )); then
    echo "- Pas de cause forte visible dans les logs gardes localement."
    echo "- Si la panne est rare, lancer ce mode juste apres la prochaine deconnexion."
  else
    if (( deep_power > 0 || THROTTLE_HISTORY_FLAG == 1 )); then
      echo "- Priorite 1: alimentation/temperature (source majeure d'instabilite RPi)."
    fi
    if (( deep_network > 0 || deep_usb > 0 )); then
      echo "- Priorite 2: lien reseau (wifi/ethernet/NIC USB) avec coupures intermittentes."
    fi
    if (( deep_storage > 0 )); then
      echo "- Priorite 3: carte SD/stockage potentiellement instable."
    fi
    if (( deep_kernel > 0 || deep_memory > 0 || deep_service > 0 )); then
      echo "- Priorite 4: stabilite OS (OOM, crash service, kernel watchdog)."
    fi
  fi
}

if [[ "$MODE" == "advanced" ]]; then
  print_advanced
elif [[ "$MODE" == "deep" ]]; then
  print_deep
else
  print_noob
fi

echo
echo "Temps d'execution: ${SECONDS}s"

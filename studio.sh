#!/usr/bin/env bash
# Roblox Studio en Raspberry Pi 5 (ARM64) — lanzador completo
#
# Auto-detecta el modo de renderizado:
#
#   DIRECTO  → si tu sesión X actual ya expone DRI3 (glamor), lanza Studio
#              directamente en ella. Es lo que ocurre con
#              /etc/X11/xrdp/xorg.conf con `Load "glamoregl"` + `Option "DRI3" "1"`.
#
#   PUENTE   → si tu sesión NO tiene DRI3 (xrdp/VNC puro), arranca un Xorg
#              paralelo con DRI3 en :20 y sirve ese display por VNC a una
#              ventana de tu escritorio (x11vnc + vncviewer).
#
# Uso:
#   studio.sh            → pipeline completo
#   studio.sh status     → qué está corriendo, en qué modo y qué faltaría
#   studio.sh stop       → cierra Studio, x11vnc y el visor
#
# NOTA sobre root: solo hace falta root para arrancar el Xorg paralelo :20
# (modo PUENTE), y solo una vez por boot. Se usa `sudo -n` → falla rápido con
# un aviso en lugar de bloquearse esperando contraseña.
set -euo pipefail

XORG_CONF="/tmp/xorg-dri3.conf"
XORG_LOG="/tmp/xorg-dri3d.log"
BRIDGE_DISPLAY=":20"
VNC_PORT=5900

# Umbral para distinguir "Studio arrancando" de "Studio murió y dejó huérfano"
STUDIO_STARTUP_S=90

log()  { echo "[studio] $*"; }
warn() { echo "[studio] AVISO: $*" >&2; }

sudon() { sudo -n "$@" 2>/dev/null; }   # no interactivo: nunca se bloquea
have()  { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# NOTA (bug real que costó depurar):
#   NO usar `... | grep -q PATRÓN` bajo `set -o pipefail`.
#   `grep -q` cierra la tubería al primer match → el proceso de la izquierda
#   recibe SIGPIPE y devuelve 141 → pipefail propaga un FALSO negativo.
#   Solución: `... | grep PATRÓN >/dev/null` (consume todo el input).
# ---------------------------------------------------------------------------

# Muestra DRI3 en ese display (o 1 si no hay display → no hay DRI3)
display_dri3() {
  local d="$1"
  [ -n "$d" ] || return 1
  DISPLAY="$d" xdpyinfo 2>/dev/null | grep DRI3 >/dev/null
}

# Display de la sesión actual, sin el ".0" final (":1.0" → ":1")
session_display() {
  local d="${DISPLAY:-}"
  [ -n "$d" ] || return 1
  printf '%s' "${d%%.*}"
}

# Decide modo y fija TARGET_DISPLAY / MODE
choose_mode() {
  local sess
  sess=$(session_display || true)
  if [ -n "$sess" ] && display_dri3 "$sess"; then
    MODE="direct"
    TARGET_DISPLAY="$sess"
    return 0
  fi
  # ¿el Xorg paralelo ya corre y tiene DRI3?
  if display_dri3 "$BRIDGE_DISPLAY"; then
    MODE="bridge"
    TARGET_DISPLAY="$BRIDGE_DISPLAY"
    return 0
  fi
  # nada disponible: modo puente e intentará arrancar :20
  MODE="bridge"
  TARGET_DISPLAY="$BRIDGE_DISPLAY"
}

xorg_bridge_ok() { pgrep -x Xorg >/dev/null 2>&1 && display_dri3 "$BRIDGE_DISPLAY"; }
studio_pid(){ pgrep -x RobloxStudioBet 2>/dev/null | head -1; }
studio_win(){ DISPLAY="$TARGET_DISPLAY" xwininfo -root -tree 2>/dev/null | grep '"Roblox Studio"' >/dev/null; }
studio_age(){ ps -o etimes= -p "$1" 2>/dev/null | tr -d ' '; }
vnc_ok()    { pgrep -x x11vnc >/dev/null 2>&1; }
view_ok()   { pgrep -x vncviewer >/dev/null 2>&1; }

# up = con ventana | starting = proceso sin ventana y recién arrancado
# stale = proceso sin ventana tras el arranque → la UI cerró, reteniendo RAM
studio_state() {
  local pid age
  pid=$(studio_pid) || { echo "off"; return; }
  studio_win && { echo "up"; return; }
  age=$(studio_age "$pid"); age=${age:-0}
  [ "$age" -gt "$STUDIO_STARTUP_S" ] && echo "stale" || echo "starting"
}

# --------------------------------------------------------------- comandos ----
cmd_status() {
  local pid st
  choose_mode
  pid=$(studio_pid || true); st=$(studio_state)
  log "modo                   : $MODE (display $TARGET_DISPLAY)"
  case "$MODE" in
    direct) log "  tu sesión ya expone DRI3 → sin Xorg paralelo ni VNC" ;;
    bridge) log "  tu sesión sin DRI3 → Xorg $BRIDGE_DISPLAY + x11vnc + visor" ;;
  esac
  log "DRI3 en $TARGET_DISPLAY : $(display_dri3 "$TARGET_DISPLAY" && echo sí || echo NO)"
  case "$st" in
    up)       log "Studio                 : sí (PID $pid, ventana visible)" ;;
    starting) log "Studio                 : arrancando (PID $pid, ${pid:+$(studio_age "$pid") }s, sin ventana aún)" ;;
    stale)    log "Studio                 : HUÉRFANO (PID $pid, ${pid:+$(studio_age "$pid") }s, sin ventana → UI cerrada, reteniendo RAM)" ;;
    *)        log "Studio                 : NO" ;;
  esac
  [ "$MODE" = "bridge" ] && {
    log "x11vnc (:$VNC_PORT)     : $(vnc_ok && echo sí || echo NO)"
    log "visor en sesión         : $(view_ok && echo sí || echo NO)"
  }
  log "sudo root disponible    : $(sudo -n true 2>/dev/null && echo sí || echo no)"
}

cmd_stop() {
  for p in $(ps -eo pid,comm | grep -iE 'RobloxStudio|robloxcrash|vinegar|x11vnc|vncviewer|start\.exe|wineserver' | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null || true
  done
  log "Studio, x11vnc y visor detenidos."
}

case "${1:-}" in
  stop)   cmd_stop; exit 0 ;;
  status) cmd_status; exit 0 ;;
esac

choose_mode
log "modo: $MODE (display $TARGET_DISPLAY)"

# --------------------------------------------------------- permisos DRM ----
ensure_dri_perms() {
  local need=() n
  for n in /dev/dri/card0 /dev/dri/card1 /dev/dri/renderD128; do
    [ -e "$n" ] || continue
    [ -w "$n" ] || need+=("$n")
  done
  [ ${#need[@]} -eq 0 ] && return 0
  if sudon setfacl -m u:"$USER":rw "${need[@]}"; then
    log "ACL de DRM aplicadas a: ${need[*]}"
  else
    warn "sin escritura en: ${need[*]} (¿grupos video/render?)"
    warn "  sudo setfacl -m u:\$USER:rw /dev/dri/card0 /dev/dri/card1 /dev/dri/renderD128"
  fi
}

# ------------------------------------- Xorg paralelo con DRI3 (solo PUENTE) ----
ensure_xorg_conf() {
  [ -f "$XORG_CONF" ] && return 0
  cat > "$XORG_CONF" <<'EOF'
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "DontVTSwitch" "true"
    Option "DontZap" "true"
EndSection
Section "Device"
    Identifier "vc4"
    Driver "modesetting"
    Option "AccelMethod" "glamor"
    Option "kmsdev" "/dev/dri/card1"
EndSection
Section "Screen"
    Identifier "scr"
    Device "vc4"
    DefaultDepth 24
EndSection
EOF
}

ensure_bridge_xorg() {
  if display_dri3 "$BRIDGE_DISPLAY"; then
    log "Xorg puente activo en $BRIDGE_DISPLAY."; return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    warn "modo puente necesita root para arrancar Xorg en $BRIDGE_DISPLAY."
    warn "  sudo /usr/lib/xorg/Xorg.wrap $BRIDGE_DISPLAY -config $XORG_CONF \\"
    warn "      -logfile $XORG_LOG -noreset -nolisten tcp &"
    return 1
  fi
  ensure_xorg_conf
  log "Arrancando Xorg puente (glamor) en $BRIDGE_DISPLAY..."
  sudon /usr/lib/xorg/Xorg.wrap "$BRIDGE_DISPLAY" -config "$XORG_CONF" \
      -logfile "$XORG_LOG" -noreset -nolisten tcp >/dev/null 2>&1 &
  local i
  for i in $(seq 1 20); do
    display_dri3 "$BRIDGE_DISPLAY" && { log "DRI3 listo en $BRIDGE_DISPLAY."; return 0; }
    sleep 1
  done
  warn "DRI3 no confirmado; mira $XORG_LOG"
}

# ---------------------------------------------------- lanzar Studio ----
kill_stale_studio() {
  local pid age
  pid=$(studio_pid) || return 0
  age=$(studio_age "$pid"); age=${age:-0}
  warn "Studio (PID $pid) lleva ${age}s sin ventana → la UI se cerró, proceso huérfano."
  log "Limpiando para poder relanzar..."
  kill "$pid" 2>/dev/null || true
  sleep 3
  kill -9 "$pid" 2>/dev/null || true
  for p in $(ps -eo pid,comm | grep -iE 'robloxcrash' | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null || true
  done
  sleep 1
}

# Marca a Studio (y a su WebView2) como víctimas preferentes del OOM killer.
# Contexto: la sesión de escritorio corre con OOMScoreAdjust=-500 y
# OOMPolicy=continue, así que si vuelve a haber un pico de memoria muere
# SOLO Studio y el escritorio sigue vivo (antes, el pico mataba la sesión
# entera y "congelaba" la Pi). Subir el oom_score_adj propio está permitido
# sin root; bajarlo sí lo necesita.
mark_oom_victim() {
  local p n=0
  for p in $(ps -eo pid,comm | grep -iE 'robloxstudio|msedgewebview|robloxcrash' | grep -v grep | awk '{print $1}'); do
    echo 500 > "/proc/$p/oom_score_adj" 2>/dev/null && n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then
    log "OOM: $n proceso(s) de Studio marcados como víctima (oom_score_adj=+500)"
  fi
}

ensure_studio_running() {
  case "$(studio_state)" in
    up)
      log "Studio ya está corriendo (PID $(studio_pid)), ventana visible."
      mark_oom_victim
      return 0 ;;
    starting)
      log "Studio arrancando (PID $(studio_pid)), esperando ventana..." ;;
    stale)
      kill_stale_studio ;;
  esac

  if ! have vinegar; then warn "vinegar no está en PATH."; return 1; fi

  log "Lanzando Vinegar → Roblox Studio (x86_64 vía box64 + Wine 10.0) en $TARGET_DISPLAY..."
  ( cd "$HOME/Downloads/StudioEmulator" && DISPLAY="$TARGET_DISPLAY" nohup vinegar \
      > "$HOME/Downloads/StudioEmulator/vinegar-auto.log" 2>&1 & )

  log "Esperando la ventana de Studio (login ~30-40s)..."
  local i
  for i in $(seq 1 60); do
    studio_win && { log "Ventana de Studio detectada."; mark_oom_victim; return 0; }
    sleep 1
  done
  warn "la ventana no apareció en 60s (¿crash? ver vinegar-auto.log)"
}

# ------------------------------- x11vnc: sirve el display por VNC (solo PUENTE) ----
ensure_x11vnc() {
  vnc_ok && { log "x11vnc ya sirve $BRIDGE_DISPLAY."; return 0; }
  if ! have x11vnc; then warn "x11vnc no instalado: sudo apt install x11vnc"; return 1; fi
  log "Sirviendo $BRIDGE_DISPLAY por VNC en localhost:$VNC_PORT..."
  nohup x11vnc -display "$BRIDGE_DISPLAY" -localhost -rfbport "$VNC_PORT" \
      -forever -shared -nopw >/tmp/x11vnc-studio.log 2>&1 &
  sleep 2
  vnc_ok || warn "x11vnc no arrancó; ver /tmp/x11vnc-studio.log"
}

# ------------------------- ventana VNC en la sesión (solo PUENTE) ----
ensure_viewer() {
  view_ok && { log "Visor ya abierto en tu escritorio."; return 0; }
  local sess
  sess=$(session_display || true)
  if ! have vncviewer; then warn "visor no instalado: sudo apt install tigervnc-viewer"; return 1; fi
  if [ -z "$sess" ] || ! DISPLAY="$sess" xdpyinfo >/dev/null 2>&1; then
    warn "no hay sesión X a la que abrir el visor"; return 1
  fi
  log "Abriendo ventana en tu sesión $sess..."
  DISPLAY="$sess" nohup vncviewer "localhost:$VNC_PORT" \
      >/tmp/vncviewer-studio.log 2>&1 &
  sleep 3
  view_ok || warn "el visor no arrancó; ver /tmp/vncviewer-studio.log"
}

# --------------------------------------------------------------- main ----
ensure_dri_perms

if [ "$MODE" = "direct" ]; then
  log "Tu sesión expone DRI3 → modo DIRECTO (sin Xorg paralelo ni VNC)."
else
  ensure_bridge_xorg || true
fi

ensure_studio_running || true

if [ "$MODE" = "bridge" ]; then
  ensure_x11vnc || true
  ensure_viewer || true
fi

echo
log "Estado:"
cmd_status
echo
if [ "$(studio_state)" = "up" ]; then
  if [ "$MODE" = "direct" ]; then
    log "Listo. Studio está en tu propio escritorio (ventana \"Roblox Studio\")."
  else
    log "Listo. Busca la ventana \"pi:$BRIDGE_DISPLAY - TigerVNC\" en tu escritorio."
  fi
  log "Interactiva: clic, teclado y QR funcionan."
else
  warn "Falta algo. Revisa los avisos de arriba."
fi
log "Para cerrar todo: $0 stop"

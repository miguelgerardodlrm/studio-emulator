#!/usr/bin/env bash
# =============================================================================
# perf-report.sh — MIDE a dónde se va la CPU mientras Studio corre
# -----------------------------------------------------------------------------
#   ./perf-report.sh            mide y da un veredicto
#   ./perf-report.sh --idle 20  mide el redibujado en reposo durante 20 s
#
# Para qué sirve: en esta máquina el cuello de botella NO es obvious. Este
# script separa el emulation cost (Studio + WebView2) del overhead de la sesión
# (Xtigervnc) y te dice cuál domina EN TU EQUIPO, antes de que dediques horas
# a optimizar algo que no era el problema.
#
# Salida pensada para pegarse en un issue: §13 del README pide estas cifras.
# =============================================================================
set -uo pipefail

IDLE_SECS=20
[ "${1:-}" = "--idle" ] && [ -n "${2:-}" ] && IDLE_SECS="$2"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_bad=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '%s  ✓ %s%s\n' "$c_ok"   "$*" "$c_off"; }
warn() { printf '%s  ! %s%s\n' "$c_warn" "$*" "$c_off"; }
bad()  { printf '%s  ✗ %s%s\n' "$c_bad"  "$*" "$c_off"; }
sec()  { printf '\n%s── %s %s\n' "$c_dim" "$*" "$(printf '─%.0s' $(seq 1 $((58 - ${#1}))))"; }
# grep sin -q: `-q` cierra stdin y provoca SIGPIPE (141) en la tubería.
gx() { grep "$@" >/dev/null; }

# RAM real (PSS). La RSS cuenta dos veces las páginas compartidas: con Studio
# y Wine eso infla el número hasta ~2×. No uses RSS para comparar.
pss_mb() { awk '/^Pss:/{printf "%d", $2/1024}' "/proc/$1/smaps_rollup" 2>/dev/null || echo 0; }

# ------------------------------------------------------------------ entorno
sec "Entorno"
printf '  %-22s %s\n' "kernel"       "$(uname -r)"
printf '  %-22s %s\n' "núcleos"      "$(nproc)"
gov=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo '?')
freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo '?')
printf '  %-22s %s (%s kHz)\n' "gobernador" "$gov" "$freq"
t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
printf '  %-22s %s °C\n' "temperatura" "$((t/1000))"
[ "$((t/1000))" -gt 80 ] && warn "por encima de 80 °C: puede estar limitando por calor"

free -m | awk '/^Mem:/{printf "  %-22s %d MB usados / %d MB\n", "RAM", $3, $2}'
sw=$(free -m | awk '/Swap:/{print $3}')
[ "${sw:-0}" -gt 4000 ] && warn "swap con ${sw} MB usados → si Studio está en swap, va muy lento"

# ------------------------------------------------------- procesos por CPU
sec "CPU por proceso (muestra de 5 s)"
top -b -d 5 -n 1 -o %CPU 2>/dev/null | awk 'NR>7 && $9+0>1 {
    printf "  %-22s %5s %% CPU   %6d MB\n", $12, $9, $6/1024
}' | head -8

studio=$(pgrep -x RobloxStudioBet | head -1)
webview=$(pgrep -cx msedgewebview2 2>/dev/null | head -1)
vnc=$(pgrep -x Xtigervnc | head -1)

# ------------------------------------------------------------- veredictos
sec "Diagnóstico"

if [ -z "$studio" ]; then
  bad "Studio no está corriendo — lanza algo antes de medir."
  echo
  echo "  Lanza directo al editor (ahorra el Chromium emulado):"
  echo "     ./studio.sh /ruta/al/tu-place.rbxl"
  exit 0
fi

studio_cpu=$(top -b -d 5 -n 1 -p "$studio" 2>/dev/null | awk 'NR>7{print $9; exit}')
studio_pss=$(pss_mb "$studio")
printf '  %-26s %s %% CPU   %s MB\n' "Studio (emulado)" "${studio_cpu:-?}" "$studio_pss"

# ¿MÁS memoria en swap que en RAM? Con 16 GB y RAM libre, eso es un fallo de
# política del kernel, no falta de recursos. Cada página intercambiada que
# Studio toque después paga I/O de disco, y eso se nota muchísimo más que la
# propia emulación.
studio_swap=$(awk '/^Swap:/{printf "%d", $2/1024}' "/proc/$studio/smaps_rollup" 2>/dev/null || echo 0)
if [ "${studio_swap:-0}" -gt "$studio_pss" ] && [ "$studio_swap" -gt 200 ]; then
  bad "Studio tiene MÁS memoria en swap (${studio_swap} MB) que en RAM (${studio_pss} MB)"
  warn "  Con RAM libre, el kernel intercambió páginas frías que luego hay"
  warn "  que traer de vuelta pagando I/O. Arreglo (necesita sudo):"
  warn "     sudo swapoff -a && sudo swapon -a   # trae todo de vuelta a RAM"
  warn "     echo 10 | sudo tee /proc/sys/vm/swappiness  # no lo vuelva a hacer"
elif [ "${studio_swap:-0}" -gt 300 ]; then
  warn "Studio tiene ${studio_swap} MB en swap — parte de él pagará I/O"
else
  ok "Studio cabe en RAM (swap: ${studio_swap} MB)"
fi

if [ "${webview:-0}" -gt 0 ]; then
  wtot=0
  for p in $(pgrep -x msedgewebview2 2>/dev/null); do wtot=$((wtot + $(pss_mb "$p"))); done
  wcpu=$(top -b -d 5 -n 1 -p "$(pgrep -x msedgewebview2 | head -1)" 2>/dev/null | awk 'NR>7{print $9; exit}')
  warn "WebView2: ${webview} procesos, ${wtot} MB, ${wcpu:-?} % CPU"
  warn "  → es la PANTALLA DE INICIO, un Chromium EMULADO. Córtala:"
  warn "     ./studio.sh /ruta/al/tu-place.rbxl   (§14.1)"
else
  ok "WebView2 ausente — no estás pagando el Chromium emulado (§14.1)"
fi

if [ -n "$vnc" ]; then
  vcpu=$(top -b -d 5 -n 1 -p "$vnc" 2>/dev/null | awk 'NR>7{print $9; exit}')
  printf '  %-26s %s %% CPU\n' "Xtigervnc (codifica)" "${vcpu:-?}"
  vc=${vcpu%%.*}; vc=${vc:-0}
  [ "$vc" -gt 60 ] && warn "  → el VNC se come >60 % de un núcleo. Ver §14.3"
else
  ok "No hay Xtigervnc (¿sesión directa?) — sin coste de codificación"
fi

# ------------------------------------------- ¿se redibuja en reposo?
if [ -n "${DISPLAY:-}" ] && command -v xwd >/dev/null 2>&1 && command -v convert >/dev/null 2>&1; then
  sec "Redibujado en reposo (${IDLE_SECS}s sin tocar nada)"
  a=/tmp/.perf-a.$$; b=/tmp/.perf-b.$$
  DISPLAY="$DISPLAY" xwd -root 2>/dev/null | convert xwd:- rgb:"$a" 2>/dev/null
  echo "  esperando ${IDLE_SECS}s…"
  sleep "$IDLE_SECS"
  DISPLAY="$DISPLAY" xwd -root 2>/dev/null | convert xwd:- rgb:"$b" 2>/dev/null
  if [ -s "$a" ] && [ -s "$b" ]; then
    total=$(($(stat -c%s "$a") / 3))          # RGB = 3 bytes por píxel
    dif=$(cmp -l "$a" "$b" 2>/dev/null | wc -l)
    pix=$((dif / 3))                           # cmp -l cuenta BYTES, no píxeles
    pct=$((pix * 100 / total))
    printf '  cambió %d de %d píxeles  (%d %%)\n' "$pix" "$total" "$pct"
    if [ "$pct" -gt 10 ]; then
      bad "Studio se redibuja en REPOSO. Cada frame lo recodifica el VNC."
      warn "Reduce el tamaño del viewport y cierra paneles que no uses:"
      warn "menos píxeles = menos render emulado Y menos codificación."
    else
      ok "está quieto — el coste del VNC es por el tamaño de la pantalla"
    fi
  else
    warn "no se pudo capturar la pantalla"
  fi
  rm -f "$a" "$b"
else
  sec "Redibujado en reposo"
  warn "falta DISPLAY o xwd/convert — omitido"
fi

# --------------------------------------------------------------- resumen
sec "Resumen"
load=$(uptime | grep -oP 'load average: \K[0-9.]+' || echo 0)
ok "load average ${load} sobre $(nproc) núcleos"
echo
echo "  Si quieres pegar esto en un issue, incluye también:"
echo "     glxinfo -B | grep renderer"
echo "     vulkaninfo --summary | grep deviceName"
echo "     ./studio.sh status"

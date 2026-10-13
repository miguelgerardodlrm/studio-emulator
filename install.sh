#!/usr/bin/env bash
# =============================================================================
# install.sh — Instala TODO el stack de Roblox Studio en una Raspberry Pi 5
# -----------------------------------------------------------------------------
#   ./install.sh              # instala lo que falte (idempotente)
#   ./install.sh --dry-run    # solo imprime lo que haría, no toca nada
#   ./install.sh --skip-box64 # no compila box64 (si ya lo tienes)
#   ./install.sh --skip-memory# no toca swap ni systemd
#   ./install.sh --help
#
# Etapas (cada una se salta si ya está hecha):
#   1  deps de compilación y ejecución (apt)
#   2  box64 desde source con -DRPI5ARM64=1   ← ~10-20 min en la Pi 5
#   3  binfmt_misc → los ELF x86_64 se ejecutan "solos"
#   4  multiarch amd64 + Vulkan v3dv
#   5  grupos video/render para acceder a /dev/dri
#   6  Wine 10.0-staging de Kron4ek          ← ¡la versión que funciona!
#   7  Vinegar desde source
#   8  config de Vinegar + webview-env.sh
#   9  memoria: swap 16 GB + OOMPolicy=continue  ← evita la congelación
#  10  DRI3 en xrdp (NO se automatiza: se instruye)
#
# Lo que NO hace: descarga Roblox Studio (lo hace Vinegar en el primer arranque,
# con tu cuenta) ni configura tu sesión gráfica.
# =============================================================================
set -euo pipefail

# ⚠️ No usar `grep -q` dentro de tuberías bajo pipefail: cierra la tubería,
# el proceso de la izquierda recibe SIGPIPE (exit 141) y pipefail propaga un
# falso negativo. Se usa `grep PATRÓN >/dev/null`.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
SKIP_BOX64=0
SKIP_MEMORY=0
STAGES_ALL=(deps box64 binfmt multiarch drm wine vinegar config memory dri3)

# ----------------------------------------------------------------- utilidades
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

info()  { printf '%s\n' "$*"; }
step()  { printf '\n%s== %s ==%s\n' "$c_dim" "$*" "$c_off"; }
ok()    { printf '%s  ✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
warn()  { printf '%s  ! %s%s\n' "$c_warn" "$*" "$c_off"; }
err()   { printf '%s  ✗ %s%s\n' "$c_err" "$*" "$c_off"; }

# Ejecuta un comando (o lo imprime en --dry-run). `run echo hola` es seguro.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s  [dry-run] %s%s\n' "$c_dim" "$*" "$c_off"
    return 0
  fi
  "$@"
}

# ¿ya está hecho? → el resto de la etapa se salta
have() { command -v "$1" >/dev/null 2>&1; }

# grep SIN -q, pensado para usar en TUBERÍAS bajo `set -o pipefail`.
# `grep -q` cierra stdin en cuanto encuentra el primer match → el proceso de la
# izquierda recibe SIGPIPE (exit 141) → pipefail lo propaga y la condición da un
# FALSO NEGATIVO (el comando se cumplía, pero bash cree que no).
# `grep PATRÓN >/dev/null` lee la entrada entera y devuelve 0/1 de verdad.
# ⚠️ Al depurar este script se cayeron DOS trampas distintas al detectar box64:
#   1. `box64 --version | grep -q .`  → SIGPIPE/141 bajo pipefail.
#   2. `box64 --version 2>/dev/null`  → box64 escribe la versión en STDERR, no
#      en stdout: redirigir stderr a /dev/null deja la tubería vacía → grep 1.
#      Hay que usar `2>&1` antes de la tubería.
gx() { grep "$@" >/dev/null; }

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --skip-box64)   SKIP_BOX64=1 ;;
    --skip-memory)  SKIP_MEMORY=1 ;;
    -h|--help)      usage ;;
    *) err "opción desconocida: $1"; echo "usa --help"; exit 2 ;;
  esac
  shift
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if have sudo; then SUDO="sudo"; else
    err "este script necesita sudo para las etapas 1-5 y 9."; exit 1
  fi
fi
# sudo -n solo si ya hay credenciales; si no, sudo pedirá contraseña en su momento
if [ "$DRY_RUN" -eq 0 ] && [ -n "$SUDO" ]; then
  sudo -v 2>/dev/null || warn "sudo pedirá la contraseña cuando toque."
fi

# `run` ya se encarga de DRY_RUN
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s  [dry-run] %s%s\n' "$c_dim" "$*" "$c_off"
    return 0
  fi
  "$@"
}

# =============================================================================
info "Roblox Studio en Raspberry Pi 5 — instalador"
info "repositorio: $REPO_DIR"
[ "$DRY_RUN" -eq 1 ] && warn "MODO DRY-RUN: no se escribirá nada"

# ---------------------------------------------------------------- 0. previo
step "0. Comprobaciones previas"

arch=$(uname -m)
if [ "$arch" = "aarch64" ]; then ok "arquitectura: aarch64"
else err "se necesita aarch64 (tienes: $arch)"; exit 1; fi

ps=$(getconf PAGE_SIZE 2>/dev/null || echo '?')
if [ "$ps" = "4096" ]; then ok "páginas de 4 KB (box64 lo exige)"
else err "páginas de $ps B — box64 necesita 4 KB"; exit 1; fi

if have curl || have wget; then ok "descarga disponible"
else warn "falta curl — se instalará en la etapa 1"; fi

dri_ok=0
for n in /dev/dri/card0 /dev/dri/renderD128; do
  [ -e "$n" ] && dri_ok=1
done
if [ "$dri_ok" -eq 1 ]; then ok "nodos DRM presentes (/dev/dri)"
else warn "no veo /dev/dri — ¿estás en una Pi con GPU?"; fi

if getent group video | gx -w "$(id -un)"; then ok "usuario en grupo video"
else warn "usuario NO en grupo video (etapa 5 lo arregla)"; fi

free_swap=$(free -m | awk '/Swap:/{print $2}')
if [ "${free_swap:-0}" -ge 8000 ]; then ok "swap ya activo (${free_swap} MB)"
else warn "swap insuficiente (${free_swap:-0} MB) — etapa 9"; fi

df_avail=$(df -BG "$HOME" | awk 'NR==2{print int($4)}')
if [ "${df_avail:-0}" -ge 15 ]; then ok "espacio en disco: ${df_avail} GB"
else err "hacen falta ~15 GB libres (tienes ${df_avail:-0} GB)"; exit 1; fi

# ------------------------------------------------------------------- 1. deps
step "1. Dependencias (apt)"
APT_BUILD="git cmake build-essential libpthread-stubs0-dev libegl-dev libgl-dev libx11-dev"
APT_RUN="vulkan-tools mesa-vulkan-drivers mesa-utils curl x11-apps imagemagick"
if have git && have cmake && have gcc; then
  ok "herramientas de compilación presentes"
else
  run $SUDO apt-get update
  run $SUDO apt-get install -y $APT_BUILD
fi
# instala lo que falte de runtime
MISSING=""
for p in $APT_RUN; do dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"; done
if [ -n "$MISSING" ]; then
  info "  instalando:$MISSING"
  run $SUDO apt-get update
  run $SUDO apt-get install -y $MISSING
else
  ok "paquetes de ejecución presentes"
fi

# ------------------------------------------------------------------ 2. box64
step "2. box64 (compilación, ~10-20 min)"
if [ "$SKIP_BOX64" -eq 1 ]; then
  warn "omitido por --skip-box64"
elif [ -x /usr/local/bin/box64 ] && /usr/local/bin/box64 --version 2>&1 | gx .; then
  ok "box64 ya compilado: $(/usr/local/bin/box64 --version 2>&1 | head -1)"
else
  info "  clonando ptitSeb/box64 y compilando con -DRPI5ARM64=1 ..."
  BOX_DIR="$REPO_DIR/box64-src"
  [ -d "$BOX_DIR/.git" ] || run git clone --depth 1 https://github.com/ptitSeb/box64.git "$BOX_DIR"
  run mkdir -p "$BOX_DIR/build"
  if [ "$DRY_RUN" -eq 1 ]; then
    run cmake -S "$BOX_DIR" -B "$BOX_DIR/build" -DRPI5ARM64=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo
    run cmake --build "$BOX_DIR/build" -j"$(nproc)"
  else
    cmake -S "$BOX_DIR" -B "$BOX_DIR/build" -DRPI5ARM64=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build "$BOX_DIR/build" -j"$(nproc)"
    $SUDO cmake --install "$BOX_DIR/build"
  fi
  ok "box64 instalado en /usr/local/bin/box64"
  warn "NO uses el de apt (0.3.8, muy antiguo y con prioridad en binfmt)"
fi

# ----------------------------------------------------------------- 3. binfmt
step "3. binfmt_misc"
BINFMT_OK=0
if [ -r /proc/sys/fs/binfmt_misc/box64 ] && grep -F '/usr/local/bin/box64' /proc/sys/fs/binfmt_misc/box64 >/dev/null 2>&1; then
  BINFMT_OK=1
fi
if [ "$BINFMT_OK" -eq 1 ]; then
  ok "binfmt ya apunta a /usr/local/bin/box64"
else
  run $SUDO mkdir -p /etc/binfmt.d
  run $SUDO cp "$REPO_DIR/examples/binfmt-box64.conf" /etc/binfmt.d/box64.conf
  run $SUDO systemctl restart systemd-binfmt
  if [ "$DRY_RUN" -eq 0 ]; then
    sleep 1
    if grep -F '/usr/local/bin/box64' /proc/sys/fs/binfmt_misc/box64 >/dev/null 2>&1; then
      ok "registrado"
    else
      warn "no se pudo verificar; comprueba: cat /proc/sys/fs/binfmt_misc/box64"
    fi
  fi
fi

# -------------------------------------------------------------- 4. multiarch
step "4. multiarch amd64 + Vulkan (v3dv)"
if dpkg --print-foreign-architectures | grep -x amd64 >/dev/null 2>&1; then
  ok "arquitectura amd64 ya habilitada"
else
  run $SUDO dpkg --add-architecture amd64
  run $SUDO apt-get update
fi
M64=""
for p in mesa-vulkan-drivers:amd64 mesa-utils:amd64; do
  dpkg -s "$p" >/dev/null 2>&1 || M64="$M64 $p"
done
if [ -n "$M64" ]; then
  info "  instalando:$M64"
  run $SUDO apt-get install -y $M64
else
  ok "paquetes amd64 presentes"
fi
if [ "$DRY_RUN" -eq 0 ] && have vulkaninfo; then
  dev=$(vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | sed 's/.*= *//' || true)
  [ -n "$dev" ] && ok "vulkaninfo ve: $dev" || warn "vulkaninfo no ve GPU todavía (¿binfmt/?xrdp?)"
fi

# ---------------------------------------------------------------- 5. drm/grupos
step "5. Acceso a /dev/dri (grupos video y render)"
for g in video render; do
  if getent group "$g" >/dev/null 2>&1; then
    if getent group "$g" | gx -w "$(id -un)"; then
      ok "en grupo $g"
    else
      run $SUDO usermod -aG "$g" "$(id -un)"
      warn "añadido a $g — hace falta reconectar la sesión para que surta efecto"
    fi
  else
    warn "no existe el grupo $g"
  fi
done

# ------------------------------------------------------------------- 6. wine
step "6. Wine 10.0-staging (Kron4ek)"
WINE_DIR="$REPO_DIR/wine-test"
WINE_ROOT="$WINE_DIR/wine-10.0-staging-amd64"
if [ -x "$WINE_ROOT/bin/wine64" ]; then
  ok "Wine 10.0 ya descargado: $WINE_ROOT"
else
  run mkdir -p "$WINE_DIR"
  URL="https://github.com/Kron4ek/Wine-Builds/releases/download/10.0/wine-10.0-staging-amd64.tar.xz"
  if have curl; then run curl -fL -o "$WINE_DIR/wine10.tar.xz" "$URL"
  else run wget -O "$WINE_DIR/wine10.tar.xz" "$URL"; fi
  run tar -xf "$WINE_DIR/wine10.tar.xz" -C "$WINE_DIR"
  [ -x "$WINE_ROOT/bin/wine64" ] && ok "Wine instalado: $WINE_ROOT" || \
    warn "no se pudo verificar la extracción"
  warn "Wine 11.x (Kombucha) CUELGA en wineboot bajo box64 — no lo uses (§6)"
fi

# --------------------------------------------------------------- 7. vinegar
step "7. Vinegar (desde source)"
if have vinegar; then
  ok "vinegar ya instalado: $(command -v vinegar)"
else
  GV=""
  for p in golang-go libgtk-4-dev libadwaita-1-dev gettext libvulkan-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || GV="$GV $p"
  done
  [ -n "$GV" ] && run $SUDO apt-get install -y $GV
  VINEGAR_SRC="$REPO_DIR/vinegar-src"
  [ -d "$VINEGAR_SRC/.git" ] || run git clone --depth 1 https://github.com/vinegarhq/vinegar.git "$VINEGAR_SRC"
  if [ "$DRY_RUN" -eq 1 ]; then
    run make -C "$VINEGAR_SRC"
    run $SUDO make -C "$VINEGAR_SRC" install
  else
    make -C "$VINEGAR_SRC"
    $SUDO make -C "$VINEGAR_SRC" install
  fi
  ok "vinegar instalado (GPL-3.0 — ver CREDITS.md)"
fi

# ----------------------------------------------------------------- 8. config
step "8. Config de Vinegar + webview-env.sh"
run chmod +x "$REPO_DIR/webview-env.sh" "$REPO_DIR/studio.sh" "$REPO_DIR/xinput.py"
CFG="$HOME/.config/vinegar/config.toml"
if [ -f "$CFG" ]; then
  ok "config.toml ya existe — NO lo sobrescribo"
  if ! grep -q 'webview-env.sh' "$CFG" 2>/dev/null; then
    warn "falta el 'launcher' de webview-env.sh (§11.4) — añádelo a mano:"
    info "      launcher = \"$REPO_DIR/webview-env.sh\""
    info "    (o haz backup y vuelve a ejecutar este script)"
  fi
else
  run mkdir -p "$HOME/.config/vinegar"
  if [ "$DRY_RUN" -eq 1 ]; then
    run cp "$REPO_DIR/examples/vinegar-config.toml" "$CFG"
  else
    sed "s|^wineroot = .*|wineroot = \"$WINE_ROOT\"|;
         s|^# <<< AJUSTA: ruta.*||;
         s|^launcher = .*|launcher = \"$REPO_DIR/webview-env.sh\"|" \
        "$REPO_DIR/examples/vinegar-config.toml" > "$CFG"
    ok "config.toml escrito con tus rutas reales"
  fi
fi

# ---------------------------------------------------------------- 9. memoria
step "9. Memoria: swap + OOMPolicy (evita la congelación)"
if [ "$SKIP_MEMORY" -eq 1 ]; then
  warn "omitido por --skip-memory"
else
  # --- swap ---
  if swapon --show 2>/dev/null | gx .; then
    ok "swap ya activo: $(swapon --show --noheadings | awk '{print $1" ("$3")"}' | head -1)"
  else
    SWAPFILE="/swapfile-studio"
    info "  creando swap de 16 GB en $SWAPFILE (en SSD si / es SSD)"
    run $SUDO fallocate -l 16G "$SWAPFILE"
    run $SUDO chmod 600 "$SWAPFILE"
    run $SUDO mkswap "$SWAPFILE" >/dev/null
    run $SUDO swapon "$SWAPFILE"
    if ! grep -q "$SWAPFILE" /etc/fstab 2>/dev/null; then
      run $SUDO sh -c "echo '$SWAPFILE none swap sw 0 0' >> /etc/fstab"
    fi
    ok "swap listo y persistente (fstab)"
  fi
  # --- OOMPolicy ---
  if systemctl show tigervnc.service -p OOMPolicy 2>/dev/null | gx continue; then
    ok "OOMPolicy=continue ya aplicado"
  else
    # localiza la unidad de la sesión (xrdp o vnc)
    UNIT=""
    for u in tigervnc.service xrdp.service xrdp-sesman.service; do
      systemctl list-unit-files "$u" >/dev/null 2>&1 && systemctl cat "$u" >/dev/null 2>&1 && { UNIT="$u"; break; }
    done
    UNIT="${UNIT:-tigervnc.service}"
    info "  unidad de sesión detectada: $UNIT"
    run $SUDO mkdir -p "/etc/systemd/system/$UNIT.d"
    run $SUDO cp "$REPO_DIR/examples/systemd-oom-policy.conf" "/etc/systemd/system/$UNIT.d/oom.conf"
    run $SUDO systemctl daemon-reload
    ok "OOMPolicy=continue → si Studio OOM, muere Studio y el escritorio vive"
    warn "los procesos de la sesión se marcan como protegidos al reconectar"
  fi
fi

# ------------------------------------------------------------------ 10. DRI3
step "10. DRI3 en la sesión (se instruye, NO se automática)"
XORG="/etc/X11/xrdp/xorg.conf"
if [ -r "$XORG" ] && grep -q 'Option "DRI3"' "$XORG" 2>/dev/null; then
  ok "DRI3 ya habilitado en $XORG"
elif [ -r "$XORG" ]; then
  warn "falta DRI3 en $XORG — es OBLIGATORIO para el modo directo (§5a)"
  info "    Añade  Load \"glamoregl\"  en Section \"Module\""
  info "    y      Option \"DRI3\" \"1\"  en Section \"Device\""
  info "    guía completa: $REPO_DIR/examples/xrdp-DRI3-snippet.conf"
else
  info "  no encuentro $XORG (¿sesión distinta de xrdp?)"
  info "  sin DRI3 usarás llvmpipe → ver README §5 (xrdp) o §5b (Xorg paralelo)"
fi
info ""
info "  Tras editarlo: desconecta y vuelve a conectar la sesión, y comprueba:"
info "    xdpyinfo | grep DRI3        # debe salir DRI3"
info "    glxinfo -B | grep renderer  # debe decir V3D, NO llvmpipe"

# ------------------------------------------------------------------ resumen
step "Listo"
cat <<RESUMEN
  Siguientes pasos:

    1. Si cambiaste grupos o DRI3 → reconecta tu sesión gráfica.

    2. Lanza Studio (descarga los paquetes la primera vez):
         DISPLAY=\$DISPLAY ./studio.sh

    3. Comprueba que usas la GPU y no software:
         ./studio.sh status
         glxinfo -B | grep renderer      # → V3D 7.1.10.2
         vulkaninfo --summary | grep deviceName

    4. Abre un place y verifica el editor 3D:
         DISPLAY=\$DISPLAY vinegar run /ruta/al/place.rbxl

  Documentación completa:  README.md
  Créditos y licencias:    CREDITS.md
  Ejemplos de configs:     examples/
RESUMEN
[ "$DRY_RUN" -eq 1 ] && warn "recuerda: esto fue un DRY-RUN, no se cambió nada"
exit 0

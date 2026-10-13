#!/bin/bash
# =====================================================================
# webview-env.sh — LÍMITE DE MEMORIA PARA WebView2 (Chromium) EN STUDIO
# ---------------------------------------------------------------------
# Problema: al abrir Studio, los procesos msedgewebview2.exe se comen
# ~8,3 GB de 14,7 GB totales (57 %) — más que el propio Studio.
# En una Pi con 16 GB y SIN swap eso disparaba el OOM killer, que mataba
# la sesión entera (OOMPolicy=stop) y "congelaba" la Pi.
#
# Por qué un wrapper: Vinegar ESCRIBE WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
# en internal/config/config.go:218 DESPUÉS de copiar [studio.env] del
# config.toml, así que configurarlo ahí sería ignorado. El launcher de
# Vinegar se antepone a argv, de modo que este script corre después y
# puede sobrescribir el valor antes de exec Wine.
#
# Configurado con:  [studio] launcher = ".../webview-env.sh"
# =====================================================================

# Conserva lo que Vinegar ya haya puesto (adaptable a renderer=Vulkan/GL)
# y si no hay nada, usa los valores por defecto de Vinegar.
BASE="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---in-process-gpu --use-angle=vulkan}"

# ---- límites de memoria / procesos ---------------------------------
# Menos procesos render: 5 → ~2-3. Chromium crea un render por origen;
# --process-per-site los agrupa por dominio.
LIMITS=" --renderer-process-limit=2"
LIMITS="$LIMITS --process-per-site"

# Tapa la heap V8 (por defecto puede llegar a varios GB por render).
# 1024 MB por render: suficiente para la home/box de Studio, evita
# que un solo render se coma 2,6 GB.
LIMITS="$LIMITS --js-flags=--max-old-space-size=1024"

# BackForwardCache guarda páginas COMPLETAS en RAM → un ahorro grande
# y sin efecto visible en Studio (no navegas entre páginas).
LIMITS="$LIMITS --disable-features=BackForwardCache,Translate,MediaRouter"

# Trabajo en segundo plano que solo consume CPU y memoria.
LIMITS="$LIMITS --disable-background-networking"
LIMITS="$LIMITS --disable-component-update"
LIMITS="$LIMITS --disable-sync"
LIMITS="$LIMITS --metrics-recording-only"
LIMITS="$LIMITS --no-first-run"

# Caché de disco contenida + no usar /dev/shm (irrelevante aquí).
LIMITS="$LIMITS --disk-cache-size=33554432"
LIMITS="$LIMITS --disable-dev-shm-usage"

export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="$BASE$LIMITS"

# Diagnóstico: deja rastro en el log de Vinegar si DEBUG_WEBVIEW=1
if [ -n "$DEBUG_WEBVIEW" ]; then
    echo "[webview-env] $WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS" >&2
fi

exec "$@"

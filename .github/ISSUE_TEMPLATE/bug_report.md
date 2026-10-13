---
name: "Bug / Studio no arranca o se congela"
about: "Alguien con una Pi 5 no consigue pasar de un punto de esta receta"
title: "[Pi 5] "
labels: ["bug"]
---

## ¿En qué punto se queda?

Marca **una** casilla (la de tu primer fallo) y pega el comando exacto:

- [ ] `./install.sh` se queda en la etapa ___
- [ ] `vinegar` no arranca / `wineboot` cuelga
- [ ] `cannot open shared object` / errores de `box64`
- [ ] **Ventana vacía, "no screens available" o error `c0000409`** → README §7
- [ ] **Se congela / pantalla negra tras unos minutos** → README §11
- [ ] `llvmpipe` en vez de `V3D` → README §5a
- [ ] Studio arranca pero el viewport no renderiza / es negro
- [ ] Otro: ___

## Entorno

| | |
|---|---|
| Modelo / RAM | Raspberry Pi 5 · ___ GB |
| Sistema | `lsb_release -ds` → |
| Kernel | `uname -r` → |
| Páginas | `getconf PAGE_SIZE` → |
| Sesión | xrdp · TigerVNC · Xorg directo · Xephyr · otra |
| Display | `echo $DISPLAY` → |
| box64 | `/usr/local/bin/box64 --version` → |
| Wine | `ls ~/Downloads/StudioEmulator/wine-test/` → |
| RAM libre | `free -h` → |
| Swap | `swapon --show` → |

## Salidas relevantes

```bash
# Pega aquí la salida de estos:
glxinfo -B | grep renderer
vulkaninfo --summary | grep -E 'deviceName|apiVersion'
systemctl show tigervnc.service -p OOMPolicy
dmesg -T | grep -i -E 'oom|killed'
```

```text
# Y aquí el log de Vinegar:
cat ~/Downloads/StudioEmulator/vinegar-run.log
tail -40 ~/.local/share/vinegar/appdata/Roblox/logs/*Studio*last.log
```

## Pasos previos

¿Qué habías hecho antes de que fallara? (cambios en `config.toml`, FFlags,
conexiones RDP/VNC simultáneas, cierre de sesión, actualización de Studio…)

## Comentarios

Contexto extra: qué probaste, qué viste en foros, etc.

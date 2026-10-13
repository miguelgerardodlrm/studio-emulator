# Roblox Studio en Raspberry Pi 5 — La receta que los foros no dan

Ejecutar **Roblox Studio (x86_64)** en una **Raspberry Pi 5 (ARM64)** usando
**emulación Wine + Box64**, con la **GPU VideoCore VII renderizando de verdad**
(vía el driver Vulkan `v3dv` de Mesa).

> **Estado: FUNCIONA, pero NO ES USABLE para desarrollar. Léelo antes.**
>
> Studio arranca, renderiza con la **GPU real (`V3D 7.1.10.2`)**, llega
> **logueado** y **abre places en el editor 3D** con viewport interactivo
> (verificado: 369.937 píxeles cambiaron al hacer zoom). Sin congelarse.
>
> ⚠️ **PERO LA CPU ESTÁ AL 100 %.** Medido con el editor abierto:
> **quedaba un 1,2 % de CPU libre**. El hilo principal de Studio va clavado
> al 100 % (emulación de una sola cadena), la UI web se come ~150 % y el VNC
> ~75 %. **No es un problema de configuración: es el techo del hardware.**
> Si buscas rendimiento, **esto no es para ti**. Métricas y alternativas en
> **§14**, y el techo en **§14.7**.
>
> ✅ **Lo que sí se puede recortar**: abre el place **directamente**
> (`studio.sh /ruta/al/place.rbxl`) y te saltas la pantalla de inicio, que es
> un **Chromium emulado** costeando un núcleo entero y 2,3 GB (**§14.1**).
>
> ⚠️ **La Pi se congelaba al abrir un place** — era un **OOM con cero swap**
> que, con `OOMPolicy=stop`, mataba también el servidor X. **Arreglado y
> verificado**: swap de 16 GB + `OOMPolicy=continue` + Studio como víctima del
> OOM (ver **§11**). El arreglo funciona, pero **no acelera**: ver §14.2.

---

## Instalación automática

En una Pi 5 con Ubuntu/Debian recién instalado, esto instala el stack entero:

```bash
git clone https://github.com/miguelgerardodlrm/studio-emulator.git
cd studio-emulator
./install.sh            # pide sudo en las etapas que lo necesitan
```

Es **idempotente**: puedes re-ejecutarlo y solo repite lo que falte. También:

```bash
./install.sh --dry-run       # solo imprime lo que haría, no toca nada
./install.sh --skip-box64    # ya tienes box64 compilado
./install.sh --skip-memory   # no toca swap ni systemd
./install.sh --help
```

**Lo que hace cada etapa** (cada una se salta si ya está hecha):

| # | Etapa | Tiempo |
|---|---|---|
| 1 | Dependencias de compilación y ejecución (`apt`) | rápido |
| 2 | **box64** desde source con `-DRPI5ARM64=1` | **~10-20 min** |
| 3 | `binfmt_misc` → los ELF x86_64 se ejecutan "solos" | rápido |
| 4 | `multiarch` amd64 + Vulkan `v3dv` | rápido |
| 5 | Grupos `video`/`render` para `/dev/dri` | rápido |
| 6 | **Wine 10.0-staging** de Kron4ek | ~2 min |
| 7 | **Vinegar** desde source | ~1 min |
| 8 | `config.toml` (con tus rutas reales) + `webview-env.sh` | rápido |
| 9 | **Memoria**: swap 16 GB + `OOMPolicy=continue` | ~1 min |
| 10 | **DRI3** en xrdp → *se instruye, no se automática* | manual |

> ⚠️ **Lo que NO automatiza**: descarga Roblox Studio (lo hace Vinegar en el
> primer arranque, con tu cuenta) ni la edición de `/etc/X11/xrdp/xorg.conf`
> (etapa 10 te dice exactamente qué dos líneas añadir —
> `examples/xrdp-DRI3-snippet.conf`). Es intencionado: pisar el `xorg.conf` de
> una sesión remota a ciegas puede dejarte sin escritorio.

Si prefieres hacerlo a mano, **§1 a §13** son el mismo proceso, paso a paso y
explicado. Las configs finales están en **[`examples/`](examples/)**.

---

## Inicio rápido (una vez instalado todo)

```bash
~/Downloads/StudioEmulator/studio.sh                       # → arranca Studio (pantalla de inicio)
~/Downloads/StudioEmulator/studio.sh /ruta/al/tu.rbxl      # → ARRANCA DIRECTO AL EDITOR ★
~/Downloads/StudioEmulator/studio.sh status                # → qué está corriendo, en qué modo, qué falta
~/Downloads/StudioEmulator/studio.sh stop                  # → cierra todo
```

> ★ **Conviene casi siempre.** La pantalla de inicio es un **Chromium emulado**:
> se come **un núcleo entero y ~2,3 GB** solo para mostrar un menú. Abrir el
> place directamente lo elimina por completo y llega al editor en ~12 s en vez
> de ~50 s. Detalle en **§14.1**.

Studio aparece como **ventana normal en tu propio escritorio XFCE**
(interactiva: clic + teclado). Si estás logueado en Roblox, arranca directamente
en la pantalla de inicio; si no, muestra el QR de login.

`studio.sh` es **idempotente** (re-ejecutar no rompe nada), **auto-detecta el
modo** de renderizado y se **auto-repara** (si Studio quedó como proceso
huérfano sin ventana, lo mata y lo relanza).

### Los dos modos (se elige solo)

| Modo | Cuándo | Qué hace |
|---|---|---|
| **DIRECTO** | Tu sesión X ya expone **DRI3** | Studio corre directo en tu sesión. Sin Xorg extra, sin VNC. **Modo normal.** |
| **PUENTE** | Tu sesión **no** tiene DRI3 | Xorg paralelo con DRI3 en `:20` + `x11vnc` + `vncviewer` en tu escritorio. **Respaldo.** |

Comprueba en qué modo estás:

```bash
studio.sh status
# [studio] modo : direct (display :1)
# [studio]   tu sesión ya expone DRI3 → sin Xorg paralelo ni VNC
```

<details>
<summary>Forzar un modo / ejecución manual</summary>

**Modo DIRECTO** (tu sesión con DRI3):

```bash
DISPLAY=:1 vinegar        # :1 = tu display (¡no :10!; verifica con echo $DISPLAY)
```

**Modo PUENTE** (sesión sin DRI3 — solo si `status` dice que hace falta):

```bash
# 1) Xorg con DRI3 (glamor sobre v3dv) en :20 — §5
sudo /usr/lib/xorg/Xorg.wrap :20 -config /tmp/xorg-dri3.conf \
    -logfile /tmp/xorg-dri3d.log -noreset -nolisten tcp &

# 2) Studio en ese display — §6/§7
DISPLAY=:20 vinegar &

# 3) Servir :20 por VNC, solo localhost — §10
x11vnc -display :20 -localhost -rfbport 5900 -forever -shared -nopw &

# 4) Visor EN TU SESIÓN (usa TU display, p.ej. :1)
DISPLAY=:1 vncviewer localhost:5900
```

**Por qué el puente:** `:20` es un servidor X distinto de tu sesión → tu XFCE
no lo pinta, y en una sesión sin DRI3 Studio no renderiza → *"graphics card is
not compatible"*. El puente VNC une ambas cosas (§10).

</details>

---

## 1. Por qué esto no está en los foros (y los callejones sin salida)

La mayoría de guías asumen que necesitas Wine *x86* tradicional, y fallan en
ARM64 por cuatro razones que aquí resolvemos una a una:

| Problema | Solución en esta receta |
|---|---|
| **Kombucha** (el Wine de Vinegar) **cuelga** en `wineboot` en ARM64 | Usar **Wine 10.0-staging de Kron4ek** (Kombucha = Wine 11.x, tiene un bug de `asprintf`/stat de 64-bit bajo box64 → issue ptitSeb/box64 **#3813**) |
| El **box64 de apt (0.3.8)** es demasiado viejo y tiene bugs de dynarec | Compilar **box64 master** con `-DRPI5ARM64=1` |
| **DXVK 3.x exige Vulkan 1.4 + `multiDrawIndirect`**; la GPU VideoCore VII **no tiene `multiDrawIndirect`** (límite de hardware) | **No usar DXVK.** Usar el renderer **Vulkan nativo de Studio** (`FFlagDebugGraphicsPreferVulkan`) que habla directo con `v3dv` (Vulkan 1.3) |
| El X-server de escritorio remoto **no tiene DRI3**, así que nada puede presentar superficies aceleradas → *"no screens available"* / *"graphics card not compatible"* | **Habilitar DRI3 en xrdp** (`Load "glamoregl"` + `Option "DRI3" "1"` en `/etc/X11/xrdp/xorg.conf`) — o como respaldo un Xorg paralelo con `modesetting`+glamor — y forzar un **virtual desktop** en Wine (`virtual_desktop = "1024x768"`) para que Qt detecte una pantalla |

---

## 2. Requisitos

- Raspberry Pi 5 (probado con **16 GB**), Ubuntu Server 26.04, kernel `7.0.0-1020-raspi`
- Páginas de **4 KB** (`getconf PAGE_SIZE` → `4096`). Box64 necesita 4K; el kernel de Pi 5 los usa.
- Conexión a internet (para bajar Wine, Studio y dependencias)
- Cuenta de Roblox (para iniciar sesión)

> **Nota sobre sesiones gráficas:** esto se probó en una sesión **XFCE virtual
> (xrdp)** sin monitor físico conectado. Si usas escritorio remoto, el paso de
> **DRI3 + virtual desktop** (secciones 5 y 6) es **obligatorio**, no opcional.

---

## 3. Instalar box64 (emulador de CPU x86_64 → ARM64)

Box64 traduce las instrucciones x86_64 del Studio a ARM64 a nivel de
retraducción dinámica (dynarec). El paquete de apt está desactualizado, así que
lo compilamos desde source:

```bash
sudo apt update
sudo apt install -y git cmake build-essential \
    libpthread-stubs0-dev libegl-dev libgl-dev libx11-dev

git clone https://github.com/ptitSeb/box64.git
cd box64
mkdir build && cd build

# -DRPI5ARM64=1 activa el tuning específico para el Cortex-A76 de la Pi 5
cmake .. -DRPI5ARM64=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo
make -j4
sudo cmake --install .        # instala en /usr/local/bin/box64
```

Verifica:
```bash
box64 --version
# Box64 arm64 v0.4.5 ... with Dynarec
```

### Registrar box64 en binfmt_misc (clave: los ELF x86_64 se ejecutan "solos")

`binfmt_misc` le dice al kernel: *"cualquier ELF x86_64, ejecútalo con box64"*.
Así `wine64` (que es x86_64) corre bajo box64 automáticamente.

```bash
# Registra el binario compilado (¡no el de apt!)
echo ':box64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/local/bin/box64:' | sudo tee /etc/binfmt.d/box64.conf
sudo systemctl restart systemd-binfmt
```

> ⚠️ **Trampa que sufrí:** el box64 de apt quedaba registrado en `/usr/bin/box64`
> y tenía prioridad. Asegúrate de que `/usr/lib/binfmt.d/box64.conf` (o
> `/etc/binfmt.d/`) apunte a **`/usr/local/bin/box64`** y reinicia binfmt.

---

## 4. Preparar multiarch amd64 + Vulkan de la GPU (v3dv)

El Studio y Wine son x86_64, así que necesitamos las libs **amd64** de Mesa que
hablan con la GPU. La GPU VideoCore VII expone **`v3dv`** (Vulkan 1.3, `apiVersion
1.3.335`) como dispositivo `V3D 7.1.10.2`.

```bash
sudo dpkg --add-architecture amd64
sudo apt update
sudo apt install -y vulkan-tools mesa-vulkan-drivers:amd64 \
    mesa-utils:amd64 wine64:amd64
```

Verifica que un binario x86_64 ve la GPU (bajo box64):
```bash
vulkaninfo --summary | grep -E 'deviceName|apiVersion'
#   deviceName = V3D 7.1.10.2
#   apiVersion = 1.3.335
```

> **Acceso a los nodos DRM:** el usuario necesita estar en los grupos `video` y
> `render` para abrir `/dev/dri/card1` y `/dev/dri/renderD128`:
> ```bash
> sudo usermod -aG video,render $USER
> # y para la sesión actual sin re-login:
> sudo setfacl -m u:$USER:rw /dev/dri/card0 /dev/dri/card1 /dev/dri/renderD128
> ```

---

## 5. DRI3 — ARREGLA la presentación acelerada

**Este es el paso que nadie documenta y sin el cual nada funciona.** Un X-server
de escritorio remoto (xrdp, VNC) típicamente **no expone DRI3**, y tanto `v3dv`
como `wined3d` **necesitan DRI3 para presentar** superficies. Sin él: `MESA: No
DRI3 support detected` y Studio muere con *"no screens available"* o muestra
*"Your computer's graphics card is not compatible"*.

### 5a. Opción recomendada: habilitar DRI3 en el propio xrdp

Añade/garantiza estas dos líneas en **`/etc/X11/xrdp/xorg.conf`**:

```xorg
Section "Module"
    Load "glamoregl"      # ← da DRI3 + aceleración GL sobre la GPU real
EndSection

Section "Screen"
    ...
    Option "DRI3" "1"
EndSection
```

Reinicia la sesión (desconecta y vuelve a conectar por RDP) y comprueba:

```bash
xdpyinfo | grep DRI3                       # debe aparecer DRI3
glxinfo -B | grep "renderer"               # debe decir V3D, NO llvmpipe
vulkaninfo --summary | grep deviceName     # debe listar V3D 7.1.10.2
```

> Con esto, **ya no hace falta el Xorg paralelo de §5b ni el puente VNC de
> §10**: `studio.sh` detecta que tu sesión tiene DRI3 y usa **modo directo**.

### 5b. Respaldo: Xorg paralelo con DRI3 (modo PUENTE)

Solo si tu sesión **no** puede exponer DRI3. Creamos un Xorg aparte usando el
display controller real (`card1` = `vc4-drm`) con `modesetting` + `glamor`:

```bash
cat > /tmp/xorg-dri3.conf <<'EOF'
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

# Arranca en :20 (necesita permisos de consola; usa el wrapper setuid)
sudo /usr/lib/xorg/Xorg.wrap :20 -config /tmp/xorg-dri3.conf \
    -logfile /tmp/xorg-dri3.log -noreset -nolisten tcp &
```

Verifica DRI3 + aceleración real (debe decir `V3D`, NO `llvmpipe`):
```bash
DISPLAY=:20 xdpyinfo | grep DRI3          # debe aparecer DRI3
DISPLAY=:20 glxinfo -B | grep "renderer"  # OpenGL renderer string: V3D 7.1.10.2
```

> Sin monitor físico, Xorg se queja *"Unable to find connected outputs"* y crea
> un framebuffer de 1024×768. **Es válido** — glxgears y Studio renderizan igual.

---

## 6. Instalar Vinegar + Wine 10.0 (Kron4ek)

**Vinegar** es el gestor oficial de Roblox Studio para Linux. Pero su Wine por
defecto (**Kombucha**, Wine 11.x) **cuelga en ARM64**. Usamos **Wine 10.0-staging
de Kron4ek** en su lugar.

```bash
# Descargar Wine 10.0-staging (amd64) — ¡¡¡la versión que funciona!!!
cd ~/Downloads/StudioEmulator/wine-test
curl -L -o wine10.tar.xz \
  "https://github.com/Kron4ek/Wine-Builds/releases/download/10.0/wine-10.0-staging-amd64.tar.xz"
tar -xf wine10.tar.xz
# → wine-10.0-staging-amd64/
```

Instalar Vinegar (desde source para poder parchearlo, ver §8):
```bash
sudo apt install -y golang-go libgtk-4-dev libadwaita-1-dev gettext libvulkan-dev
git clone https://github.com/vinegarhq/vinegar.git
cd vinegar && make && sudo make install   # → /usr/bin/vinegar
```

### Configurar Vinegar (`~/.config/vinegar/config.toml`)

```toml
debug = true

[studio]
wineroot = "/ABSOLUTE/PATH/wine-test/wine-10.0-staging-amd64"  # Wine 10.0 Kron4ek
renderer = "Vulkan"           # NO "DXVK" — ver §8
virtual_desktop = "1024x768"  # CRÍTICO: Qt necesita "ver" una pantalla
gamemode = false
discord_rpc = false
```

### Lanzar

```bash
DISPLAY=:20 vinegar
```

En la primera ejecución Vinegar:
1. Descarga e instala Studio (paquetes oficiales de Roblox → `~/.local/share/vinegar/versions/`)
2. Prepara el prefix de Wine
3. Instala **WebView2** (necesario para el login)
4. Lanza Studio

---

## 7. Por qué `virtual_desktop` es obligatorio (y por qué Studio "no ve pantallas")

Studio es una app **Qt5**. Al arrancar, Qt detecta las pantallas del sistema. En
un framebuffer sin monitor (o un X-server raro), Qt reporta **"no screens
available"** y Studio aborta con `c0000409` (__fastfail).

**notepad funciona igual** en ese mismo entorno → no es un problema de Wine ni
de box64, es la detección de pantallas de Qt.

La solución es arrancar Studio **dentro del escritorio virtual de Wine**
(`explorer /desktop=<uuid>,1024x768`). En ese modo Wine **sí** informa de una
pantalla correcta a Qt, y Studio crea su ventana. Vinegar lo hace con la opción
`virtual_desktop` (→ `bootstrapper_run.go` lanza `explorer /desktop=...`).

**Verificado:** con `virtual_desktop` activo, aparece la ventana `"Roblox Studio"
1024×768` y Studio arranca completamente.

---

## 8. Por qué NO usar DXVK (y cómo Vinegar quedó configurado)

**DXVK 3.x no puede funcionar en la Pi 5.** Requiere Vulkan 1.4 y, sobre todo,
la feature `multiDrawIndirect`, que la GPU **VideoCore VII no soporta** (límite de
hardware, confirmado en foros de Raspberry Pi y en el código de DXVK
`d3d11_device_features.cpp`). DXVK descarta `v3dv` con:

```
Found device: V3D 7.1.10.2 (V3DV Mesa 26.0.3)
   Skipping: Device does not support required feature 'multiDrawIndirect'
DXVK: No adapters found
```

Tampoco sirven DXVK 2.x ni versiones viejas (todas exigen `multiDrawIndirect`
para Feature Level 11_0).

**Solución:** usar el **renderer Vulkan nativo de Studio**
(`FFlagDebugGraphicsPreferVulkan`). Studio habla Vulkan directo con `v3dv`
(Vulkan 1.3), sin pasar por DXVK. Vinegar setea esto automáticamente cuando
`renderer = "Vulkan"` (escribe los FFlags en `ClientAppSettings.json`).

> Nota: Vinegar descarga DXVK 3.1 y lo inyecta en el directorio de Studio. Eso
> es inocuo porque Studio con FFlags de Vulkan no lo usa para el renderer
> principal. Si quieres Vinegar 100 % DXVK-free, parchea `internal/config/config.go`
> (`DXVKVersion = "2.7.1"` o vacío) y recompila — lo hice y funciona igual.

---

## 9. Verificación / Resultado

Tras ejecutar `studio.sh` (o `DISPLAY=<tu-display> vinegar`):

- ✅ Wine 10.0 crea el prefix y completa `wineboot`
- ✅ WebView2 se instala
- ✅ Studio descarga e instala sus paquetes
- ✅ Se mapea la ventana **"Roblox Studio"**
- ✅ El **UI Qt renderiza**: logo, botón "Sign in", **QR de login** (escaneable)
- ✅ El fondo 3D animado (cuadrícula perspectiva) se dibuja con la GPU
- ✅ **Logueado, pantalla de inicio completa**: *"Welcome, \<usuario\>"*,
  sidebar (New Experience / Recents / Templates…), banner 3D y miniaturas de
  experiencias — con `GL_RENDERER = V3D 7.1.10.2` (GPU real, no llvmpipe)
- ✅ **Editor 3D completo con un place abierto** (Gate 5): viewport renderizando
  la escena con texturas e iluminación, ribbon (Home/Avatar/UI/Script/Model),
  **Explorer** con el árbol de instancias, **Properties**, **Toolbox**,
  **Terrain Editor**, gizmo de orientación, command bar y botón **Run**

Comprobación rápida de que usas la GPU y no software:

```bash
glxinfo -B | grep renderer          # → V3D 7.1.10.2  (NO llvmpipe)
vulkaninfo --summary | grep device  # → V3D 7.1.10.2
studio.sh status                    # → modo: direct / Studio: sí
```

### 9a. Abrir un place y verificar el viewport 3D

`vinegar run <args>` **traslada los argumentos a Studio**
(`app.go → boot.run(args...)`), así que puedes abrir un place directamente:

```bash
ST=$(ls -d ~/.local/share/vinegar/versions/version-* | head -1)

# place que trae propio Studio (escena 3D real, sirve de prueba)
DISPLAY=:1 vinegar run "$ST/content/models/Thumbnails/AvatarCyclorama.rbxl"

# o tu propio place
DISPLAY=:1 vinegar run /ruta/al/place.rbxl
```

El log confirma la carga (`State: PlaceIdle`,
`PlaceSessionId: ...AvatarCyclorama.rbxl`) y el RSS sube a ~3,5 GB.

**Verificar que el viewport es vivo e interactivo** (no una imagen estática):
simula input con `xinput.py` (usa `libXtst` vía ctypes → **no necesita
`xdotool` ni sudo**) y compara capturas antes/después:

```bash
DISPLAY=:1 xwd -root -out /tmp/before.xwd && convert /tmp/before.xwd /tmp/before.png
DISPLAY=:1 python3 ~/Downloads/StudioEmulator/xinput.py :1 scroll 8   # zoom en el viewport
sleep 3
DISPLAY=:1 xwd -root -out /tmp/after.xwd  && convert /tmp/after.xwd  /tmp/after.png
compare -metric AE /tmp/before.png /tmp/after.png /dev/null           # píxeles distintos
```

> Resultado obtenido: **369.937 píxeles cambiados** al hacer zoom → el
> viewport 3D responde al input y se redesdibuja con la GPU. ✅

`xinput.py` acepta:

| Acción | Uso | Qué hace |
|---|---|---|
| `scroll [n]` | `python3 xinput.py :1 scroll 8` | hace clic para enfocar el viewport y hace zoom (rueda) |
| `scrollout` | `python3 xinput.py :1 scrollout` | zoom out |
| `click [x y]` | `python3 xinput.py :1 click 716 400` | clic en unas coordenadas (por defecto, centro del viewport) |
| `raise <título>` | `python3 xinput.py :1 raise "Wine Desktop"` | trae una ventana al frente (`XRaiseWindow`) |

> **`raise` es necesario** porque con `virtual_desktop` Studio vive *dentro* de
> la ventana **`<uuid> - Wine Desktop`**. Elevar `"Roblox Studio"` no sirve (es
> una ventana hija); hay que elevar **`"Wine Desktop"`**, que es la que gestiona
> el window manager. Útil para no perder Studio detrás de otras ventanas.
>
> Las coordenadas `VX, VY` están al inicio del script y conviene ajustarlas si
> cambia la resolución (la sesión xrdp puede variar: 1366×694, 1920×1200…).

> **Sin `xwd`/`convert` a mano:** `xwd`+`convert` vienen de `x11-apps` e
> `imagemagick` (§ver Troubleshooting). Para capturar **el contenido real** de
> un display usa `xwd -root` (raíz), no `xwd -id <ventana>`: con ventanas
> obstruidas `-id` devuelve los píxeles de la ventana que está encima.

---

## 10. Ejecutar y VER Studio en tu propio escritorio

`studio.sh` elige el modo solo (ver "Inicio rápido"). Los dos caminos:

### Modo DIRECTO — tu sesión ya tiene DRI3 (lo normal)

Si habilitaste DRI3 en xrdp (§5a), Studio corre **directo en tu sesión XFCE**,
como cualquier otra ventana. Sin Xorg extra, sin VNC, sin sudo:

```bash
DISPLAY=:1 vinegar     # o simplemente: studio.sh
```

> **Usa tu display real** (`echo $DISPLAY`), que no tiene por qué ser `:10`:
> xrdp asigna `:1`, `:2`… según la sesión. `studio.sh` lo detecta solo.

### Modo PUENTE — tu sesión no tiene DRI3 (respaldo)

Si el X de tu sesión no expone DRI3, Studio no puede presentar con la GPU:

```
libEGL warning: DRI3 error: Could not get DRI3 device
MESA: info: vulkan: No DRI3 support detected - required for presentation
→ Studio muestra: "Your computer's graphics card is not compatible with
                   Roblox's minimum system requirements"
```

> Eso es la famosa **"ventana azul"**: no es un fallo de Studio, es Studio
> detectando que no puede usar la GPU en esa sesión.

Solución: sirves un Xorg con DRI3 (`:20`) por VNC y abres el visor en tu sesión:

```bash
# 1) Xorg DRI3 en :20 (si no corre)     — §5b
# 2) Studio en :20                       — §6/§7
DISPLAY=:20 vinegar &

# 3) Servir :20 por VNC (solo local, sin contraseña)
x11vnc -display :20 -localhost -rfbport 5900 -forever -shared -nopw &

# 4) Visor EN TU SESIÓN (usa TU display, p.ej. :1)
DISPLAY=:1 vncviewer localhost:5900
```

Aparece la ventana **`pi:20 - TigerVNC`**, interactiva (clic, teclado, QR).

### ⚠️ Xephyr NO sirve como alternativa

Un X server anidado (Xephyr) **hereda las limitaciones del X anfitrión**: si tu
sesión no tiene DRI3, Xephyr tampoco → `OpenGL renderer string: llvmpipe` →
Studio rechazaría la GPU igual. Por eso el respaldo es por VNC (transporta los
frames ya renderizados por la GPU en `:20`), no por anidación.

---

## 11. La Pi se CONGELABA al abrir un place (OOM) — diagnóstico y arreglo

### Síntoma

Al abrir un place, la Pi entera se queda bloqueada y hay que reiniciarla.
Se sospecha de la sesión virtual… **pero no es la causa directa.**

### Causa real

Ocurrió el 12/10 a las 14:31:49. El rastro en el journal del arranque anterior:

```
Oct 12 14:31:49 kernel: RobloxStudioBet invoked oom-killer: gfp_mask=GFP_HIGHUSER_MOVABLE, order=0
Oct 12 14:31:49 kernel: Out of memory: Killed process 3352 (RobloxStudioBet)
                        total-vm:213145736kB  anon-rss:3682032kB
Oct 12 14:31:49 systemd[1]: tigervnc.service: The kernel OOM killer killed some processes in this unit.
Oct 12 14:31:50 tigervncserver[4226]: Killing Xtigervnc process ID 2306... success!
Oct 12 14:31:51 systemd[1]: tigervnc.service: Failed with result 'oom-kill'.
Oct 12 14:31:51 systemd[1]: tigervnc.service: Consumed 37min CPU over 18min wall clock, 15.2G memory peak.
```

La cadena, paso a paso:

| # | Qué pasó | Evidencia |
|---|---|---|
| 1 | La sesión picó a **15,2 GB de 15,96 GB** | `15.2G memory peak` |
| 2 | **`Swap: 0B`** → no había a dónde recurrir | `free -h` |
| 3 | El kernel dispara **OOM global** (no de cgroup) | `global_oom`, `order=0` |
| 4 | Mata a Studio (única víctima) | `Killed process 3352` |
| 5 | **`OOMPolicy=stop`** (default de systemd) → para la unidad **entera** | `Killing Xtigervnc process ID 2306` |
| 6 | Murió el servidor X → **pantalla congelada** | `Failed with result 'oom-kill'` |

> **¿Es por ser una sesión virtual?** No en cuanto a consumo: `Xtigervnc` solo
> usaba 137 MB. Lo que ocurre es **arquitectónico**: todo el escritorio vive en
> **una sola unidad de systemd** (`tigervnc.service`) y, con `OOMPolicy=stop`,
> **un OOM de Studio mata también al servidor X**. En una sesión física el mismo
> OOM mataría a Studio y el escritorio seguiría vivo.
> El desencadenante de fondo sí es de memoria: **pico + cero swap.**

### Qué se veía en el volcado (y una trampa de diagnóstico)

Zona de memoria en el instante del OOM — la caché de ficheros ya estaba al
mínimo, el kernel había reclaimado todo lo que podía:

```
Normal free:70744kB  min:70824kB        ← libres POR DEBAJO del mínimo → OOM
  active_anon:  1.97 GB   inactive_anon:  9.70 GB   ← anónimo (no reclaimable sin swap)
  active_file:     6 MB   inactive_file:    18 MB   ← caché ya vacía
DMA    inactive_anon: 3.58 GB
```

Reparto por proceso (RSS del volcado):

| Proceso | RSS | |
|---|---|---|
| `RobloxStudioBet` | 3,52 GB | `total-vm = 203 GB` (VA que reserva box64) |
| **`msedgewebview2.exe` ×5** | **8,35 GB** | 2,61 + 2,14 + 1,58 + 1,54 + 0,48 |
| resto (opencode, wine, XFCE…) | ~1 GB | |

> ⚠️ **Trampa:** la **RSS duplica** las páginas compartidas entre procesos
> (Chromium comparte código e IPC). Para saber el consumo **real** usa **PSS**:
> `awk '/^Pss:/{print $2}' /proc/<pid>/smaps_rollup`. Con PSS, WebView2 son
> **4,04 GB**, no 10. El RSS sirve para orientar, **no** para sumar.

### Arreglos aplicados

#### 1. Swap de 16 GB en el SSD ← el que evita la congelación

El disco es `/dev/sda2` (RTL9210C, `ROTA=0`, 883 GB libres) → swap barato y rápido.

```bash
sudo fallocate -l 16G /swapfile-studio
sudo chmod 600 /swapfile-studio
sudo mkswap /swapfile-studio
sudo swapon /swapfile-studio
echo '/swapfile-studio none swap sw 0 0' | sudo tee -a /etc/fstab
```

> Sin swap, cualquier pico es un OOM **instantáneo e inevitable**: la memoria
> anónima no se puede reclaimar, así que el kernel no tiene más opción que
> matar procesos. El swap convierte *"se congela"* en *"va lento pero sigue"*.
> **Verificado tras reinicio:** el swap revivió solo desde `fstab`. ✓

#### 2. `OOMPolicy=continue` → la sesión sobrevive a un OOM de Studio

⚠️ **`systemctl set-property ... OOMPolicy` NO funciona** en systemd 259:
devuelve `Cannot set property OOMPolicy, or unknown property`. Hay que usar un
drop-in:

```bash
sudo mkdir -p /etc/systemd/system/tigervnc.service.d
printf '[Service]\nOOMPolicy=continue\n' | sudo tee /etc/systemd/system/tigervnc.service.d/oom.conf
sudo systemctl daemon-reload
systemctl show tigervnc.service -p OOMPolicy    # → OOMPolicy=continue
```

Ahora, si vuelve a haber un OOM, muere Studio pero **el escritorio no se para**.

#### 3. Marcar a Studio como víctima del OOM killer

La sesión se protege en caliente y Studio se marca como sacrificable:

```bash
for n in Xtigervnc xfce4-session xfwm4 xfce4-panel; do
  for p in $(pgrep -x $n); do echo -500 | sudo tee /proc/$p/oom_score_adj >/dev/null; done
done
```

`studio.sh` hace la parte de Studio (`mark_oom_victim`, **no necesita root**:
*bajar* el `oom_score_adj` exige privilegios, *subir* no) — pone `+500` a
`RobloxStudioBet`, `msedgewebview2` y `RobloxCrashHandler` al detectar la ventana.

> No se usa `systemctl set-property ... OOMScoreAdjust=` en la unidad porque se
> aplicaría **también a Studio** (heredaría el valor negativo) y anularía el efecto.

#### 4. Limitar la memoria de WebView2 (Chromium) — `webview-env.sh`

Chromium es, con diferencia, el mayor consumidor. Los flags:

```toml
# ~/.config/vinegar/config.toml
[studio]
launcher = "/home/pi/Downloads/StudioEmulator/webview-env.sh"
```

> **Por qué un wrapper y no `[studio] env`:** Vinegar hace
> `env := maps.Clone(c.Studio.Env)` (config.go:180) y **después** en la línea 218
> `env["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"] = "--in-process-gpu "` →
> **sobrescribe** lo que pongas en el config. El `launcher` se antepone a argv
> (`bootstrapper_run.go`), así que corre **después** y puede fijar el valor.

Flags que aplica (limite de renderers, heap V8, BFCache…):

```
--renderer-process-limit=2  --process-per-site
--js-flags=--max-old-space-size=1024
--disable-features=BackForwardCache,Translate,MediaRouter
--disable-background-networking  --disable-component-update  --disable-sync
--disk-cache-size=33554432  --disable-dev-shm-usage
```

**¿Se aplican? Sí** — Studio *lee* la variable de su entorno y se la pasa a
WebView2 como **argumentos de línea de comandos** (así funciona
`additionalBrowserArguments`). Verificable con:

```bash
tr '\0' ' ' < /proc/$(pgrep -f msedgewebview | head -1)/cmdline | tr -s ' '
# → ... --js-flags=--max-old-space-size=1024 --renderer-process-limit=2 ...
```

> Nota honesta: limitan el **número** de procesos (5 en vez de más) y la heap V8,
> pero el consumo **total apenas baja** (~4 GB PSS): la home de Studio es una web
> pesada. El efecto real de los cuatro arreglos es que **no se llega al OOM**.

### Verificación — repetir el caso que rompía todo

Mismo escenario (abrir `AvatarCyclorama.rbxl`) monitorizado cada 10 s:

```
t(s) | RAM used/free/avail MB  | swap  | webview
   0 | 10473 2685 5494         |    0  | 2.34 GB
  40 | 11641 1445 4326         |    0  | 3.06 GB
  90 | 13322  478 2645         |    0  | 7.76 GB
 100 | 13520  392 2447         |   79  | 8.30 GB   ← antes: AQUÍ mataba el OOM
 +40 | 10699 3163 5268         | 4081  |           ← el swap absorbe el pico
 +80 | 12904  434 3063         | 4591  |
```

Resultado:

- ✅ **Sin OOM** (antes: `Killed process` a los ~100 s)
- ✅ **Sesión viva**: `Xtigervnc` y `xfce4-session` presentes
- ✅ **Swap absorbió el pico** (0 → 4,6 GB) que antes era fatal
- ✅ **El place cargó** (`State: PlaceIdle`) y **el editor 3D renderiza**
- ✅ **8,9 GB disponibles** tras estabilizarse (PSS real: WebView2 4,04 GB + Studio 0,91 GB)

> **Comprobación persistente tras reinicio:** el 12/10 la Pi se reinició a las
> 16:24 y al arrancar ya estaban el swap (desde `fstab`), `OOMPolicy=continue`
> (drop-in) y el `launcher`. ✓

---

## 12. Problemas conocidos / trabajo pendiente

- **Cuando Studio sale, deja un proceso huérfano.** El cierre es **limpio** (el
  log dice *"About to exit the application, doing cleanup"* / *"exit
  LifecycleManager UserSession scope (standalone shutdown)"*), sin excepciones
  ni OOM — pero el proceso `RobloxStudioBet` **queda vivo reteniendo ~2 GB de
  RAM** con 0 % CPU y sin ventana. `pgrep` lo ve por "vivo", así que un
  lanzador ingenuo no lo relanzaría. `studio.sh` lo detecta
  (`studio.sh status` → `HUÉRFANO`) y lo mata antes de relanzar. A mano:
  ```bash
  pkill -x RobloxStudioBet
  ```
- **NO se cierra solo.** Verificado dos veces: 5+ min y **25 min**
  (`1498 s`, `StudioClose: 1488ms`) sin intervención. Los cierres observados
  (~3,4 min y ~13,75 min) no son deterministas → lo más probable es que fueran
  cierres manuales. Si observas cierres espontáneos, revisa el `*Studio*last.log`
  buscando `standalone shutdown` y compara timestamps.
- **Rendimiento.** La emulación + Wine + GPU integrada no será como un PC
  nativo; esperar tiempos de carga largos.
- **Kombucha no sirve en ARM64** (bug de 64-bit bajo box64). Si Vinegar intenta
  auto-descargarlo, ignóralo y forza `wineroot` a Wine 10.0.
- **box64 de apt es 0.3.8.** Usa siempre el compilado en `/usr/local/bin/box64`.

> **Nota sobre sudo/root:** en **modo directo** (§5a, sesión con DRI3) **no hace
> falta root para nada** — todo corre como usuario normal. Solo el **modo
> puente** (§5b) necesita root para arrancar el Xorg paralelo `:20`, y una sola
> vez por boot. `studio.sh` usa `sudo -n` en todo, así que sin sudo NOPASSWD
> **falla rápido con un aviso** en lugar de bloquearse esperando la contraseña.

> **Nota sobre sudo/root:** solo hace falta root **una vez por boot**, para
> arrancar el Xorg DRI3 en `:20` (§5). Después todo el pipeline (Vinegar,
> Studio, x11vnc, visor) corre como usuario normal. `studio.sh` usa `sudo -n`
> en todo, así que si no hay sudo NOPASSWD **falla rápido con un aviso** en
> lugar de quedarse colgado esperando la contraseña.

---

## 13. Solución de problemas ( Troubleshooting )

| Síntoma | Causa | Fix |
|---|---|---|
| `DXVK: No adapters found` / `Skipping: multiDrawIndirect` | DXVK no sirve en VideoCore VII | Usa `renderer = "Vulkan"` (nativo) |
| `Cannot create window: no screens available` | Qt no ve pantalla | Activa `virtual_desktop = "1024x768"` (§7) |
| `MESA: No DRI3 support detected` | X-server sin DRI3 | Habilita DRI3 en xrdp (§5a) o Xorg modesetting+glamor (§5b) |
| `OpenGL renderer string: llvmpipe` | GL cae a software | Tu Xorg no está usando la GPU; revisa §5 y permisos DRM (§4) |
| `wineboot` cuelga para siempre | Kombucha/Wine 11.x | Usa Wine 10.0-staging de Kron4ek (§6) |
| `Permission denied` en `/dev/dri/*` | Usuario sin grupos | `usermod -aG video,render` + `setfacl` (§4) |
| **"ventana azul" / "graphics card is not compatible"** | Tu sesión X no expone DRI3 | Habilita DRI3 en xrdp (§5a) y reconnecta; o modo puente (§10) |
| Xephyr muestra llvmpipe | Hereda el X anfitrión sin DRI3 | No usar Xephyr; usar DRI3 nativo (§5a) o x11vnc (§10) |
| No se ve nada al ejecutar `DISPLAY=:20 vinegar` | `:20` es otro servidor X, tu XFCE no lo pinta | Lanza en tu sesión (modo directo) o `studio.sh` (§10) |
| `studio.sh status` → `HUÉRFANO` | Studio salió limpio pero dejó el proceso con ~2 GB | `studio.sh` lo mata y relanza solo, o `pkill -x RobloxStudioBet` (§12) |
| El script se queda esperando y pide contraseña | `sudo` interactivo | No debe pasar: usa `sudo -n`. Solo el Xorg paralelo `:20` necesita root (§5b) |
| `xdpyinfo` no detecta DRI3 aunque existe | bug clásico `grep -q` + `pipefail` (SIGPIPE → exit 141) | Usa `grep PATRÓN >/dev/null` sin `-q` en tuberías |
| Tras un **reinicio** ya no funciona | `/tmp` se vacía (conf y logs del Xorg paralelo) y los procesos mueren | En modo directo solo relanza `studio.sh`; en puente re-crea el conf (§5b, lo hace solo) |
| **La Pi se congela al abrir un place** | OOM con cero swap → `OOMPolicy=stop` mataba el servidor X | Swap 16 GB + `OOMPolicy=continue` + víctima OOM (**§11**) — ya no debe ocurrir |
| `systemctl set-property ... OOMPolicy` falla | En systemd 259 esa propiedad no es seteable en caliente | Drop-in en `/etc/systemd/system/tigervnc.service.d/oom.conf` (§11.2) |
| Poner `[studio] env` de WebView2 no hace nada | Vinegar **sobrescribe** `WEBVIEW2_...` en config.go:218 | Usar `launcher = ".../webview-env.sh"` (§11.4) |
| El display de la sesión **cambia** (`:1` → `:2`…) | xrdp asigna el número al conectar | No lo hardcodees: `echo $DISPLAY` o deja que `studio.sh` lo detecte |
| `version-XXXXXXXX` cambió | Studio se auto-actualiza; cambia el dir y las FFlags se reescriben | Ninguno: Vinegar renueva `ClientAppSettings.json` solo |
| `vinegar run <place.rbxl>` no abre el place | El subcomando `run` es el que traslada args a Studio | `DISPLAY=<d> vinegar run /ruta/place.rbxl` (§9a) |
| `xwd -id <ventana>` muestra otra ventana | Con la ventana obstruida devuelve los píxeles de la superior | Usa `xwd -root` (raíz del display) (§9a) |
| `xwd`/`convert` no existen | No instalados | `sudo apt install x11-apps imagemagick` |
| Studio "desaparece" tras otras ventanas | Vive en la ventana `<uuid> - Wine Desktop` | `python3 xinput.py :1 raise "Wine Desktop"` (§9a) o clic en su pestaña del panel |

---

## 14. Rendimiento real (lo que nadie te cuenta)

Esta sección existe porque **"funciona" no significa "es usable"**, y un README
que solo diga "FUNCIONANDO" miente por omisión. Todas las cifras de abajo están
**medidas en una Pi 5 de 16 GB**, no estimadas.

### La verdad de fondo

Box64 traduce cada instrucción x86_64 a ARM64 en tiempo de ejecución. Ese
traductor es **bueno** (ya va casi al máximo: `BIGBLOCK=2`, `CALLRET=2`,
`NATIVEFLAGS=1`, `BLEEDING_EDGE=1`), pero **no puede borrar la diferencia de
IPC** entre un Cortex-A76 ejecutando código nativo y uno ejecutando x86_64
traducido. Números redondos: **un emulador de CPU de este tipo cuesta entre
5× y 15× respecto a ejecutar lo mismo en hardware x86 nativo**.

Roblox Studio no es un programa ligero: es Qt + un motor 3D + (en la pantalla
de inicio) una página web completa. Traducir eso a ARM64 con unos núcleos de
2,4 GHz da como resultado **la fluidez de un portátil de hace ~15 años**.
**Esto no se arregla con flags**: es el coste del problema que se está
resolviendo.

### Métricas medidas (Pi 5 16 GB, sesión VNC, place abierto en el editor)

| Componente | CPU | RAM (PSS) | Notas |
|---|---|---|---|
| `RobloxStudioBet` (editor) | **~120 %** | **~2,6 GB** | Emulado por box64 |
| `msedgewebview2` (solo la **home**) | **~97 %** | **~2,3 GB** | Chromium **emulado** |
| `Xtigervnc` (recodifica la pantalla) | **30–90 %** | — | Cada frame que se dibuja se captura y recodifica |

Dos lecturas importantes de esa tabla:

1. **La pantalla de inicio cuesta casi tanto como todo el editor.** Es una
   página web corriendo dentro de Chromium, y ese Chromium **también va
   emulado**. 1 núcleo entero + 2,3 GB de RAM para mostrar un menú.
2. **El servidor VNC consume entre un tercio y un núcleo completo** solo
   recodificando la pantalla. Si ves Studio a través de VNC, esa CPU no llega
   a Studio.

### 14.1 Atajo que sí compensa: abre el place directamente

En lugar de arrancar Studio en su pantalla de inicio, abre el archivo del
place. Te saltas la home y con ella **todo el Chromium emulado**:

```bash
DISPLAY=:1 vinegar run /ruta/al/tu-place.rbxl
```

Medido con `AvatarCyclorama.rbxl`:

| | Arranque normal (home) | Arranque directo (place) |
|---|---|---|
| Instancias WebView2 | 5 | **0** |
| RAM de WebView2 | ~2,3 GB | **0** |
| CPU de WebView2 | ~97 % (1 núcleo) | **0 %** |
| RAM de Studio | ~1,7 GB | ~2,6 GB (absorbe la UI) |
| Hasta el editor usable | ~40–60 s | **~12 s** |

> **Regla práctica**: si trabajas en un sitio concreto, tenlo en un `.rbxl` y
> ábrelo directamente. Reserva la pantalla de inicio solo para cuando de verdad
> necesites el launcher.

### 14.2 El hallazgo más rentable: Studio estaba metido en swap

De todas las cosas medidas, **esta es la que más diferencia hace y la que
menos gente mira**. Con `perf-report.sh` (ver §14.6) salió esto, con Studio
abierto y **11 GB de RAM libres**:

```
Studio (PID 8468):  RAM 1.153 MB  ·  SWAP 2.298 MB
```

**Studio tenía más memoria en disco que en RAM.** Y no por falta de recursos:
había 11 GB libres. Lo que pasa es que el kernel, con `vm.swappiness=60` por
defecto, manda a swap las páginas "frías" de un proceso con un espacio de
direcciones enorme — y Studio, al ser una app de Windows emulada, tiene un
espacio virtual de decenas de GB.

El efecto es brutal y **se confunde fácilmente con "es que la emulación es
lenta"**: cada vez que Studio toca una página que está en disco, paga I/O.
Y eso que a 58 °C y con un SSD no es lentísimo… pero multiplicado por miles
de accesos convierte cualquier acción en un tirón.

**Comprueba si te pasa a ti:**

```bash
p=$(pgrep -x RobloxStudioBet)
awk '/^Pss:|^Swap:/{printf "  %s %d MB\n", $1, $2/1024}' /proc/$p/smaps_rollup
```

**Arreglo** (necesita `sudo`):

```bash
# 1. Trae todo de vuelta a la RAM (si hay RAM libre, es instantáneo)
sudo swapoff -a && sudo swapon -a

# 2. Que no vuelva a empujar páginas de Studio a disco
echo 10 | sudo tee /proc/sys/vm/swappiness

# 3. Persistente entre reinicios
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.d/99-studio.conf
```

Medido antes/después con el mismo escenario: CPU de Studio pasó de **50 % a
120 %** (estaba tirando de disco, no de CPU) y el swap de 5,8 GB a ~0,6 GB.
**No acelera la emulación — le quitaste el freno de disco que la tapaba.**

> **⚠️ Corrección honesta (oct 2026).** Este apartado se escribió afirmando que
> este arreglo "aceleraba" Studio, porque la CPU de Studio subió de 50 % a
> 120 % tras aplicarlo. **Eso era un error de lectura mía**: más CPU no es más
> rápido, significaba que Studio dejaba de esperar disco y pasaba a *trabajar*
> — al mismo ritmo de siempre. Quien lo aplicó **no notó diferencia**.
>
> El arreglo **es correcto y sí se aplica** (el swap de Studio pasó de 2.298 MB
> a 0 MB), pero **no mejora la fluidez**, porque el cuello de botella real es
> otro: **la CPU está al 100 % saturada**. Ver **§14.7**, que es donde está la
> verdad de todo esto.
>
> Se deja documentado igualmente porque **sí es una optimización real**: quita
> I/O de disco del camino y deja el sistema en un estado más limpio. Simplemente
> **no es lo que frena**.

### 14.3 Qué NO va a ayudar (y por qué)

Para que no pierdas el tiempo probando cosas que suenan bien y no sirven:

| Idea | ¿Por qué no sirve? |
|---|---|
| Subir los flags de dynarec | `BIGBLOCK`, `CALLRET`, `NATIVEFLAGS` y `BLEEDING_EDGE` **ya están al máximo por defecto** en el build `RPI5ARM64`. |
| Forzar el gobernador a `performance` | Medido: los 4 núcleos ya van a **2,4 GHz** (máximo) y la CPU está a 58 °C sin throttling. |
| Añadir más RAM / más swap | **No es un problema de memoria**. Con el editor abierto quedaban 9 GB libres y el swap al 4 %. |
| Compilar box64 con otras optimizaciones | El cuello de botella es la traducción de instrucciones, no la compilación. |
| Usar DXVK para ir más rápido | Ya está descartado de raíz: exige `multiDrawIndirect`, que el VideoCore VII no soporta (**§8**). |

### 14.4 Qué sí puede mejorar algo (margen real, no milagros)

- **Abre places directamente** (§14.1) — la única mejora grande y gratis.
- **Reduce lo que Studio dibuja**: viewport pequeño, calidad de sombras al
  mínimo, sin *shadows* / *lighting* en el editor. Aliviar el 3D libera CPU
  que va emulada.
- **Cierra la home web si ya la usaste**: los `msedgewebview2` **se quedan
  huérfanos** reteniendo ~2 GB. `studio.sh status` te avisa (`stale`), y
  `pkill -x RobloxStudioBet` los limpia.
- **Baja la profundidad de color del VNC** si controlas su arranque: sobre
  `localhost` la compresión es CPU gastada en balde.
- **No uses Xephyr**: hereda las limitaciones del X anfitrión y acaba en
  llvmpipe (**§10**).

### 14.5 Entonces, ¿para qué sirve?

Si tu idea es **aprender, experimentar, tocar places pequeños o simplemente
comprobar que se puede**, funciona y es fascinante. Si tu idea es **desarrollar
un juego con soltura en una Pi**, no: para eso necesitas hardware x86 o un
ordenador con GPU decente. Decirlo claro ahorra horas a todo el mundo.

### 14.6 Mídelo tú: `perf-report.sh`

Nada de lo anterior sirve si no sabes **qué es lo que frena en tu equipo**.
Este script lo mide y te da un veredicto:

```bash
DISPLAY=:1 ./perf-report.sh            # diagnóstico completo
DISPLAY=:1 ./perf-report.sh --idle 30  # mide el redibujado en reposo 30 s
```

Lo que separa (porque se confunden entre sí):

| Mide | Por qué importa |
|---|---|
| **CPU de Studio y de WebView2** | La home web es Chromium **emulado**: suele costar tanto como el editor entero (§14.1) |
| **CPU de Xtigervnc** | Cada frame que Studio dibuja se captura y recodifica: suele comerse 0,6–0,9 de un núcleo |
| **¿Studio está en swap?** | El caso más rentable de arreglar: si tiene más memoria en disco que en RAM, paga I/O por todo (§14.2) |
| **¿Se redibuja en reposo?** | Compara dos capturas sin tocar nada: si cambian píxeles, hay render continuo que el VNC re-codifica |
| **Gobernador, temperatura, RAM** | Descarta de un vazo las causas tontas (throttling, falta de RAM) |

> **Uso pensado para issues**: la plantilla de este repo pide estas cifras.
> Si reportas un problema, pega la salida de `perf-report.sh` — ahorra tres
> idas y venidas de preguntas y respuestas.

### 14.7 El techo real: la CPU está al 100 %

Esto es lo que hay que saber **antes** de invertir tiempo en esta receta, y lo
que este documento tardó demasiado en decir claro.

Medido con **el editor abierto y un place cargado**, en una Pi 5 de 16 GB:

```
usr 95,39 %   sys 3,29 %   IDLE 1,23 %
```

**Queda un 1,2 % de CPU libre.** Ni un núcleo. Y el reparto:

| Consumidor | CPU | ¿Evitable? |
|---|---|---|
| Studio (hilo principal, emulado) | **100 %** — clavado | No |
| WebView2 ×2 (UI de Studio) | ~150 % | **No del todo** |
| Xtigervnc (recodifica la pantalla) | ~75 % | Sí, pero necesita `sudo` |
| Sistema | ~30 % | No |

Tres conclusiones, y son definitivas:

1. **El hilo principal de Studio está al 100 %.** Es emulación de una sola
   cadena de ejecución: aunque le des más núcleos, esa cadena no va más rápido
   porque **no hay núcleos más rápidos**. Los Cortex-A76 van ya a 2,4 GHz.

2. **WebView2 vuelve.** Abrir el place directamente evita la *home*, pero la
   **propia interfaz de Studio es web** (Toolbox, Properties, ayudas). Dos
   instancias se comen ~150 %. Se puede recortar con `webview-env.sh`, pero no
   eliminarse sin romper la UI.

3. **El único desperdicio real es el VNC (~75 %)**, y lo arregla `sudo`. Pero
   incluso quitándolo entero, seguirías con el hilo principal de Studio al
   100 %.

#### ¿Y entonces?

**Con esta receta, Studio en una Pi 5 funciona pero no es usable para
desarrollar con soltura.** Es el resultado correcto del experimento — probar
que se puede — pero no una herramienta de producción.

Las opciones que quedan, siendo honestos sobre cada una:

| Opción | Coste | Veredicto |
|---|---|---|
| **Recortar el VNC** (color, codificación) | `sudo`, 30 min | Recupera ~0,7 de un núcleo. **Ayuda, no basta.** |
| **Recortar la UI web de Studio** (`webview-env.sh`) | bajo | Quita algo de los 150 %. **Ayuda, no basta.** |
| **Probar FEX-Emu en vez de Box64** | alto, ~2 h | Diferente JIT; a veces más rápido, a veces menos. **Sin garantías** — hay que medir. |
| **Aceptar el techo** | 0 | Es lo que recomiendo si buscabas rendimiento. |

> **Consejo de quien ya lo midió**: si lo que quieres es *usar* Studio, usa un
> ordenador con GPU. Si lo que quieres *aprender* — emulación, Box64, Wine,
> Vulkan en ARM — esto es fascinante y funciona. Son objetivos distintos, y
> confundirlos cuesta muchas horas.

---

## Estructura de archivos usada

**Lo que hay en este repositorio** (lo puedes clonar tal cual):

```
studio-emulator/
├── README.md                # este archivo
├── install.sh               # INSTALADOR — instala todo el stack (idempotente)
├── studio.sh                # LANZADOR AUTO (detecta modo directo/puente, §10)
│                            #   acepta un .rbxl → va directo al editor (§14.1)
├── webview-env.sh           # límite de RAM de WebView2, vía [studio] launcher (§11.4)
├── xinput.py                # simula clics/zoom vía libXtst (§9a, sin xdotool)
├── perf-report.sh           # MIDE a dónde se va la CPU — diagnostica tu equipo (§14.6)
├── examples/                # configs descargables, cada una con su "dónde va"
│   ├── README.md            #   qué es cada fichero (+ por qué NO hay FFlags)
│   ├── vinegar-config.toml  #   ~/.config/vinegar/config.toml   (§6)
│   ├── binfmt-box64.conf    #   /etc/binfmt.d/box64.conf        (§3)
│   ├── systemd-oom-policy.conf  # /etc/systemd/system/.../oom.conf (§11.2)
│   └── xrdp-DRI3-snippet.conf   # 2 líneas para /etc/X11/xrdp/xorg.conf (§5a)
├── CREDITS.md               # autores y licencias de todo el stack
├── LICENSE                  # MIT (solo lo de este repo — ver CREDITS.md)
└── .github/ISSUE_TEMPLATE/  # plantilla al reportar problemas
```

**Lo que se genera aquí al seguir el README** (no está en git, ver `.gitignore`):

```
~/Downloads/StudioEmulator/
├── box64-src/               # box64 compilado (→ /usr/local/bin/box64)
├── vinegar-src/             # Vinegar compilado (→ /usr/bin/vinegar)
├── wine-test/
│   └── wine-10.0-staging-amd64/   # Wine Kron4ek (¡el que funciona!)
└── *.log                    # logs de Vinegar (several MB, solo depuración)

~/.config/vinegar/config.toml                 # configuración de Vinegar
~/.local/share/vinegar/versions/version-*/    # Studio instalado
~/.local/share/vinegar/prefixes/studio/       # prefix de Wine
/tmp/xorg-dri3.conf                           # Xorg con DRI3 (§5b, solo modo puente)
/etc/X11/xrdp/xorg.conf                       # DRI3 de la sesión xrdp (§5a)
```

> El `ClientAppSettings.json` de Studio **no está en el repo**: lo **genera**
> Vinegar a partir de `renderer = "Vulkan"`. Ver `examples/README.md`.

---

## Créditos

Este proyecto no es un emulador escrito desde cero: es una receta que combina
el trabajo de muchos. **[CREDITS.md](CREDITS.md)** tiene la tabla completa.
Resumen:

| Proyecto | Qué aporta | Licencia |
|---|---|---|
| **[Box64](https://github.com/ptitSeb/box64)** | Traduce y JITea x86_64 → ARM64 | MIT |
| **[Wine](https://www.winehq.org/)** (builds de [Kron4ek](https://github.com/Kron4ek/Wine-Builds)) | Capa Win32 sobre Linux | LGPL-2.1+ |
| **[Vinegar](https://codeberg.org/vinegarhq/vinegar)** | Bootstrap y arranque de Studio en Linux | GPL-3.0 |
| **[Mesa](https://gitlab.freedesktop.org/mesa/mesa) `v3dv`** | Driver Vulkan de la GPU VideoCore VII | MIT |
| **[xrdp](https://github.com/neutrinolabs/xrdp)** / **[TigerVNC](https://github.com/TigerVNC/tigervnc)** | Sesión de escritorio remota | Apache-2.0 / GPL-2.0 |

**[Roblox Studio](https://create.roblox.com/)** es propiedad de **Roblox
Corporation** y **no se redistribuye aquí**: se descarga desde sus servidores
al ejecutar Vinegar. Este proyecto no está afiliado a Roblox.

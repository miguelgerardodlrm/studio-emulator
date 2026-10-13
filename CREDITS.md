# Créditos y agradecimientos

Este proyecto **no es un emulador escrito desde cero**: es una receta que
combina el trabajo de muchas personas. Sin ellas esto no existiría.

> Este repositorio solo contiene los **scripts, la documentación y las configs**
> escritos para este proyecto. **No redistribuye** el código de ningún
> proyecto listado abajo: cada uno se instala desde su fuente oficial siguiendo
> el README. Verifica siempre la licencia vigente en el repositorio de cada
> proyecto.

## El stack que hace posible todo

| Proyecto | Autoría | Qué aporta aquí | Licencia |
|---|---|---|---|
| **[Box64](https://github.com/ptitSeb/box64)** | ptitSeb y colaboradores | El corazón: traduce y JITea ELF **x86_64** a ARM64. Sin esto, Wine no arranca en una Pi. | **MIT** *(verificada en su `LICENSE`)* |
| **[Wine](https://www.winehq.org/)** | Proyecto Wine | Capa de compatibilidad Win32 sobre Linux. Usamos **10.0 staging** (builds de [Kron4ek](https://github.com/Kron4ek/Wine-Builds)), porque 11.x cuelga en `wineboot` bajo box64. | **LGPL-2.1+** |
| **[Vinegar](https://codeberg.org/vinegarhq/vinegar)** | [vinegarhq](https://github.com/vinegarhq) | El orquestador: bootstrap, prefix, FFlags, WebView2 y arranque de Studio en Linux. Compilado desde source para esta receta. | **GPL-3.0** *(verificada en su `LICENSE`)* |
| **[Mesa](https://gitlab.freedesktop.org/mesa/mesa) — driver `v3dv`** | Broadcom / Mesa | El driver **Vulkan** de la GPU VideoCore VII. Es lo que permite renderizar de verdad en vez de llvmpipe. | **MIT** |
| **[DXVK](https://github.com/doitsujin/dxvk)** | doitsujin | Traduce D3D → Vulkan. **No se usa aquí** (exige `multiDrawIndirect`, que el VideoCore VII no soporta), pero se documenta como callejón sin salida. | zlib/libpng |
| **[Qt](https://www.qt.io/)** | The Qt Company | Framework de la UI de Studio. Sus límites con pantallas virtuales motivan `virtual_desktop`. | LGPL |

## Entorno y sesión

| Proyecto | Qué aporta aquí | Licencia |
|---|---|---|
| **[xrdp](https://github.com/neutrinolabs/xrdp)** | Sesión de escritorio remota. Su `xorg.conf` es donde se habilita DRI3 (§5a). | Apache-2.0 |
| **[TigerVNC](https://github.com/TigerVNC/tigervnc)** | Servidor VNC y visor; alternativa en modo puente (§5b). | GPL-2.0 |
| **[XFCE](https://xfce.org/)** | Window manager de la sesión usada para las pruebas. | GPL-2.0+ |
| **[GTK](https://www.gtk.org/) / GLib** | UI de Vinegar. | LGPL-2.1+ |
| **[Go](https://go.dev/)** | Lenguaje en el que está escrito Vinegar. | BSD-style |

## El software que emulamos

**[Roblox Studio](https://create.roblox.com/)** es propiedad de
**Roblox Corporation** y se distribuye bajo sus propios términos.
Este proyecto **no redistribuye** Studio ni sus recursos: se descarga desde los
servidores de Roblox en tiempo de ejecución, tal y como haría un usuario
normal, y solo se ejecuta en la máquina del propio usuario.

Roblox, Roblox Studio y sus logos son marcas de Roblox Corporation. Este
proyecto **no está afiliado, patrocinado ni respaldado** por Roblox
Corporation.

## Agradecimientos

- A **ptitSeb** y a la comunidad de **box64**: mantener un traductor de
  instrucciones tan completo y rápido es un trabajo enorme.
- Al equipo de **Vinegar** por hacer que Roblox funcione en Linux sin parchear
  el cliente.
- A **Kron4ek** por mantener builds de Wine fiables y bien etiquetados.
- A los desarrolladores de **v3dv**, sin los cuales la GPU de la Pi seguiría
  sin soporte Vulkan.
- A quienes documentan estos callejones en foros y issues — buena parte de
  este README son problemas que otros resolvieron primero y que aquí solo se
  han compilado en un orden comprobado.

---

Si eres autor de alguno de estos proyectos y quieres que se corrija o
amplíe algo que aparece aquí, **abre una issue** — se corregirá con gusto.

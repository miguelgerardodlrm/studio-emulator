# `examples/` — configs descargables

Cada fichero de aquí está comentado con **dónde va**, **cómo instalarlo** y
**por qué existe**. No hay que copiarlos a ciegas: lee el comentario de
cabecera.

| Fichero | Destino | Sección del README |
|---|---|---|
| `vinegar-config.toml` | `~/.config/vinegar/config.toml` | §6 |
| `binfmt-box64.conf` | `/etc/binfmt.d/box64.conf` | §3 |
| `systemd-oom-policy.conf` | `/etc/systemd/system/tigervnc.service.d/oom.conf` | §11.2 |
| `xrdp-DRI3-snippet.conf` | *no se copia*: indica dos líneas a añadir a `/etc/X11/xrdp/xorg.conf` | §5a |

## Nota sobre `ClientAppSettings.json`

**No lo encontrarás aquí, a propósito.** Es un fichero **generado**, no un
input.

Vinegar lo reescribe en cada arranque a partir de `renderer = "..."` de tu
`config.toml` (`applyFFlags()` en `bootstrapper_setup.go`):

```go
for _, avail := range renderers {
    isRenderer := avail == string(r)
    f["FFlagDebugGraphicsPrefer"+avail] = isRenderer
    f["FFlagDebugGraphicsDisable"+avail] = !isRenderer
}
```

Con `renderer = "Vulkan"` eso produce exactamente:

```json
{
  "FFlagDebugGraphicsPreferVulkan":  true,  "FFlagDebugGraphicsDisableVulkan":  false,
  "FFlagDebugGraphicsPreferD3D11":   false, "FFlagDebugGraphicsDisableD3D11":   true,
  "FFlagDebugGraphicsPreferD3D11FL10": false, "FFlagDebugGraphicsDisableD3D11FL10": true,
  "FFlagDebugGraphicsPreferOpenGL":  false, "FFlagDebugGraphicsDisableOpenGL":  true
}
```

Así que **no hace falta editar FFlags a mano**: pon `renderer = "Vulkan"` y
Vinegar se encarga. Si tu `ClientAppSettings.json` no se parece a lo de arriba,
algo falla — mira el log de Vinegar.

> Para flags *adicionales* que Vinegar no derive, existe
> `[studio.fflags]` en el `config.toml` (se fusionan antes de escribir).

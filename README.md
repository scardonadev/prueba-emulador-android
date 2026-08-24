# Captura de la URL de stream vía GitHub Actions (sin tocar tu PC)

Corre un emulador Android en un runner de GitHub (con KVM), instala el APK, arranca
Frida como root y captura la **URL/firma real** que el motor nativo Titan/Ranger genera
al reproducir — enganchando en el borde Java↔nativo y en los sockets (evita el TLS
embebido del `.so`). Todo corre en la nube; tu PC no interviene.

## Archivos

```
.github/workflows/capture-stream-url.yml   # el workflow
capture.sh                                 # orquesta dentro del emulador
driver.py                                  # spawnea el APK con Frida y vuelca el log
frida-hook.js                              # los hooks
```

## Puesta en marcha

1. **Crea un repo PRIVADO** en GitHub (no publiques el APK) y sube estos 4 archivos
   respetando las rutas (el `.yml` va en `.github/workflows/`).

2. **Provee el APK** (una de dos):
   - **Committéalo** como `app.apk` en la raíz del repo (GitHub admite hasta 100 MB),
     **o**
   - sube el APK a un enlace privado y crea el secret `APK_URL` (Settings → Secrets and
     variables → Actions) con esa URL; el workflow lo descarga.
   > Es el APK original instalable (el que decompilaste), no las carpetas `sources/`.
   > Verifica el package: si no es `com.lite.fczx`, pásalo en el input `package`.

3. **Lanza el workflow**: pestaña **Actions → capture-stream-url → Run workflow**.
   - 1ª corrida: deja `taps` vacío. Sirve para **ver las pantallas**.

4. **Descarga el artifact `capture`** y abre:
   - `screen_*.png` y `ui_*.xml` → mira en qué pantalla se quedó y las coordenadas de
     un título y del botón de **play**.
   - `frida.log` / `frida.filtered.txt` → ya podría traer la URL si algo reprodujo.

5. **2ª corrida con navegación**: en `taps` pon la secuencia de toques (coordenadas de
   los `ui_*.xml`) para abrir un video y darle play, p. ej.:
   ```
   540,900 540,1250 540,700
   ```
   (cada `x,y` se togglea una vez por ciclo de 20 s). Ajusta hasta que reproduzca.

6. Mándame **`frida.log`** (o `frida.filtered.txt`) y **`logcat.txt`**. Busco las líneas:
   - `ijk.setDataSource` → la URL que recibe el reproductor.
   - `HTTP:send` / `SSL_write@...` → el request real al CDN (ruta + firma).
   - `com.titan.ranger.*` → el JSON con `entries`/`media`/URI resuelta.
   Con eso reconstruyo la URL reproducible (o confirmo qué firma nativa falta).

## Notas / límites honestos

- **Traducción ARM**: el APK trae libs solo-ARM; por eso el AVD es `api-level 30`,
  `target google_apis`, `arch x86_64` (esa imagen ejecuta ARM por traducción).
- **Root**: `google_apis` (no *playstore*) permite `adb root`, necesario para frida-server.
- **Hooks Java** (`ijk.setDataSource`, `com.titan.ranger.*`) son fiables. Los **hooks
  nativos** de sockets pueden fallar parcialmente porque el código ARM corre traducido;
  por eso capturamos por varios frentes a la vez.
- Bloqueamos UDP 5333 para **empujar al motor al CDN HTTP** (capturable en claro). Si el
  log muestra que sigue por P2P, añade en `capture.sh` las IPs de trackers a dropear.
- La automatización del "dale play" es lo único que suele necesitar 1–2 iteraciones
  (por eso subimos screenshots + `ui_*.xml`).
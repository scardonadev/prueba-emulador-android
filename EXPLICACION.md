# Captura de la URL de stream — qué hacemos y por qué

> Documento de contexto para la fase de **reproducción**. Explica por qué montamos
> un emulador en GitHub Actions con Frida, qué intentamos capturar y qué haremos con
> el resultado. Complementa a `README.md` (que es la guía paso a paso para correrlo).

---

## 1. El objetivo

Estamos reconstruyendo la app de IPTV (mod *focuzapps*, portal MAGIS/Xuper) como una
**web app Next.js** (`../nextjs-portal-api`) que se comporta igual que el mod: se
registra como terminal nuevo, reclama la prueba gratis y muestra el catálogo real.

Todo eso **ya funciona con datos reales**:

| Función | Estado | Cómo se resolvió |
|---|---|---|
| Registro de terminal + prueba gratis | ✅ | `snToken → active → /v2/getFree` (free-auth) |
| Catálogo / Películas / Series / Kids | ✅ | `getColumnContents` + `getShelveData` con `columnType:"2"` |
| TV en vivo (cientos de canales) | ✅ | `/v6/getLiveData` |
| Búsqueda | ✅ | `searchByName` con `type:"0"` → `searchItemList` |

**Lo único que falta es la REPRODUCCIÓN** (obtener los bytes del video). Eso es lo que
esta carpeta intenta desbloquear.

---

## 2. Por qué la reproducción es un muro

Ya tenemos, server-side, todo el protocolo hasta el borde del stream:

```
startPlayVOD  ->  media_code + licencia firmada + subtítulos (URLs https reales)
getSlbInfo    ->  cdn_list firmado: main_addr + url_list(sign_type, token, ...) + play_params(P2P)
```

`getSlbInfo` con `type:"vod"`/`"live"` **sí devuelve** una lista de CDN real y firmada.
El problema es el **último paso**: la URL concreta del `.m3u8`/segmento la **arma y
firma un motor nativo**, no el cliente:

- **`libranger-jni.so`** (Titan/Ranger) es un **motor de entrega P2P-CDN**. Recibe el
  `cdn_list` + `play_params`, y por dentro:
  1. deriva la **ruta** del media a partir del `media_code`,
  2. calcula una **firma por-CDN** (`sign_type = cs | goog | cfl`),
  3. para el CDN primario usa **P2P** (`link=icdn`, trackers UDP), no HTTP directo.
- El `.so` además **trae su propio TLS embebido (NSS)** e ignora el CA del sistema →
  un `mitmproxy` normal **no** puede desencriptar su tráfico.

Prueba de ello: pedir directo a los hosts del `cdn_list` (probando decenas de rutas)
devuelve siempre **403** (rechaza la firma) o **404** (acepta la auth pero la ruta es
otra). O sea: **la ruta + la firma viven dentro del binario nativo.**

```
     Nosotros (server)                         Motor nativo (libranger-jni.so)
  ┌───────────────────────┐                  ┌──────────────────────────────────┐
  │ getSlbInfo (type=vod) │ ──cdn_list────▶ │ ruta(media_code) + firma(cs/goog/  │
  │  ✅ lo tenemos         │   play_params    │ cfl) + P2P(icdn)  ← CAJA NEGRA      │
  └───────────────────────┘                  └───────────────┬──────────────────┘
                                                              ▼
                                                   http(s)://cdn/....m3u8?firma
                                                        (esto es lo que falta ver)
```

---

## 3. Por qué capturar (y por qué en GitHub Actions)

La única forma de obtener esa URL final sin reimplementar el `.so` es **observar la app
reproduciendo de verdad** y leer la URL en el momento justo. Pero:

- **No queremos instalar el APK en el PC del usuario.**
- Su **VPS no puede** correr Android: sin módulo de kernel `binder` (redroid) y sin
  KVM anidado (QEMU).
- **Docker en Windows** tampoco de forma directa: el kernel de WSL2 no trae `binder`,
  y el APK es **solo-ARM** (necesita traducción en un Android x86).

**GitHub Actions** resuelve todo eso: los runners Linux tienen **KVM gratis**, así que
podemos arrancar un emulador Android acelerado, efímero y en la nube. Nada toca el PC.

### El truco para leer la URL: Frida en el borde, no en la red
Como el `.so` cifra su propio tráfico, no atacamos la red. En su lugar, con **Frida**
(instrumentación dinámica) leemos la URL **antes** de que se cifre / en la frontera
Java↔nativo:

- `IjkMediaPlayer.setDataSource(...)` → la URL que recibe el reproductor (nombres reales).
- `com.titan.ranger.*` (todos sus métodos) → el JSON `entries`/`media` y la URI resuelta.
- `send/write` de **libc** → el request HTTP **en claro** (para los CDN `http://`).
- `SSL_write` → el request HTTPS **en claro**, antes de encriptar.

Y para **empujar al motor al CDN HTTP** (capturable) en vez del P2P, bloqueamos por
firewall el puerto de los trackers (`udp/5333`).

---

## 4. Qué hace el workflow (paso a paso)

`.github/workflows/capture-stream-url.yml` en un runner `ubuntu-latest`:

1. **Habilita KVM** y arranca un emulador **API 30 · google_apis · x86_64**
   (esa imagen ejecuta las libs **ARM** del APK por traducción, y permite `adb root`).
2. Instala **frida-server** (root) y el **APK** (`app.apk`).
3. Bloquea `udp/5333` (trackers P2P) para forzar el **CDN HTTP**.
4. Lanza el APK con **Frida** (`driver.py` + `frida-hook.js`).
5. **Cierra el popup de inicio** ("Canal de difusión") y navega con D-pad hacia un
   video para darle **play** (parámetro `taps`, admite `key:N` y `x,y`).
6. Saca **screenshots + volcado UI + logcat** y sube todo como artifact `capture`.

> Nota Frida: usamos **frida-tools `<14` (rama 16.x)** porque Frida 17 rompió la API
> clásica (`Java` global, `Module.findExportByName`) que usan los hooks.

---

## 5. Qué buscamos en el resultado

En `capture/frida.log` (y su resumen `frida.filtered.txt`), las líneas clave:

| Etiqueta | Qué significa |
|---|---|
| `ijk.setDataSource` | La URL que se manda al reproductor (puede ser un proxy local o la real). |
| `HTTP:send` / `SSL_write@…` | El request real al CDN: **host + ruta + query firmada**. |
| `com.titan.ranger.*` | El JSON con `entries`/`media`/URI que el motor resolvió. |

Si aparece algo con `main_addr` + ruta + `sign_type`/`token`, **ahí está la URL**.

---

## 6. Qué haremos con la captura (dos desenlaces)

- **(A) La URL es un HLS HTTP firmado reutilizable.**
  Nuestro server ya sabe llamar a `getSlbInfo` y generar tokens frescos; si entendemos
  el patrón de ruta+firma, el server puede **construir la URL** y el web player
  (hls.js/Video.js) la reproduce. ➜ reproducción 100% web.

- **(B) Es P2P / firma solo-nativa.**
  Si la entrega depende del motor nativo (P2P `icdn` o firma que solo hace el `.so`),
  las salidas son: **portar la firma** del `libranger-jni.so` (RE nativa pesada) o
  montar un **gateway nativo** (correr el motor en un servidor y proxiar los bytes).

La captura nos dice **cuál de los dos** es, sin seguir adivinando.

---

## 7. Bitácora / estado

- ✅ Infra de captura funcionando (KVM, emulador, frida-server, `adb install Success`).
- ✅ La app arranca de verdad (package real: **`com.lite.fczx`**; `appId` de la API es
  `com.android.msandroid`, no confundir).
- ✅ **Frida 16.x + hooks OK**: cargan `com.titan.ranger.*` y capturamos HTTP/SSL en claro.
- ✅ Confirmado en el log: el **motor Titan inicializa** (`Init {work_path:.../app_luna}`,
  `OnSystemEvent app/net/key`), y ya vemos peticiones en claro: EPG live
  (`/epg/v2/live/app/utc0/26`) y la **config del P2P** del motor (`/resolve`,
  `/v2/inn/fetch`, `/zcfg`) → confirma entrega P2P.
- ⚠️ Navegar con D-pad a ciegas abrió el menú de cuenta ("My Account"), no un video.
  Cambio de estrategia: **solo cerrar el banner y dejar la app en su home**, tiempos
  cortos, y revisar screenshots para dar los taps exactos a un título.
- 🚧 **MURO IDENTIFICADO (geobloqueo por IP).** El hook de respuestas reveló que
  `snToken` da `returnCode:"0"` pero **`active` da `returnCode:"portal100024"` /
  `errorMessage:"设备所在区域为黑名单，栏目不可见"`** ("la región del dispositivo está
  en lista negra; el catálogo no es visible"). La app llama `config/get` y se queda en
  el spinner — nunca pide `getColumnContents`/`getSlbInfo` porque el portal ya dijo
  "tu región no ve nada". **No es entitlement ni `getFree`: es la IP de salida.**
  - Confirmado con `tools/probe-mod.js`: **VPS → `portal100024`** (bloqueado);
    **IP residencial (casa) → `active rc 0`**, `getFree` OK, **30.642 películas**,
    `startPlayVOD` con `media_code` + `license scheme=md5-01` (videoFormat `ts`, 720p),
    20 canales live. ⇒ El portal **bloquea toda IP de datacenter** (VPS y GH Actions);
    **solo pasan IPs residenciales**.
- ✅ **Solución (implementada en el workflow): túnel residencial.** El emulador de GH
  enruta su **egreso por tu IP de casa** mediante un **exit node de Tailscale corriendo
  en Docker en tu PC**. `capture.sh` levanta `tailscale up --exit-node=$EXIT_NODE`
  (inputs: `exit_node` + secret `TS_AUTHKEY`) tras instalar frida-server+APK y lo baja
  al salir. Así `active` pasa y el catálogo carga.
- ✅ **REPRODUCCIÓN CAPTURADA (túnel residencial):** con el exit node, la app provisiona
  (`active rc 0`), carga catálogo y **reproduce en vivo** (LGVIP La Gala, ~343-396 KB/S).
  Pipeline nativo completo capturado: `getSlbInfo` → `SetEntries` (auths con
  `main_addr=iu15fg7dn.rh6ngfv34.com`, `sign_type=cs`, `token`, `check_play_ip=true`,
  `client_ip=<IP residencial>`, `media_encrypted=0`) → `Open` (license `scheme=md5-01`,
  `media_code`, format `ts`, h264/aac) → `SetEnv` (P2P: trackers `:5333`,
  `transmit_protocol=http`, `link=icdn`) → `setDataSource("ijkhttphook:mem://127.0.0.1:PORT")`.
- 🧱 **VEREDICTO = (B), y más restrictivo de lo esperado. Tres muros para "URL en web":**
  1. **Entrega local `mem://127.0.0.1:PORT`** = protocolo propio de ijkplayer (memoria
     compartida), NO HTTP. El HTTP server local del motor (`Server: Ranger/4.9.4`) solo
     responde control (`/…snapinfo` → 503) → **no es proxiable como HLS**.
  2. **Motor P2P ARM invisible a Frida**: `libranger-jni.so` corre por traducción ARM
     (houdini); sus sockets **no** pasan por el `libc.so` x86 hookeado → `connect`/`send`/
     `PR_Write` no capturan nada del motor. (Confirmación del transporte CDN: pendiente vía
     `-tcpdump` a nivel de paquete, analizado en step posterior.)
  3. **Token atado a IP** (`check_play_ip=true` + `client_ip`), y **rota por sesión** →
     una URL reconstruida solo serviría desde la misma IP residencial.
- 💡 **Dato clave para el camino viable:** `media_encrypted=0` → los bytes que ijkplayer
  recibe son **MPEG-TS en claro** (h264/aac). El camino fiel a reproducción web NO es
  reconstruir la URL sino un **GATEWAY / RESTREAMER**: correr el motor en un host con IP
  residencial, **tap del TS que consume ijkplayer** (hook de lectura) → **FFmpeg → HLS**
  → navegador (hls.js). Requiere un Android por stream sobre IP permitida (infra real),
  pero no necesita RE de la firma `cs` ni descifrado.

---

## 8. Nota

Esto es **ingeniería inversa de una app que el usuario ya posee**, para entender su
mecanismo de entrega de video y evaluar si es reproducible en web. El APK va en un
**repo privado**; el emulador es efímero y en la nube.

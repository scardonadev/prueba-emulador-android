#!/usr/bin/env bash
# Corre DENTRO del step del emulador. Instala frida-server + APK, lanza la app con
# Frida, navega a una PELÍCULA y le da play para capturar la URL real del stream.
set -uxo pipefail

PKG="${PKG:-com.lite.fczx}"
DUR="${DUR:-120}"
mkdir -p capture

adb wait-for-device
adb root || true
sleep 3
adb wait-for-device

FV="$(python -c 'import frida; print(frida.__version__)')"
echo "frida $FV"
curl -fsSL -o fs.xz "https://github.com/frida/frida/releases/download/${FV}/frida-server-${FV}-android-x86_64.xz"
unxz fs.xz
adb push fs /data/local/tmp/frida-server
adb shell chmod 755 /data/local/tmp/frida-server
adb shell "nohup /data/local/tmp/frida-server >/dev/null 2>&1 &" || true
sleep 5

adb install -r -g app.apk || adb install -r app.apk || { echo "::error::install falló"; exit 1; }

# ── Túnel residencial (exit node Tailscale en tu PC) ─────────────────────────
# El portal bloquea TODA IP de datacenter (VPS y GH Actions -> portal100024,
# "设备所在区域为黑名单"). Solo pasan IPs residenciales. Enrutamos el EGRESO del
# runner (y por ende del emulador vía SLIRP) por tu IP de casa. Sin esto, `active`
# falla y el catálogo se queda en el spinner.
# Se levanta DESPUÉS de bajar frida-server + APK (esos usan la ruta directa, rápida)
# y se baja al salir (trap) para no tunelizar la subida del artifact.
if [ -n "${TS_AUTHKEY:-}" ] && [ -n "${EXIT_NODE:-}" ]; then
  echo "== Túnel Tailscale: exit node $EXIT_NODE =="
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up --authkey="$TS_AUTHKEY" --hostname=gh-capture \
    --exit-node="$EXIT_NODE" --exit-node-allow-lan-access --accept-routes || \
    echo "::warning::tailscale up falló; el emulador saldrá por la IP del runner (bloqueada)"
  trap 'sudo tailscale down >/dev/null 2>&1 || true' EXIT
  echo "IP de salida efectiva:"; curl -s --max-time 12 https://api.ipify.org || true; echo
else
  echo "::warning::sin TS_AUTHKEY/EXIT_NODE -> el emulador saldrá por la IP del runner (será bloqueada: portal100024)"
fi

# Forzar HTTP (opcional): bloquea los trackers P2P (udp/5333) para que el motor caiga a
# transmit_protocol=http y pida los segmentos al main_addr por HTTP -> capturable con los
# hooks connect/PR_Write/sendto. Si BLOCK_P2P!=true, deja la entrega P2P normal.
if [ "${BLOCK_P2P:-false}" = "true" ]; then
  echo "== Bloqueando P2P (udp/5333) para forzar HTTP =="
  sudo iptables -A OUTPUT -p udp --dport 5333 -j DROP || true
fi

# Toca el centro del primer nodo cuyo text coincida (insensible a mayúsculas).
tap_text() {
  local label="$1"
  adb shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1 || return 1
  adb pull /sdcard/u.xml /tmp/u.xml >/dev/null 2>&1 || return 1
  local b
  b=$(tr '>' '\n' < /tmp/u.xml | grep -i -m1 "text=\"$label\"" | grep -o 'bounds="\[[0-9,]*\]\[[0-9,]*\]"')
  [ -z "$b" ] && { echo "tap_text: no encontré '$label'"; return 1; }
  set -- $(echo "$b" | grep -o '[0-9]\+')
  local cx=$(( ($1 + $3) / 2 )) cy=$(( ($2 + $4) / 2 ))
  echo "tap_text '$label' -> $cx,$cy"
  adb shell input tap "$cx" "$cy"
}

# Driver de Frida: hace spawn del APK, carga el hook y captura DUR segundos.
python driver.py "$PKG" "$DUR" &
DRV=$!

# ── Navegación robusta a una PELÍCULA (VOD) ──────────────────────────────────
# El problema real: el popup "Canal de difusión / focuzapps" reaparece y se traga
# los taps. Solución: cerrarlo en bucle, tocar MOVIES por su texto y VERIFICAR que
# salimos de LIVE, luego abrir el primer póster por sus bounds. Sin depender de timing.
dump_ui() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1; }
snap() { # snap <etiqueta>: guarda screenshot + UI dump con nombre
  adb exec-out screencap -p > "capture/nav_${1}.png" 2>/dev/null || true
  dump_ui && cp /tmp/ui.xml "capture/nav_${1}.xml" 2>/dev/null || true
}
popup_up() { dump_ui && grep -qiE 'focuzapps|Canal de difusi|PRESIONA OK' /tmp/ui.xml; }
on_live()  { dump_ui && grep -qiE 'mFlMainLive|mLvChannelList|LGVIP' /tmp/ui.xml; }

# Toca el primer nodo clickable del ÁREA DE CONTENIDO (x1>420) con tamaño de póster.
tap_first_poster() {
  dump_ui || return 1
  local found
  found=$(tr '>' '\n' < /tmp/ui.xml | grep -i 'clickable="true"' \
    | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' \
    | while read -r b; do
        set -- $(echo "$b" | grep -oE '[0-9]+'); x1=$1;y1=$2;x2=$3;y2=$4
        w=$((x2-x1)); h=$((y2-y1))
        if [ "$x1" -gt 420 ] && [ "$w" -gt 140 ] && [ "$h" -gt 140 ] && [ "$y1" -gt 170 ]; then echo "$x1 $y1 $x2 $y2"; break; fi
      done)
  [ -z "$found" ] && return 1
  set -- $found; local cx=$(( ($1+$3)/2 )) cy=$(( ($2+$4)/2 ))
  echo "poster -> $cx,$cy"; adb shell input tap "$cx" "$cy"
}

# 0) La app ARM a veces cae al home (spawn de frida inestable). Si no está en
#    primer plano, la relanzo por el launcher.
sleep 16
fg=$(adb shell dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity)
if ! echo "$fg" | grep -qi 'com.lite.fczx'; then
  echo "app NO está en foreground ($fg) -> relanzo"
  adb shell monkey -p com.lite.fczx -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 10
fi

# 1) Cerrar el popup de inicio en bucle (aparece tarde y REAPARECE).
for i in $(seq 1 12); do
  if popup_up; then echo "popup -> cierro"; adb shell input keyevent 23 || true; sleep 1; adb shell input keyevent 4 || true; fi
  sleep 2
done
snap 0_home

# 2) Ir a MOVIES y VERIFICAR que dejamos LIVE (reintenta; recierra popup si vuelve).
for i in $(seq 1 6); do
  echo "intento MOVIES #$i"
  tap_text "MOVIES" || adb shell input tap 195 557
  sleep 5
  if popup_up; then adb shell input keyevent 23 || true; sleep 1; fi
  if ! on_live; then echo "salimos de LIVE (probable MOVIES)"; break; fi
done
snap 1_movies   # <<< ESTE es el dump clave de la grilla de películas

# 3) Si el usuario pasó TAPS, se ejecutan aquí (override manual del póster/play).
if [ -n "${TAPS:-}" ]; then
  j=0
  for t in $TAPS; do
    case "$t" in
      text:*)  tap_text "${t#text:}" || true; sleep 2 ;;
      key:*)   adb shell input keyevent "${t#key:}" || true; sleep 2 ;;
      sleep:*) sleep "${t#sleep:}" ;;
      *,*)     x="${t%,*}"; y="${t#*,}"; adb shell input tap "$x" "$y" || true; sleep 2 ;;
    esac
    j=$((j+1)); snap "step_$j"
  done
else
  # 4) Abrir el primer póster (por bounds).
  tap_first_poster || adb shell input keyevent 22
  sleep 8; snap 2_detail
  # 4b) Cerrar el coach-mark/tutorial ("Next"/mButton) que TAPA el botón Play.
  #     Puede tener varios pasos -> clic al mButton hasta que desaparezca.
  for i in $(seq 1 8); do
    dump_ui || break
    if grep -qiE 'com.lite.fczx:id/mButton|access the subtitles|You can now' /tmp/ui.xml; then
      b=$(tr '>' '\n' < /tmp/ui.xml | grep -i 'mButton' | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1)
      if [ -n "$b" ]; then set -- $(echo "$b" | grep -oE '[0-9]+'); adb shell input tap $(( ($1+$3)/2 )) $(( ($2+$4)/2 )) || true
      else adb shell input tap 432 883 || true; fi
      sleep 2
    else break; fi
  done
  snap 2b_ready
  # 4c) PLAY: NO usar CENTER (activaba el chip de género "Action" -> categoría).
  #     El "botón Play" es la VENTANA del reproductor (mFlRoot/mPlayerWindow).
  #     Tap DIRECTO a su centro, leído del dump (fallback 1695,265).
  # DEJA CERRAR EL MODAL del tutorial (animación) antes de tocar play.
  sleep 4
  for i in $(seq 1 4); do
    dump_ui || break
    grep -qiE 'com.lite.fczx:id/mButton|access the subtitles|You can now' /tmp/ui.xml || break
    b=$(tr '>' '\n' < /tmp/ui.xml | grep -i 'mButton' | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1)
    [ -n "$b" ] && { set -- $(echo "$b" | grep -oE '[0-9]+'); adb shell input tap $(( ($1+$3)/2 )) $(( ($2+$4)/2 )) || true; }
    sleep 2
  done
  sleep 2
  # 4d) PLAY: UN SOLO tap al icono de play (mIvPlayStatus). NO reintentar el mismo tap
  #     (un segundo tap PAUSA mientras bufferea = por eso fallaba). Sin CENTER (géneros).
  dump_ui
  pb=$(tr '>' '\n' < /tmp/ui.xml | grep -i 'mIvPlayStatus' | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1)
  [ -z "$pb" ] && pb=$(tr '>' '\n' < /tmp/ui.xml | grep -iE 'mFlRoot|mPlayerWindow' | grep -oE 'bounds="\[[0-9,]+\]\[[0-9,]+\]"' | head -1)
  if [ -n "$pb" ]; then set -- $(echo "$pb" | grep -oE '[0-9]+'); px=$(( ($1+$3)/2 )); py=$(( ($2+$4)/2 )); else px=1695; py=265; fi
  echo "tap PLAY (una vez) -> $px,$py"
  adb shell input tap "$px" "$py" || true
  sleep 12; snap 3_play   # deja que el player pase de banner->negro y empiece a bufferar

  # 4e) respaldo NO-pausante: si el ▶ sigue, abre en Full Screen (acción distinta,
  #     no togglea el play inline). Reintenta hasta 2 veces.
  for i in 1 2; do
    dump_ui
    grep -qi 'mIvPlayStatus' /tmp/ui.xml || { echo "sin boton play -> reproduce"; break; }
    echo "sigue ▶ -> Full Screen (272,574) intento $i"
    adb shell input tap 272 574 || true; sleep 10; snap "3_fullscreen_$i"
  done
  # 4f) deja BUFFERAR: aquí el motor pide getSlbInfo(vod) + segmentos (frida/pcap capturan).
  sleep 25; snap 3b_final
fi

# ¿Es viable un GATEWAY? El motor levanta un server local (mem://127.0.0.1:PORT y
# snapinfo_url http://127.0.0.1:PORT/...). Si ese server nos entrega un HLS/TS
# reproducible, un gateway = correr el motor y proxiar ese puerto. Lo probamos:
# adb forward runner:19000 -> emulador:PORT y hacemos GET a rutas típicas.
sleep 6
# Prioriza la play_url REAL de VOD (http://127.0.0.1:PORT/vod/0/MEDIA.m3u8); si no,
# cae al mem:// de live. El .m3u8 y sobre todo el .snapinfo (metadata del motor)
# pueden revelar el ORIGEN del media.
PLAYURL=$(grep -aoE 'http://127\.0\.0\.1:[0-9]+/vod/0/[A-Za-z0-9]+\.m3u8' capture/frida.log 2>/dev/null | head -1)
PORT=$(echo "$PLAYURL" | grep -oE ':[0-9]+' | head -1 | tr -d ':')
[ -z "$PORT" ] && PORT=$(grep -aoE 'mem://127\.0\.0\.1:[0-9]+' capture/frida.log 2>/dev/null | head -1 | grep -oE '[0-9]+$')
MEDIA=$(echo "$PLAYURL" | grep -oE '/vod/0/[A-Za-z0-9]+' | head -1 | sed 's#.*/##')
[ -z "$MEDIA" ] && MEDIA=$(grep -aoE '"media":"[^"]+"' capture/frida.log 2>/dev/null | head -1 | sed 's/.*:"//; s/"$//')
# un nombre de segmento por rango real que ijkplayer pidió (para probar el server local)
SEG=$(grep -aoE "/vod/0/${MEDIA}/[0-9]+-[0-9]+_[0-9]+~[0-9]+\.ts" capture/frida.log 2>/dev/null | head -1 | sed 's#.*/##')
{
  echo "motor local: PORT=${PORT:-?}  MEDIA=${MEDIA:-?}  SEG=${SEG:-?}"
  echo "play_url: ${PLAYURL:-?}"
  if [ -n "${PORT:-}" ]; then
    adb forward tcp:19000 "tcp:${PORT}" || true
    PATHS="vod/0/${MEDIA}.m3u8 vod/0/${MEDIA}.snapinfo vod/0/${MEDIA}.info vod/0/${MEDIA}/index.m3u8"
    [ -n "${SEG:-}" ] && PATHS="$PATHS vod/0/${MEDIA}/${SEG}"
    for path in $PATHS; do
      echo "=== GET /$path ==="
      curl -s -m 8 -D - -o "capture/ls_$(echo "$path" | tr '/.~' '___').bin" "http://127.0.0.1:19000/$path" 2>&1 || true
      f="capture/ls_$(echo "$path" | tr '/.~' '___').bin"
      echo "  (bytes: $(wc -c < "$f" 2>/dev/null || echo 0))"
      # si es texto (m3u8/snapinfo), muéstralo: puede traer la URL del ORIGEN
      case "$path" in *.m3u8|*.snapinfo|*.info) echo "  --- contenido ---"; head -c 1200 "$f" 2>/dev/null | tr -d '\000'; echo ;; esac
    done
  fi
} > capture/local_server.txt 2>&1

# Evidencia: screenshots + UI dump cada 10s.
CYCLES=$(( DUR / 10 )); [ "$CYCLES" -lt 1 ] && CYCLES=1
for i in $(seq 1 "$CYCLES"); do
  sleep 10
  adb exec-out screencap -p > "capture/screen_$i.png" 2>/dev/null || true
  if adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; then
    adb pull /sdcard/ui.xml "capture/ui_$i.xml" >/dev/null 2>&1 || true
  fi
done

wait "$DRV" || true
adb logcat -d > capture/logcat.txt 2>/dev/null || true
# Llaves TLS del NSS del motor (para descifrar guest.pcap en el step del pcap).
adb root >/dev/null 2>&1 || true; sleep 2
adb exec-out "cat /data/data/com.lite.fczx/sslkeys.log 2>/dev/null || cat /data/user/0/com.lite.fczx/sslkeys.log 2>/dev/null" > capture/sslkeys.log 2>/dev/null || true
# por si quedó en otra ruta, búscala
if [ ! -s capture/sslkeys.log ]; then
  F=$(adb exec-out "ls /data/data/com.lite.fczx/sslkeys.log /data/user/0/com.lite.fczx/sslkeys.log 2>/dev/null; find /data -name sslkeys.log 2>/dev/null" | head -1)
  [ -n "$F" ] && adb exec-out "cat $F" > capture/sslkeys.log 2>/dev/null || true
fi
echo "sslkeys.log: $(wc -l < capture/sslkeys.log 2>/dev/null || echo 0) lineas (>0 => NSS volcó llaves; descifraremos el pcap)"
# NOTA: el guest.pcap se analiza en un STEP POSTERIOR del workflow (tras apagar el
# emulador y volcar el buffer). Aquí saldría truncado.
grep -aiE 'http|m3u8|cdn|sign_type|token|main_addr|slb|ranger|titan|portalCore|startPlay|getSlb|connect|PR_Write|PR_Read|mem://|\.ts|entries|auths|links|JniHandler|PlayMedia|REPORT\.|OnReport|proxy' capture/frida.log 2>/dev/null \
  > capture/frida.filtered.txt || true
# Extracción directa de la telemetría del motor: enlaces CDN reales que usó (PlayMedia.links).
grep -aiE 'REPORT\.links|REPORT\.proxy|PlayMedia.setLinks|"links"|JniHandler\.' capture/frida.log 2>/dev/null \
  > capture/report-links.txt || true
# Aparte: SOLO las peticiones reales al CDN (connect + requests fuera de 127.0.0.1/portal).
grep -aiE 'connect|PR_Write|PR_Read|HTTP:send|SSL_write|main_addr|\.ts|\.m3u8' capture/frida.log 2>/dev/null \
  | grep -avE 'portalCore|127.0.0.1|umeng|crashlytics|google|firebase|installations' \
  > capture/cdn-requests.txt || true
echo "captura completa"

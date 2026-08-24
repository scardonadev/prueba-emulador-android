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

# Screenshot + UI dump con nombre (para afinar navegación desde el artifact).
snap() { # snap <etiqueta>
  adb exec-out screencap -p > "capture/nav_${1}.png" 2>/dev/null || true
  adb shell uiautomator dump /sdcard/n.xml >/dev/null 2>&1 && adb pull /sdcard/n.xml "capture/nav_${1}.xml" >/dev/null 2>&1 || true
}

# Cierra el banner del mod con BACK (ENTER abriría "My Account").
sleep 16
adb shell input keyevent 4 || true
sleep 3
snap 0_home   # <-- HOME tras cerrar banner. Mira este PNG para dar los taps exactos.

# OBJETIVO: reproducir una PELÍCULA (VOD). El token de VOD no está atado a IP.
# Si diste TAPS, se ejecutan; si no, intento una secuencia VOD por defecto y dejo
# screenshots numerados entre paso y paso para ver dónde quedó el foco.
# Tokens TAPS: "text:Movies" | "key:N" (keyevent) | "sleep:N" | "x,y".
#   DPAD: 19=up 20=down 21=left 22=right 23=center/enter.  Ej. película:
#   TAPS="text:Movies sleep:6 key:20 key:23 sleep:8 key:23"
if [ -n "${TAPS:-}" ]; then
  i=0
  for t in $TAPS; do
    case "$t" in
      text:*)  tap_text "${t#text:}" || true; sleep 2 ;;
      key:*)   adb shell input keyevent "${t#key:}" || true; sleep 2 ;;
      sleep:*) sleep "${t#sleep:}" ;;
      *,*)     x="${t%,*}"; y="${t#*,}"; adb shell input tap "$x" "$y" || true; sleep 2 ;;
    esac
    i=$((i+1)); snap "step_$i"
  done
else
  echo "== sin TAPS: intento VOD por defecto (tap 'Movies' -> abrir 1er título -> play) =="
  tap_text "Movies" || tap_text "Películas" || tap_text "MOVIES" || adb shell input keyevent 20
  sleep 6; snap 1_movies
  adb shell input keyevent 20 || true; sleep 1      # baja a la grilla
  adb shell input keyevent 23 || true; sleep 8; snap 2_detail   # abre el primer título
  adb shell input keyevent 23 || true; sleep 3; snap 3_play     # play
fi

# ¿Es viable un GATEWAY? El motor levanta un server local (mem://127.0.0.1:PORT y
# snapinfo_url http://127.0.0.1:PORT/...). Si ese server nos entrega un HLS/TS
# reproducible, un gateway = correr el motor y proxiar ese puerto. Lo probamos:
# adb forward runner:19000 -> emulador:PORT y hacemos GET a rutas típicas.
sleep 6
PORT=$(grep -aoE 'mem://127\.0\.0\.1:[0-9]+' capture/frida.log 2>/dev/null | head -1 | grep -oE '[0-9]+$')
MEDIA=$(grep -aoE '"media":"[^"]+"' capture/frida.log 2>/dev/null | head -1 | sed 's/.*:"//; s/"$//')
{
  echo "motor local: PORT=${PORT:-?}  MEDIA=${MEDIA:-?}"
  if [ -n "${PORT:-}" ]; then
    adb forward tcp:19000 "tcp:${PORT}" || true
    for path in "vod/0/${MEDIA}.snapinfo" "vod/0/${MEDIA}.m3u8" "vod/0/${MEDIA}" "vod/0/${MEDIA}/index.m3u8" "${MEDIA}.m3u8" "live/${MEDIA}.m3u8" "hls/${MEDIA}.m3u8"; do
      echo "=== GET /$path ==="
      curl -s -m 6 -D - "http://127.0.0.1:19000/$path" -o "capture/ls_$(echo "$path" | tr '/.' '__').bin" 2>&1 || true
      echo "  (bytes: $(wc -c < "capture/ls_$(echo "$path" | tr '/.' '__').bin" 2>/dev/null || echo 0))"
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

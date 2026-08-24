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

# (Sin bloqueo P2P: dejamos que reproduzca de verdad. Capturamos igual por Frida.)

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

# Cierra el banner del mod con BACK (ENTER abriría "My Account").
sleep 16
adb shell input keyevent 4 || true
sleep 3

# Navegación (una vez) vía TAPS. Tokens: "text:MOVIES" | "key:N" | "sleep:N" | "x,y".
# Para película (deja cargar la grilla):
#   TAPS="text:MOVIES sleep:22 key:22 key:23 sleep:8 key:23 key:23"
for t in ${TAPS:-}; do
  case "$t" in
    text:*)  tap_text "${t#text:}" || true; sleep 2 ;;
    key:*)   adb shell input keyevent "${t#key:}" || true; sleep 2 ;;
    sleep:*) sleep "${t#sleep:}" ;;
    *,*)     x="${t%,*}"; y="${t#*,}"; adb shell input tap "$x" "$y" || true; sleep 2 ;;
  esac
done

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
grep -aiE 'http|m3u8|cdn|sign_type|token|main_addr|slb|ranger|titan|portalCore|startPlay|getSlb' capture/frida.log 2>/dev/null \
  > capture/frida.filtered.txt || true
echo "captura completa"

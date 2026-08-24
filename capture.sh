#!/usr/bin/env bash
# Corre DENTRO del step del emulador (android-emulator-runner). Instala frida-server,
# instala el APK, lo lanza con Frida y captura la URL real del stream. Best-effort:
# también saca screenshots + volcado UI + logcat para poder afinar los taps.
set -uxo pipefail

PKG="${PKG:-com.lite.fczx}"
DUR="${DUR:-240}"
mkdir -p capture

adb wait-for-device
adb root || true
sleep 3
adb wait-for-device

# frida-server que coincida con la versión de frida-tools instalada en el runner
FV="$(python -c 'import frida; print(frida.__version__)')"
echo "frida $FV"
curl -fsSL -o fs.xz "https://github.com/frida/frida/releases/download/${FV}/frida-server-${FV}-android-x86_64.xz"
unxz fs.xz
adb push fs /data/local/tmp/frida-server
adb shell chmod 755 /data/local/tmp/frida-server
adb shell "nohup /data/local/tmp/frida-server >/dev/null 2>&1 &" || true
sleep 5

# instalar APK (-g concede permisos runtime)
adb install -r -g app.apk || adb install -r app.apk || { echo "::error::install falló"; exit 1; }

# Empujar al motor a usar el CDN HTTP (no P2P): bloquear puertos de trackers.
# (best-effort; añade IPs concretas si las conoces)
adb shell 'su 0 iptables -A OUTPUT -p udp --dport 5333 -j DROP' 2>/dev/null \
  || adb shell 'iptables -A OUTPUT -p udp --dport 5333 -j DROP' 2>/dev/null || true

# Driver de Frida: hace spawn del APK, carga el hook y captura DUR segundos.
python driver.py "$PKG" "$DUR" &
DRV=$!

# Cierra SOLO el banner del mod ("Canal de difusión ... PRESIONA OK O [X]"), que viene
# enfocado, con UNA pulsación. NADA de navegación: dejamos la app en su home natural.
sleep 16
adb shell input keyevent 66 || true               # ENTER/OK -> pulsa el botón del banner
sleep 2

# Navegación opcional (una vez) SOLO si pasas TAPS. Vacío = no navega.
#   "x,y" -> input tap x y   |   "key:N" -> input keyevent N (22=der 21=izq 19=arr 20=abj 23=OK)
for t in ${TAPS:-}; do
  case "$t" in
    key:*) adb shell input keyevent "${t#key:}" || true ;;
    *,*)   x="${t%,*}"; y="${t#*,}"; adb shell input tap "$x" "$y" || true ;;
  esac
  sleep 3
done

# Evidencia: screenshots + UI dump cada 10s (para iterar rápido)
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
# filtro rápido de lo interesante para revisar de un vistazo
grep -aiE 'http|m3u8|cdn|sign_type|token|main_addr|slb|ranger|titan' capture/frida.log 2>/dev/null \
  > capture/frida.filtered.txt || true
echo "captura completa"

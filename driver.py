#!/usr/bin/env python3
# Hace spawn del APK con Frida, carga frida-hook.js y vuelca todos los mensajes
# (URLs, JSON del motor, requests HTTP en claro) a capture/frida.log durante DUR s.
import frida, sys, time, os

pkg = sys.argv[1] if len(sys.argv) > 1 else "com.lite.fczx"
dur = int(sys.argv[2]) if len(sys.argv) > 2 else 240

os.makedirs("capture", exist_ok=True)
log = open("capture/frida.log", "a", encoding="utf-8")


def w(line):
    print(line, flush=True)
    log.write(line + "\n")
    log.flush()


def on_message(message, data):
    if message["type"] == "send":
        p = message["payload"]
        if isinstance(p, dict):
            w("[%s] %s" % (p.get("tag"), p.get("data")))
        else:
            w("[send] %s" % p)
    elif message["type"] == "error":
        w("[frida-error] %s | %s" % (message.get("description", ""), message.get("stack", "")[:400]))


def main():
    dev = None
    for _ in range(30):
        try:
            dev = frida.get_usb_device(timeout=5)
            break
        except Exception:
            time.sleep(2)
    if dev is None:
        w("[driver] no se encontró dispositivo frida")
        return
    w("[driver] device: %s" % dev)

    try:
        pid = dev.spawn([pkg])
    except Exception as e:
        w("[driver] spawn falló (%s); intento attach al proceso en marcha" % e)
        pid = None

    with open("frida-hook.js", encoding="utf-8") as f:
        src = f.read()

    if pid is not None:
        session = dev.attach(pid)
    else:
        session = dev.attach(pkg)

    script = session.create_script(src)
    script.on("message", on_message)
    script.load()
    if pid is not None:
        dev.resume(pid)
    w("[driver] capturando %ds..." % dur)
    time.sleep(dur)
    w("[driver] fin")


if __name__ == "__main__":
    main()

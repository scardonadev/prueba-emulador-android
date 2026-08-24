'use strict';
// Captura la URL/firma real que el motor Titan/Ranger genera al reproducir.
// Tres frentes:
//   1) Java: IjkMediaPlayer.setDataSource (nombres REALES, no ofuscados) => la URL
//      que recibe el player; y TODOS los métodos de com.titan.ranger.* (JSON in/out).
//   2) Nativo: send/write/sendto de libc => request HTTP en claro (CDN http://).
//   3) SSL_write (BoringSSL/OpenSSL) en cualquier módulo => request HTTPS en claro.
// Evita el TLS embebido (NSS) leyendo en el borde, no en la red.

function emit(o) { try { send(o); } catch (e) {} }

function bytesToStr(ab) {
  if (!ab) return '';
  var u = new Uint8Array(ab), s = '';
  for (var i = 0; i < u.length; i++) { var c = u[i]; s += (c >= 9 && c < 127) ? String.fromCharCode(c) : '.'; }
  return s;
}
function looksHttp(s) {
  return /^(GET|POST|HEAD|PUT|OPTIONS) \S+ HTTP\/1/.test(s) || /\r\nHost:\s/i.test(s);
}
function head(s) { return s.split('\r\n').slice(0, 16).join('\n'); }

// 2) libc sockets -> HTTP en claro
function hookSockets() {
  ['send', 'sendto', 'write', 'sendmsg'].forEach(function (fn) {
    var p = Module.findExportByName('libc.so', fn) || Module.findExportByName(null, fn);
    if (!p) return;
    try {
      Interceptor.attach(p, {
        onEnter: function (a) {
          try {
            var len = a[2].toInt32();
            if (len <= 8 || len > 1048576) return;
            var s = bytesToStr(a[1].readByteArray(Math.min(len, 4096)));
            if (looksHttp(s)) emit({ tag: 'HTTP:' + fn, data: head(s) });
          } catch (e) {}
        }
      });
    } catch (e) {}
  });
  var gai = Module.findExportByName('libc.so', 'getaddrinfo');
  if (gai) { try { Interceptor.attach(gai, { onEnter: function (a) { try { emit({ tag: 'DNS', data: a[0].readUtf8String() }); } catch (e) {} } }); } catch (e) {} }
}

// 3) SSL_write -> HTTPS en claro
function hookSSL() {
  Process.enumerateModules().forEach(function (m) {
    var w = Module.findExportByName(m.name, 'SSL_write');
    if (!w) return;
    try {
      Interceptor.attach(w, {
        onEnter: function (a) {
          try {
            var s = bytesToStr(a[1].readByteArray(a[2].toInt32()));
            if (looksHttp(s)) emit({ tag: 'SSL_write@' + m.name, data: head(s) });
          } catch (e) {}
        }
      });
      emit({ tag: 'info', data: 'hooked SSL_write@' + m.name });
    } catch (e) {}
  });
}

// 1) Java
function hookJava() {
  Java.perform(function () {
    // ijkplayer: la URL que se va a reproducir (clase NO ofuscada)
    try {
      var P = Java.use('tv.danmaku.ijk.media.player.IjkMediaPlayer');
      ['setDataSource', '_setDataSource'].forEach(function (mn) {
        if (!P[mn]) return;
        P[mn].overloads.forEach(function (ov) {
          ov.implementation = function () {
            emit({ tag: 'ijk.' + mn, data: Array.prototype.slice.call(arguments).map(String).join(' | ') });
            return ov.apply(this, arguments);
          };
        });
      });
      emit({ tag: 'info', data: 'hooked IjkMediaPlayer' });
    } catch (e) { emit({ tag: 'warn', data: 'no IjkMediaPlayer: ' + e }); }

    // MediaPlayer estándar (por si acaso)
    try {
      var MP = Java.use('android.media.MediaPlayer');
      MP.setDataSource.overload('java.lang.String').implementation = function (u) {
        emit({ tag: 'mp.setDataSource', data: String(u) }); return this.setDataSource(u);
      };
    } catch (e) {}

    // Motor Titan/Ranger: engancha TODOS los métodos (nombres ofuscados) para ver
    // el JSON que entra al nativo (entries/media/env) y lo que devuelve (URI/callbacks).
    ['com.titan.ranger.NativeJni', 'com.titan.ranger.a', 'com.titan.ranger.b', 'com.titan.ranger.c'].forEach(function (cn) {
      try {
        var C = Java.use(cn);
        var seen = {};
        C.class.getDeclaredMethods().forEach(function (md) {
          var nm = md.getName();
          if (seen[nm]) return; seen[nm] = 1;
          try {
            C[nm].overloads.forEach(function (ov) {
              ov.implementation = function () {
                var args = Array.prototype.slice.call(arguments).map(function (x) {
                  var s = String(x); return s.length > 600 ? s.slice(0, 600) : s;
                });
                var r = ov.apply(this, arguments);
                var rs = String(r); if (rs.length > 600) rs = rs.slice(0, 600);
                emit({ tag: cn + '.' + nm, data: args.join(' | ') + '  =>  ' + rs });
                return r;
              };
            });
          } catch (e) {}
        });
        emit({ tag: 'info', data: 'hooked ' + cn });
      } catch (e) { emit({ tag: 'warn', data: 'no ' + cn }); }
    });
  });
}

setTimeout(function () {
  try { hookSockets(); } catch (e) { emit({ tag: 'err', data: 'sockets ' + e }); }
  try { hookSSL(); } catch (e) {}
  try { hookJava(); } catch (e) { emit({ tag: 'err', data: 'java ' + e }); }
  emit({ tag: 'info', data: 'hooks instalados' });
}, 800);

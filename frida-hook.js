'use strict';
// Captura la URL/firma real del stream leyendo en el borde (antes del TLS embebido):
//   - Java: IjkMediaPlayer.setDataSource + TODOS los métodos de com.titan.ranger.*
//   - Nativo: send/write/sendto de libc  -> HTTP en claro
//   - SSL_write en cualquier lib -> HTTPS en claro
// Se instala con un pequeño retardo para dejar que la app inicialice (estable).

function emit(o) { try { send(o); } catch (e) {} }
function bytesToStr(ab) {
  if (!ab) return '';
  var u = new Uint8Array(ab), s = '';
  for (var i = 0; i < u.length; i++) { var c = u[i]; s += (c >= 9 && c < 127) ? String.fromCharCode(c) : '.'; }
  return s;
}
function looksHttp(s) { return /^(GET|POST|HEAD|PUT|OPTIONS) \S+ HTTP\/1/.test(s) || /\r\nHost:\s/i.test(s); }
function head(s) { return s.split('\r\n').slice(0, 16).join('\n'); }

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

function hookJava() {
  Java.perform(function () {
    // okhttp: TODAS las peticiones (incl. portalCore/getSlbInfo), sin importar el TLS.
    try {
      var OkHttpClient = Java.use('okhttp3.OkHttpClient');
      OkHttpClient.newCall.implementation = function (req) {
        try { emit({ tag: 'okhttp', data: req.method() + ' ' + String(req.url()) }); } catch (e) {}
        return this.newCall(req);
      };
      emit({ tag: 'info', data: 'hooked okhttp' });
    } catch (e) { emit({ tag: 'warn', data: 'no okhttp' }); }

    // Respuestas de portalCore: returnCode/errorMessage vienen en texto plano al inicio.
    try {
      var RespBuilder = Java.use('okhttp3.Response$Builder');
      RespBuilder.build.implementation = function () {
        var resp = this.build();
        try {
          var url = String(resp.request().url());
          if (url.indexOf('portalCore') >= 0 || url.indexOf('getSlb') >= 0) {
            var txt = '';
            try { txt = resp.peekBody(2048).string(); } catch (e) {}
            emit({ tag: 'resp', data: resp.code() + ' ' + url + '  ' + txt.slice(0, 220) });
          }
        } catch (e) {}
        return resp;
      };
      emit({ tag: 'info', data: 'hooked okhttp-resp' });
    } catch (e) { emit({ tag: 'warn', data: 'no okhttp-resp' }); }

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
    } catch (e) { emit({ tag: 'warn', data: 'no IjkMediaPlayer' }); }

    ['com.titan.ranger.NativeJni', 'com.titan.ranger.a', 'com.titan.ranger.b', 'com.titan.ranger.c'].forEach(function (cn) {
      try {
        var C = Java.use(cn); var seen = {};
        C.class.getDeclaredMethods().forEach(function (md) {
          var nm = md.getName(); if (seen[nm]) return; seen[nm] = 1;
          try {
            C[nm].overloads.forEach(function (ov) {
              ov.implementation = function () {
                var args = Array.prototype.slice.call(arguments).map(function (x) { var s = String(x); return s.length > 800 ? s.slice(0, 800) : s; });
                var r = ov.apply(this, arguments);
                var rs = String(r); if (rs.length > 800) rs = rs.slice(0, 800);
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
  try { hookSockets(); } catch (e) {}
  try { hookSSL(); } catch (e) {}
  try { hookJava(); } catch (e) {}
  emit({ tag: 'info', data: 'hooks instalados' });
}, 800);

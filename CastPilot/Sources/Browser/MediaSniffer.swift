import Foundation

/// JavaScript injected into every page and frame. It watches <video>/<audio> elements and
/// network requests (fetch and XHR) for video files and stream playlists, and reports each one
/// to the app once.
enum MediaSniffer {
    static let handlerName = "castPilotMedia"

    static let script = #"""
    (function () {
      if (window.__castPilotInstalled) return;
      window.__castPilotInstalled = true;

      var seen = {};
      var durationSent = {};
      var subSeen = {};
      var subCount = 0;
      var SUB_EXT = /\.(vtt|srt)$/i;
      var MEDIA_EXT = /\.(m3u8|mpd|mp4|m4v|mov|webm|mkv|mp3|m4a|aac|ogg|oga|wav|flac)(\?|#|&|$)/i;
      var SEGMENT_EXT = /\.(ts|m4s|cmfv|cmfa|aac|key|vtt|srt|webvtt|jpg|jpeg|png|gif|webp|js|css|json)$/i;
      var MEDIA_TYPE = /(mpegurl|dash\+xml|^video\/|^audio\/)/i;
      var SEGMENT_TYPE = /(mp2t|iso\.segment|^audio\/aac|^text\/)/i;
      var AD_HOST = /(doubleclick|googlesyndication|googleads|imasdk|adservice|adsystem|adnxs|springserve|spotx|tremorhub|innovid|teads|moatads|pubmatic|vidazoo|aniview|connatix)/i;

      function abs(u) {
        try { return new URL(u, document.baseURI).href; } catch (e) { return null; }
      }

      function pathOf(u) {
        try { return new URL(u).pathname; } catch (e) { return u; }
      }

      function send(msg) {
        try { window.webkit.messageHandlers.castPilotMedia.postMessage(msg); } catch (e) {}
      }

      function post(url, how, extra) {
        url = abs(url);
        if (!url || !/^https?:/i.test(url)) return;
        if (AD_HOST.test(url)) return;
        var dur = (extra && extra.duration > 0) ? extra.duration : 0;
        if (seen[url]) {
          // Send the length once it becomes known, so short ad clips can be hidden.
          if (dur > 0 && !durationSent[url]) { durationSent[url] = true; send({ url: url, how: 'update', duration: dur }); }
          return;
        }
        seen[url] = true;
        if (dur > 0) durationSent[url] = true;
        var msg = { url: url, how: how, title: document.title || '', page: location.href, mime: '' };
        if (extra) { for (var k in extra) { if (extra[k] != null) msg[k] = extra[k]; } }
        send(msg);
      }

      function postSub(url, label, lang, how) {
        url = abs(url);
        if (!url || !/^https?:/i.test(url) || subSeen[url] || subCount >= 20) return;
        subSeen[url] = true;
        subCount++;
        send({ kind: 'subtitle', url: url, label: label || '', lang: lang || '', page: location.href, how: how });
      }

      function consider(url, type, how) {
        if (!url || typeof url !== 'string') return;
        url = abs(url);
        if (!url) return;
        var p = pathOf(url);
        if (SUB_EXT.test(p)) {
          // Stand-alone subtitle files (not the numbered pieces of a stream's subtitles).
          if (!/(seg|segment|chunk|frag|part)[-_]?\d+/i.test(p) && !/[-_\/]\d{3,}\.(vtt|srt)$/i.test(p)) postSub(url, '', '', how);
          return;
        }
        if (SEGMENT_EXT.test(p)) return;
        type = (type || '').toLowerCase();
        if (type && SEGMENT_TYPE.test(type)) return;
        // Ranged requests are usually chunks of a bigger file the page is already playing.
        if (/[?&](range|bytestart|byteend)=/i.test(url) && !MEDIA_EXT.test(pathOf(url))) return;
        if (MEDIA_EXT.test(url) || (type && MEDIA_TYPE.test(type))) post(url, how, { mime: type });
      }

      function scanMedia(el) {
        if (!el || !el.tagName) return;
        var extra = {
          poster: el.poster ? abs(el.poster) : null,
          duration: isFinite(el.duration) ? el.duration : null,
          mime: el.tagName === 'AUDIO' ? 'audio/mpeg' : ''
        };
        var src = el.currentSrc || el.src;
        if (src && !/^(blob|data):/i.test(src)) post(src, 'element', extra);
        var tracks = el.querySelectorAll ? el.querySelectorAll('track') : [];
        for (var t = 0; t < tracks.length; t++) {
          var kind = (tracks[t].kind || 'subtitles').toLowerCase();
          if ((kind === 'subtitles' || kind === 'captions') && tracks[t].src) {
            postSub(tracks[t].src, tracks[t].label, tracks[t].srclang, 'track');
          }
        }
        var sources = el.querySelectorAll ? el.querySelectorAll('source') : [];
        for (var i = 0; i < sources.length; i++) {
          var s = sources[i].src || sources[i].getAttribute('src');
          if (s && !/^(blob|data):/i.test(s)) {
            var e2 = { poster: extra.poster, duration: extra.duration, mime: sources[i].type || extra.mime };
            post(s, 'element', e2);
          }
        }
      }

      function scanAll() {
        var els = document.querySelectorAll('video, audio');
        for (var i = 0; i < els.length; i++) scanMedia(els[i]);
        // Links straight to video files.
        var links = document.querySelectorAll('a[href]');
        for (var j = 0; j < links.length && j < 2000; j++) {
          var h = links[j].href;
          if (h && MEDIA_EXT.test(pathOf(h)) && !/\.(mp3|m4a|aac|ogg|oga|wav|flac)$/i.test(pathOf(h))) {
            post(h, 'link', { mime: '' });
          }
        }
      }

      ['play', 'playing', 'loadedmetadata', 'loadstart', 'durationchange'].forEach(function (name) {
        document.addEventListener(name, function (e) { scanMedia(e.target); }, true);
      });

      var timer = null;
      function schedule() {
        if (timer) return;
        timer = setTimeout(function () { timer = null; scanAll(); }, 600);
      }
      try {
        new MutationObserver(schedule).observe(document.documentElement || document, {
          childList: true, subtree: true, attributes: true, attributeFilter: ['src']
        });
      } catch (e) {}
      document.addEventListener('DOMContentLoaded', scanAll);
      window.addEventListener('load', scanAll);
      var ticks = 0;
      var interval = setInterval(function () { scanAll(); if (++ticks > 40) clearInterval(interval); }, 3000);

      // fetch()
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          var url = (typeof input === 'string') ? input : (input && input.url);
          try { consider(url, '', 'fetch'); } catch (e) {}
          return origFetch.apply(this, arguments).then(function (res) {
            try { consider(res.url, res.headers.get('content-type'), 'fetch'); } catch (e) {}
            return res;
          });
        };
      }

      // XMLHttpRequest
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try {
          var xhr = this;
          xhr.__castPilotURL = url;
          consider(String(url), '', 'xhr');
          xhr.addEventListener('readystatechange', function () {
            if (xhr.readyState === 2) {
              try { consider(xhr.responseURL || String(xhr.__castPilotURL), xhr.getResponseHeader('content-type'), 'xhr'); } catch (e) {}
            }
          });
        } catch (e) {}
        return origOpen.apply(this, arguments);
      };
    })();
    """#
}

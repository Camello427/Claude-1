/* CastPilot web app: play web videos and send them to a TV with AirPlay (Safari) or
 * Chromecast (Chrome). No build step and no framework; everything lives in this file. */
'use strict';

// ---------------------------------------------------------------- helpers

const $ = (id) => document.getElementById(id);
const video = $('video');

const store = {
  get(key, fallback) {
    try {
      const raw = localStorage.getItem('castpilot.' + key);
      return raw == null ? fallback : JSON.parse(raw);
    } catch (e) { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem('castpilot.' + key, JSON.stringify(value)); } catch (e) { /* storage full or disabled */ }
  },
};

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function clock(sec) {
  if (!isFinite(sec) || sec < 0) return '--:--';
  sec = Math.floor(sec);
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`;
}

let toastTimer = null;
function toast(text) {
  const t = $('toast');
  t.textContent = text;
  t.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add('hidden'), 2600);
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.async = true;
    s.onload = () => resolve();
    s.onerror = () => reject(new Error('Could not load ' + src));
    document.head.appendChild(s);
  });
}

function hostOf(url) {
  try { return new URL(url).host; } catch (e) { return ''; }
}

function isWebURL(text) {
  try { const u = new URL(text); return u.protocol === 'http:' || u.protocol === 'https:'; } catch (e) { return false; }
}

// ---------------------------------------------------------------- media kinds

function detectKind(url, mime) {
  let path = '';
  try { path = new URL(url).pathname.toLowerCase(); } catch (e) { path = String(url).toLowerCase(); }
  const ext = (path.match(/\.([a-z0-9]+)$/) || [])[1] || '';
  if (ext === 'm3u8' || ext === 'm3u') return 'hls';
  if (ext === 'mpd') return 'dash';
  if (ext === 'mp4' || ext === 'm4v') return 'mp4';
  if (ext === 'webm') return 'webm';
  if (ext === 'mov') return 'mov';
  if (ext === 'mkv') return 'mkv';
  if (['mp3', 'm4a', 'aac', 'ogg', 'oga', 'wav', 'flac', 'opus'].includes(ext)) return 'audio';
  const t = String(mime || '').toLowerCase();
  if (t.includes('mpegurl')) return 'hls';
  if (t.includes('dash+xml')) return 'dash';
  if (t.startsWith('audio/')) return 'audio';
  if (t.startsWith('video/')) return 'mp4';
  const s = String(url).toLowerCase();
  if (s.includes('.m3u8')) return 'hls';
  if (s.includes('.mpd')) return 'dash';
  if (s.includes('.mp4')) return 'mp4';
  return 'unknown';
}

const KIND_LABEL = {
  hls: 'Stream (HLS)', dash: 'Stream (DASH)', mp4: 'MP4 video', webm: 'WebM video', mov: 'QuickTime video',
  mkv: 'MKV video', audio: 'Audio', unknown: 'Video',
};

function castMime(kind) {
  switch (kind) {
    case 'hls': return 'application/x-mpegURL';
    case 'dash': return 'application/dash+xml';
    case 'webm': return 'video/webm';
    case 'audio': return 'audio/mpeg';
    default: return 'video/mp4';
  }
}

function looksLikeMedia(url) {
  return detectKind(url) !== 'unknown';
}

function makeItem(url, extra) {
  const e = extra || {};
  let name = '';
  try { name = decodeURIComponent(new URL(url).pathname.split('/').pop() || ''); } catch (err) { name = ''; }
  return {
    url,
    title: e.title || name.replace(/\.[a-z0-9]+$/i, '') || hostOf(url) || 'Video',
    kind: e.kind || detectKind(url, e.mime),
    page: e.page || '',
    poster: e.poster || '',
    duration: e.duration || 0,
    isLocal: !!e.isLocal,
    subs: e.subs || [],
  };
}

// ---------------------------------------------------------------- state

const settings = Object.assign({ resume: true, hideShort: true, autoNext: true }, store.get('settings', {}));
let queue = store.get('queue', []);
let watchHistory = store.get('history', []);
let found = store.get('found', null);
let sites = store.get('sites', [
  { title: 'Internet Archive – Movies', url: 'https://archive.org/details/movies' },
  { title: 'Apple HLS examples', url: 'https://developer.apple.com/streaming/examples/' },
  { title: 'Test videos (Big Buck Bunny)', url: 'https://test-videos.co.uk/bigbuckbunny/mp4-h264' },
]);
let repeatMode = store.get('repeat', 'off');
let shuffle = store.get('shuffle', false);

let current = null;           // the item loaded in the player
let loadedSubs = [];          // subtitle files loaded this session
let activeSub = null;         // { label, lang, url, castUrl }
let variants = [];            // quality options for native HLS
let hls = null;               // hls.js instance (browsers without built-in HLS)
let finishedFired = false;
let lastHistorySave = 0;
let seeking = false;

const saveSettings = () => store.set('settings', settings);
const saveQueue = () => store.set('queue', queue.filter((i) => !i.isLocal));
const saveHistory = () => store.set('history', watchHistory);

// ---------------------------------------------------------------- Chromecast (Chrome, Edge on Android / desktop)

const cc = { ready: false, available: false, connected: false, player: null, controller: null, device: '', loadedUrl: null, lastTime: 0, finished: false };

function chromeLike() {
  return !!window.chrome && !/iPhone|iPad|iPod/i.test(navigator.userAgent);
}

function initChromecast() {
  if (!chromeLike() || !window.isSecureContext) return;
  window.__onGCastApiAvailable = (ok) => { if (ok) setupChromecast(); };
  loadScript('https://www.gstatic.com/cv/js/sender/v1/cast_sender.js?loadCastFramework=1').catch(() => {});
}

function setupChromecast() {
  const fw = window.cast.framework;
  const ctx = fw.CastContext.getInstance();
  ctx.setOptions({
    receiverApplicationId: window.chrome.cast.media.DEFAULT_MEDIA_RECEIVER_APP_ID,
    autoJoinPolicy: window.chrome.cast.AutoJoinPolicy.ORIGIN_SCOPED,
  });
  cc.player = new fw.RemotePlayer();
  cc.controller = new fw.RemotePlayerController(cc.player);
  cc.controller.addEventListener(fw.RemotePlayerEventType.ANY_CHANGE, onChromecastChange);
  ctx.addEventListener(fw.CastContextEventType.CAST_STATE_CHANGED, (e) => {
    cc.available = e.castState !== fw.CastState.NO_DEVICES_AVAILABLE;
    renderCastButtons();
  });
  ctx.addEventListener(fw.CastContextEventType.SESSION_STATE_CHANGED, onChromecastSession);
  cc.available = ctx.getCastState() !== fw.CastState.NO_DEVICES_AVAILABLE;
  cc.ready = true;
  renderCastButtons();
  renderDiagnostics();
}

function chromecastSession() {
  return cc.ready ? window.cast.framework.CastContext.getInstance().getCurrentSession() : null;
}

function onChromecastSession(e) {
  const S = window.cast.framework.SessionState;
  if (e.sessionState === S.SESSION_STARTED || e.sessionState === S.SESSION_RESUMED) {
    cc.connected = true;
    const session = chromecastSession();
    cc.device = session && session.getCastDevice() ? session.getCastDevice().friendlyName : 'Chromecast';
    if (current && !current.isLocal && e.sessionState === S.SESSION_STARTED) {
      const at = video.currentTime || 0;
      video.pause();
      chromecastLoad(current, at);
    }
  } else if (e.sessionState === S.SESSION_ENDED) {
    cc.connected = false;
    cc.loadedUrl = null;
    if (current && !current.isLocal && cc.lastTime > 0) {
      try { video.currentTime = cc.lastTime; } catch (err) { /* not loaded */ }
    }
  }
  renderCastState();
}

async function chromecastLoad(item, startAt) {
  const session = chromecastSession();
  if (!session) return;
  if (item.isLocal) {
    showError('Videos from this phone can’t be sent to Chromecast from a web page. Use AirPlay, or the CastPilot iPhone app.');
    return;
  }
  const cm = window.chrome.cast.media;
  const url = item.variantUrl || item.url;
  const info = new cm.MediaInfo(url, castMime(item.kind));
  info.contentUrl = url;
  info.streamType = cm.StreamType.BUFFERED;
  const meta = new cm.GenericMediaMetadata();
  meta.title = item.title;
  if (item.poster) meta.images = [new window.chrome.cast.Image(item.poster)];
  info.metadata = meta;
  const request = new cm.LoadRequest(info);
  request.autoplay = true;
  request.currentTime = startAt || 0;
  if (activeSub && activeSub.castUrl) {
    const track = new cm.Track(1, cm.TrackType.TEXT);
    track.trackContentId = activeSub.castUrl;
    track.trackContentType = 'text/vtt';
    track.subtype = cm.TextTrackType.SUBTITLES;
    track.name = activeSub.label;
    track.language = activeSub.lang || 'en';
    info.tracks = [track];
    request.activeTrackIds = [1];
  }
  try {
    await session.loadMedia(request);
    cc.loadedUrl = item.url;
    cc.finished = false;
    hideError();
  } catch (err) {
    cc.loadedUrl = null;
    showError('The Chromecast couldn’t play this video. The website may block TVs, or (for streams) not allow other apps to load it.');
  }
  renderCastState();
}

function onChromecastChange(e) {
  if (!cc.player) return;
  if (cc.player.currentTime > 0) cc.lastTime = cc.player.currentTime;
  if (e.field === 'playerState' && cc.player.playerState === 'IDLE' && cc.loadedUrl && !cc.finished) {
    const session = chromecastSession();
    const ms = session && session.getMediaSession();
    if (ms && ms.idleReason === 'FINISHED') {
      cc.finished = true;
      onFinished();
    }
  }
}

// ---------------------------------------------------------------- AirPlay (Safari) and the Remote Playback API

const airplay = {
  supported: !!window.WebKitPlaybackTargetAvailabilityEvent,
  available: false,
  active: false,
};
const remotePlayback = { supported: 'remote' in HTMLMediaElement.prototype, connected: false };

if (airplay.supported) {
  video.addEventListener('webkitplaybacktargetavailabilitychanged', (e) => {
    airplay.available = e.availability === 'available';
    renderCastButtons();
  });
  video.addEventListener('webkitcurrentplaybacktargetiswirelesschanged', () => {
    airplay.active = !!video.webkitCurrentPlaybackTargetIsWireless;
    renderCastState();
  });
}
if (remotePlayback.supported && video.remote) {
  video.remote.addEventListener('connect', () => { remotePlayback.connected = true; renderCastState(); });
  video.remote.addEventListener('disconnect', () => { remotePlayback.connected = false; renderCastState(); });
}

// ---------------------------------------------------------------- playback engine (local/AirPlay video element or Chromecast)

const engine = {
  remote() { return cc.connected && !!cc.loadedUrl && current && !current.isLocal; },
  time() { return this.remote() ? (cc.player.currentTime || 0) : (video.currentTime || 0); },
  duration() {
    if (this.remote()) return cc.player.duration || 0;
    return isFinite(video.duration) ? video.duration : 0;
  },
  paused() { return this.remote() ? (cc.player.isPaused || cc.player.playerState === 'IDLE') : video.paused; },
  play() {
    if (this.remote()) { if (cc.player.isPaused) cc.controller.playOrPause(); return; }
    const p = video.play();
    if (p && p.catch) p.catch(() => {});
  },
  pause() {
    if (this.remote()) { if (!cc.player.isPaused) cc.controller.playOrPause(); return; }
    video.pause();
  },
  toggle() { if (this.paused()) this.play(); else this.pause(); },
  seek(t) {
    t = Math.max(0, t);
    if (this.remote()) { cc.player.currentTime = t; cc.controller.seek(); return; }
    try { video.currentTime = t; } catch (e) { /* not seekable yet */ }
  },
  skip(delta) {
    const d = this.duration();
    let t = this.time() + delta;
    if (d > 0) t = Math.min(t, d - 1);
    this.seek(t);
  },
  stop() {
    if (this.remote()) { cc.controller.stop(); cc.loadedUrl = null; return; }
    video.pause();
  },
  setRate(r) {
    video.playbackRate = r;
    if (this.remote()) {
      const session = chromecastSession();
      const ms = session && session.getMediaSession();
      if (ms) {
        session.sendMessage('urn:x-cast:com.google.cast.media', {
          type: 'SET_PLAYBACK_RATE', playbackRate: r, mediaSessionId: ms.mediaSessionId, requestId: Math.floor(Math.random() * 1e6),
        }).catch(() => toast('This TV doesn’t support changing speed.'));
      }
    }
  },
  setVolume(v) {
    if (this.remote()) { cc.player.volumeLevel = v; cc.controller.setVolumeLevel(); }
  },
};

// ---------------------------------------------------------------- loading and playing

async function loadHls() {
  if (window.Hls) return window.Hls;
  try { await loadScript('https://cdn.jsdelivr.net/npm/hls.js@1/dist/hls.min.js'); } catch (e) { return null; }
  return window.Hls || null;
}

function teardownHls() {
  if (hls) { try { hls.destroy(); } catch (e) { /* already gone */ } hls = null; }
}

function clearTracks() {
  Array.from(video.querySelectorAll('track')).forEach((t) => {
    if (t.src && t.src.startsWith('blob:')) URL.revokeObjectURL(t.src);
    t.remove();
  });
}

/** Points the <video> element at an item, starting at `startAt` seconds. */
async function setLocalSource(item, startAt) {
  teardownHls();
  clearTracks();
  video.removeAttribute('src');
  video.load();
  const url = item.variantUrl || item.url;
  const needsHlsJs = item.kind === 'hls' && !video.canPlayType('application/vnd.apple.mpegurl');
  if (needsHlsJs) {
    const Hls = await loadHls();
    if (Hls && Hls.isSupported()) {
      hls = new Hls({ startPosition: startAt > 0 ? startAt : -1 });
      hls.on(Hls.Events.MANIFEST_PARSED, () => renderQualityFromHls());
      hls.on(Hls.Events.ERROR, (_, data) => {
        if (data && data.fatal) showError('This stream couldn’t be played here. The website may not allow other apps to load it. Casting may still work.');
      });
      hls.loadSource(url);
      hls.attachMedia(video);
    } else {
      video.src = url;
    }
  } else {
    video.src = url;
  }
  if (startAt > 0 && !hls) {
    video.addEventListener('loadedmetadata', () => {
      try { video.currentTime = startAt; } catch (e) { /* ignore */ }
    }, { once: true });
  }
  if (activeSub) attachSubtitleTrack(activeSub);
  const p = video.play();
  if (p && p.catch) p.catch(() => {});
}

/** Plays an item: on the Chromecast if one is connected, otherwise here (and over AirPlay). */
async function playItem(item, opts) {
  const o = opts || {};
  current = Object.assign({}, item);
  finishedFired = false;
  activeSub = null;
  variants = [];
  hideError();
  showTab('watch');

  let startAt = typeof o.startAt === 'number' ? o.startAt : 0;
  let resumed = 0;
  if (typeof o.startAt !== 'number' && settings.resume && !current.isLocal) {
    const h = watchHistory.find((e) => e.url === current.url);
    if (h && h.position > 30 && (!h.duration || h.position < h.duration - 30)) {
      startAt = h.position;
      resumed = h.position;
    }
  }

  $('playerCard').classList.remove('hidden');
  $('nowTitle').textContent = current.title;
  $('nowSub').textContent = `${KIND_LABEL[current.kind] || 'Video'} · ${current.isLocal ? 'On this device' : hostOf(current.url)}`;
  $('resumeBanner').classList.toggle('hidden', !resumed);
  $('resumeText').textContent = resumed ? `Resumed at ${clock(resumed)}` : '';
  video.poster = current.poster || '';
  video.playbackRate = Number($('speedSelect').value) || 1;

  renderSubtitleOptions();
  renderQualityPlaceholder();
  recordHistory(current);

  if (engine.remote() || (cc.connected && !current.isLocal)) {
    video.pause();
    await chromecastLoad(current, startAt);
  } else {
    await setLocalSource(current, startAt);
  }
  if (current.kind === 'hls' && !current.isLocal && !hls) loadNativeVariants(current);
  updateMediaSession();
  renderAll();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function showError(text) {
  const b = $('errorBanner');
  b.textContent = text;
  b.classList.remove('hidden');
}

function hideError() {
  $('errorBanner').classList.add('hidden');
}

video.addEventListener('error', () => {
  if (!current || engine.remote()) return;
  showError(current.kind === 'dash'
    ? 'DASH streams don’t play in Safari. Try another video from the page, or Chromecast from Chrome.'
    : 'This video couldn’t be played. The website may only allow its own pages to play it, or the format isn’t supported.');
});
video.addEventListener('ended', () => { if (!engine.remote()) onFinished(); });
video.addEventListener('timeupdate', () => maybeSaveProgress(false));
video.addEventListener('pause', () => maybeSaveProgress(true));
video.addEventListener('play', hideErrorIfPlaying);
function hideErrorIfPlaying() { if (!video.error) hideError(); }

// ---------------------------------------------------------------- finishing, queue, repeat

function onFinished() {
  if (finishedFired || !current) return;
  finishedFired = true;
  const d = engine.duration();
  if (d > 0) updateHistoryProgress(current.url, d, d, true);
  if (sleep.endOfVideo) {
    sleepFired();
    return;
  }
  if (!settings.autoNext) return;
  const next = dequeueNext(current, true);
  if (next) playItem(next, next.url === current.url ? { startAt: 0 } : {});
}

function dequeueNext(cur, finished) {
  if (finished && repeatMode === 'one' && cur) return cur;
  if (repeatMode === 'all' && cur && !cur.isLocal) queue.push(cur);
  if (!queue.length) { saveQueue(); return null; }
  const index = shuffle ? Math.floor(Math.random() * queue.length) : 0;
  const [item] = queue.splice(index, 1);
  saveQueue();
  renderQueue();
  return item;
}

function addToQueue(item, next) {
  if (next) queue.unshift(item); else queue.push(item);
  saveQueue();
  renderQueue();
  toast(next ? 'Will play next' : `Added to Up Next (${queue.length})`);
}

function playNextInQueue() {
  const next = dequeueNext(current, false);
  if (next) playItem(next);
}

// ---------------------------------------------------------------- watchHistory and resume

function recordHistory(item) {
  if (item.isLocal) return;
  const old = watchHistory.find((e) => e.url === item.url);
  watchHistory = watchHistory.filter((e) => e.url !== item.url);
  watchHistory.unshift({
    url: item.url, title: item.title, kind: item.kind, page: item.page, poster: item.poster,
    position: old ? old.position : 0, duration: old ? old.duration : (item.duration || 0), date: Date.now(),
  });
  watchHistory = watchHistory.slice(0, 100);
  saveHistory();
  renderHistory();
}

function updateHistoryProgress(url, position, duration, force) {
  const e = watchHistory.find((x) => x.url === url);
  if (!e) return;
  e.position = position;
  if (duration > 0) e.duration = duration;
  if (force || Date.now() - lastHistorySave > 5000) {
    lastHistorySave = Date.now();
    saveHistory();
  }
}

function maybeSaveProgress(force) {
  if (!current || current.isLocal) return;
  const t = engine.time();
  if (t > 0) updateHistoryProgress(current.url, t, engine.duration(), force);
}

// ---------------------------------------------------------------- sleep timer

const sleep = { timer: null, deadline: 0, endOfVideo: false };

function setSleep(value) {
  clearTimeout(sleep.timer);
  sleep.timer = null;
  sleep.deadline = 0;
  sleep.endOfVideo = false;
  if (value === 'end') {
    sleep.endOfVideo = true;
  } else if (value !== 'off') {
    const ms = Number(value) * 60000;
    sleep.deadline = Date.now() + ms;
    sleep.timer = setTimeout(sleepFired, ms);
  }
  renderSleep();
}

function sleepFired() {
  engine.pause();
  setSleep('off');
  $('sleepSelect').value = 'off';
  toast('Sleep timer: playback paused');
}

function renderSleep() {
  const note = $('sleepNote');
  if (sleep.deadline) note.textContent = `Sleep timer: pausing in ${clock((sleep.deadline - Date.now()) / 1000)}`;
  else if (sleep.endOfVideo) note.textContent = 'Sleep timer: pausing when this video ends';
  else note.textContent = '';
}

// ---------------------------------------------------------------- subtitles

function srtToVtt(text) {
  let t = String(text).replace(/\r\n?/g, '\n').replace(/^﻿/, '');
  if (/^\s*WEBVTT/.test(t)) return t;
  t = t.split('\n').map((line) => (line.includes('-->') ? line.replace(/,/g, '.') : line)).join('\n');
  return 'WEBVTT\n\n' + t;
}

function attachSubtitleTrack(sub) {
  clearTracks();
  if (!sub || !sub.blobUrl) return;
  const track = document.createElement('track');
  track.kind = 'subtitles';
  track.label = sub.label;
  track.srclang = sub.lang || 'en';
  track.src = sub.blobUrl;
  track.default = true;
  video.appendChild(track);
  setTimeout(() => {
    for (const tt of Array.from(video.textTracks)) tt.mode = tt.label === sub.label ? 'showing' : 'disabled';
  }, 0);
}

function subtitleChoices() {
  const list = [];
  if (current && current.subs) current.subs.forEach((s) => list.push({ label: s.label || 'Subtitles', lang: s.lang, url: s.url }));
  if (found && current && found.u === current.page) {
    (found.s || []).forEach((s) => {
      if (!list.some((x) => x.url === s.u)) list.push({ label: s.l || labelFromURL(s.u), lang: s.g, url: s.u });
    });
  }
  loadedSubs.forEach((s) => list.push(s));
  return list;
}

function labelFromURL(u) {
  try { return decodeURIComponent(new URL(u).pathname.split('/').pop()); } catch (e) { return 'Subtitles'; }
}

function renderSubtitleOptions() {
  const sel = $('subtitleSelect');
  const choices = subtitleChoices();
  sel.innerHTML = '<option value="off">Off</option>' + choices.map((s, i) => `<option value="${i}">${esc(s.label)}</option>`).join('');
  sel.value = activeSub ? String(choices.findIndex((c) => c.label === activeSub.label && c.url === activeSub.url)) : 'off';
  if (sel.value === '' || sel.value === '-1') sel.value = 'off';
}

async function selectSubtitle(choice) {
  if (!choice) {
    activeSub = null;
    clearTracks();
  } else {
    let text = choice.text;
    if (!text && choice.url) {
      try {
        const res = await fetch(choice.url);
        if (!res.ok) throw new Error(String(res.status));
        text = await res.text();
      } catch (e) {
        text = null;
      }
    }
    const castUrl = choice.url && /\.vtt(\?|$)/i.test(choice.url) ? choice.url : null;
    activeSub = { label: choice.label, lang: choice.lang, url: choice.url, castUrl, blobUrl: null };
    if (text) {
      activeSub.blobUrl = URL.createObjectURL(new Blob([srtToVtt(text)], { type: 'text/vtt' }));
      attachSubtitleTrack(activeSub);
    } else {
      toast('This website doesn’t let other apps load its subtitles here.');
    }
  }
  if (engine.remote() && current) {
    if (activeSub && !activeSub.castUrl) toast('Chromecast needs subtitles as a .vtt web link; these show on this device only.');
    chromecastLoad(current, engine.time());
  }
}

$('subtitleSelect').addEventListener('change', (e) => {
  const v = e.target.value;
  selectSubtitle(v === 'off' ? null : subtitleChoices()[Number(v)]);
});

$('subtitleFile').addEventListener('change', async (e) => {
  const file = e.target.files && e.target.files[0];
  e.target.value = '';
  if (!file) return;
  const text = await file.text();
  const choice = { label: file.name.replace(/\.(srt|vtt)$/i, ''), lang: '', url: null, text };
  loadedSubs.push(choice);
  await selectSubtitle(choice);
  renderSubtitleOptions();
  toast('Subtitles loaded');
});

// ---------------------------------------------------------------- quality

function parseVariants(text, base) {
  const out = [];
  const lines = String(text).replace(/\r\n/g, '\n').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    const attrs = {};
    line.slice(18).replace(/([A-Z0-9-]+)=("[^"]*"|[^,]*)/g, (_, k, v) => { attrs[k] = v.replace(/^"|"$/g, ''); return ''; });
    let uri = '';
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j].trim();
      if (l && !l.startsWith('#')) { uri = l; break; }
    }
    if (!uri) continue;
    let url;
    try { url = new URL(uri, base).href; } catch (e) { continue; }
    const res = (attrs.RESOLUTION || '').split('x');
    const height = Number(res[1]) || 0;
    const bw = Number(attrs['AVERAGE-BANDWIDTH'] || attrs.BANDWIDTH) || 0;
    if (!out.some((v) => v.url === url)) out.push({ url, height, bandwidth: bw });
  }
  return out.sort((a, b) => (b.height - a.height) || (b.bandwidth - a.bandwidth));
}

function variantLabel(height, bandwidth) {
  const rate = bandwidth ? `${(bandwidth / 1e6).toFixed(1)} Mbps` : '';
  const name = height >= 2000 ? '4K' : height >= 1400 ? '1440p' : height ? `${height}p` : '';
  return [name, rate].filter(Boolean).join(' · ') || 'Unknown';
}

function renderQualityPlaceholder() {
  const sel = $('qualitySelect');
  sel.innerHTML = '<option value="auto">Automatic</option>';
  sel.disabled = true;
}

async function loadNativeVariants(item) {
  try {
    const res = await fetch(item.url);
    if (!res.ok) return;
    const text = await res.text();
    // With separate audio tracks, picking one video playlist would lose the sound.
    if (/#EXT-X-MEDIA:[^\n]*TYPE=AUDIO[^\n]*URI=/.test(text)) return;
    const list = parseVariants(text, res.url || item.url);
    if (current !== null && current.url === item.url && list.length > 1) {
      variants = list;
      const sel = $('qualitySelect');
      sel.innerHTML = '<option value="auto">Automatic</option>' +
        list.map((v, i) => `<option value="${i}">${esc(variantLabel(v.height, v.bandwidth))}</option>`).join('');
      sel.disabled = false;
    }
  } catch (e) {
    // The site doesn't share its playlist with other apps; quality stays automatic.
  }
}

function renderQualityFromHls() {
  if (!hls || !hls.levels || hls.levels.length < 2) return;
  const sel = $('qualitySelect');
  sel.innerHTML = '<option value="auto">Automatic</option>' +
    hls.levels.map((l, i) => `<option value="hls-${i}">${esc(variantLabel(l.height, l.bitrate))}</option>`).join('');
  sel.disabled = false;
}

$('qualitySelect').addEventListener('change', (e) => {
  const v = e.target.value;
  if (!current) return;
  if (hls) {
    hls.currentLevel = v === 'auto' ? -1 : Number(v.replace('hls-', ''));
    return;
  }
  current.variantUrl = v === 'auto' ? null : (variants[Number(v)] || {}).url || null;
  const at = engine.time();
  if (engine.remote()) chromecastLoad(current, at);
  else setLocalSource(current, at);
});

// ---------------------------------------------------------------- lock screen / Control Center

function updateMediaSession() {
  if (!('mediaSession' in navigator) || !current) return;
  try {
    navigator.mediaSession.metadata = new window.MediaMetadata({
      title: current.title,
      artist: castTargetLabel() || 'CastPilot',
      artwork: current.poster
        ? [{ src: current.poster, sizes: '512x512' }]
        : [{ src: 'icon-512.png', sizes: '512x512', type: 'image/png' }],
    });
  } catch (e) { /* older browsers */ }
}

function setupMediaSessionHandlers() {
  if (!('mediaSession' in navigator)) return;
  const set = (action, fn) => { try { navigator.mediaSession.setActionHandler(action, fn); } catch (e) { /* unsupported */ } };
  set('play', () => engine.play());
  set('pause', () => engine.pause());
  set('seekbackward', (d) => engine.skip(-((d && d.seekOffset) || 10)));
  set('seekforward', (d) => engine.skip((d && d.seekOffset) || 30));
  set('seekto', (d) => { if (d && typeof d.seekTime === 'number') engine.seek(d.seekTime); });
  set('nexttrack', () => playNextInQueue());
  set('previoustrack', () => engine.seek(0));
  set('stop', () => engine.stop());
}

// ---------------------------------------------------------------- rendering

function castTargetLabel() {
  if (engine.remote()) return `on ${cc.device}`;
  if (airplay.active) return 'on AirPlay';
  if (remotePlayback.connected) return 'on your TV';
  return '';
}

function renderCastButtons() {
  const showAirplay = airplay.supported;
  const showChromecast = cc.ready;
  const showRemote = !showAirplay && !showChromecast && remotePlayback.supported;
  $('airplayBtn').classList.toggle('hidden', !showAirplay);
  $('chromecastBtn').classList.toggle('hidden', !showChromecast);
  $('remoteBtn').classList.toggle('hidden', !showRemote);
  const visible = [showAirplay, showChromecast, showRemote].filter(Boolean).length;
  ['airplayBtn', 'chromecastBtn', 'remoteBtn'].forEach((id) => $(id).classList.toggle('single', visible === 1));
  $('airplayBtn').lastChild.textContent = airplay.active ? 'AirPlay (on)' : 'AirPlay';
  $('chromecastBtn').lastChild.textContent = cc.connected ? `${cc.device} (on)` : (cc.available ? 'Chromecast' : 'Chromecast (none found)');
}

function renderCastState() {
  const label = castTargetLabel();
  const chip = $('castChip');
  chip.textContent = label ? `Playing ${label}` : 'On this device';
  chip.classList.toggle('live', !!label);
  const remote = engine.remote();
  $('castOverlay').classList.toggle('hidden', !remote);
  $('castOverlayText').textContent = remote ? `Playing on ${cc.device}` : '';
  $('volumeRow').classList.toggle('hidden', !remote);
  if (remote && cc.player) $('volume').value = cc.player.volumeLevel;
  renderCastButtons();
  updateMediaSession();
}

function renderPlayer() {
  if (!current) return;
  const t = engine.time();
  const d = engine.duration();
  const seek = $('seek');
  if (!seeking) {
    seek.max = d > 0 ? d : 100;
    seek.value = d > 0 ? t : 0;
  }
  seek.disabled = !(d > 0);
  $('tCur').textContent = clock(seeking ? Number(seek.value) : t);
  $('tDur').textContent = d > 0 ? clock(d) : (current.kind === 'hls' ? 'Live' : '--:--');
  const paused = engine.paused();
  $('playPause').innerHTML = `<svg><use href="#${paused ? 'i-play' : 'i-pause'}"/></svg>`;
  $('playPause').setAttribute('aria-label', paused ? 'Play' : 'Pause');
  $('nextBtn').classList.toggle('hidden', queue.length === 0);
  if ('mediaSession' in navigator && navigator.mediaSession.setPositionState && d > 0 && !engine.remote()) {
    try { navigator.mediaSession.setPositionState({ duration: d, position: Math.min(t, d), playbackRate: video.playbackRate || 1 }); } catch (e) { /* ignore */ }
  }
  if (engine.remote()) maybeSaveProgress(false);
  renderSleep();
}

function itemThumb(item, duration) {
  const style = item.poster ? ` style="background-image:url('${esc(item.poster)}')"` : '';
  const icon = item.poster ? '' : `<svg><use href="#${item.kind === 'hls' || item.kind === 'dash' ? 'i-wave' : 'i-film'}"/></svg>`;
  const dur = duration > 0 ? `<span class="dur">${clock(duration)}</span>` : '';
  return `<div class="thumb"${style}>${icon}${dur}</div>`;
}

function renderQueue() {
  const list = $('queueList');
  if (!queue.length) {
    list.innerHTML = '<li class="empty">Nothing queued. Use “Up Next” on any video to line it up here.</li>';
  } else {
    list.innerHTML = queue.map((item, i) => `
      <li>
        ${itemThumb(item, item.duration)}
        <div class="grow"><div class="item-title">${esc(item.title)}</div><div class="item-sub">${esc(KIND_LABEL[item.kind] || 'Video')} · ${esc(item.isLocal ? 'On this device' : hostOf(item.url))}</div></div>
        <button class="icon-btn" data-q="play" data-i="${i}" aria-label="Play now"><svg><use href="#i-play"/></svg></button>
        <button class="icon-btn" data-q="up" data-i="${i}" aria-label="Move up" ${i === 0 ? 'disabled' : ''}><svg><use href="#i-up"/></svg></button>
        <button class="icon-btn" data-q="remove" data-i="${i}" aria-label="Remove"><svg><use href="#i-x"/></svg></button>
      </li>`).join('');
  }
  $('clearQueue').classList.toggle('hidden', !queue.length);
  const badge = $('queueBadge');
  badge.textContent = queue.length;
  badge.classList.toggle('hidden', !queue.length);
  $('nextBtn').classList.toggle('hidden', !queue.length || !current);
}

function renderHistory() {
  const list = $('historyList');
  if (!watchHistory.length) {
    list.innerHTML = '<li class="empty">Videos you play show up here, so you can pick up where you left off.</li>';
  } else {
    list.innerHTML = watchHistory.map((e, i) => {
      const pct = e.duration > 0 ? Math.min(100, (e.position / e.duration) * 100) : 0;
      const done = e.duration > 0 && e.position >= e.duration - 30;
      const when = new Date(e.date).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
      const state = done ? 'Watched' : (e.position > 30 ? `${clock(e.position)} of ${clock(e.duration)}` : '');
      return `
      <li>
        ${itemThumb(e, e.duration)}
        <div class="grow">
          <div class="item-title">${esc(e.title)}</div>
          <div class="item-sub">${esc([when, hostOf(e.url), state].filter(Boolean).join(' · '))}</div>
          ${pct > 0 ? `<div class="progress"><i style="width:${pct.toFixed(1)}%"></i></div>` : ''}
        </div>
        <button class="icon-btn" data-h="play" data-i="${i}" aria-label="Play"><svg><use href="#i-play"/></svg></button>
        <button class="icon-btn" data-h="remove" data-i="${i}" aria-label="Remove"><svg><use href="#i-x"/></svg></button>
      </li>`;
    }).join('');
  }
  $('clearHistory').classList.toggle('hidden', !watchHistory.length);

  const unfinished = watchHistory.filter((e) => e.position > 30 && !(e.duration > 0 && e.position >= e.duration - 30)).slice(0, 3);
  $('continueCard').classList.toggle('hidden', !unfinished.length);
  $('continueList').innerHTML = unfinished.map((e) => {
    const pct = e.duration > 0 ? Math.min(100, (e.position / e.duration) * 100) : 0;
    return `
      <li>
        ${itemThumb(e, e.duration)}
        <div class="grow">
          <div class="item-title">${esc(e.title)}</div>
          <div class="item-sub">${esc(clock(e.position))} of ${esc(clock(e.duration))}</div>
          <div class="progress"><i style="width:${pct.toFixed(1)}%"></i></div>
        </div>
        <button class="icon-btn" data-h="play" data-url="${esc(e.url)}" aria-label="Continue"><svg><use href="#i-play"/></svg></button>
      </li>`;
  }).join('');
}

function foundVideos(includeShort) {
  if (!found) return [];
  const all = (found.v || []).map((v) => Object.assign({}, v, { kind: detectKind(v.u) }));
  if (includeShort || !settings.hideShort) return all;
  return all.filter((v) => !(v.d > 0 && v.d < 30));
}

function foundItem(v, index) {
  const title = found.t ? (foundVideos(true).length > 1 ? `${found.t} (${index + 1})` : found.t) : '';
  return makeItem(v.u, {
    title, page: found.u, poster: v.p, duration: v.d,
    subs: (found.s || []).map((s) => ({ url: s.u, label: s.l || labelFromURL(s.u), lang: s.g })),
  });
}

function renderFound() {
  const has = !!(found && ((found.v && found.v.length) || (found.f && found.f.length)));
  $('foundEmpty').classList.toggle('hidden', has);
  $('foundBody').classList.toggle('hidden', !has);
  const badgeCount = found && found.fresh ? foundVideos(false).length : 0;
  $('findBadge').textContent = badgeCount;
  $('findBadge').classList.toggle('hidden', !badgeCount);
  if (!has) return;

  $('foundTitle').textContent = found.t || 'Videos found';
  $('foundPage').textContent = hostOf(found.u);
  const showAll = $('showShort').checked;
  const all = foundVideos(true);
  const vids = foundVideos(showAll);
  const hiddenCount = all.length - foundVideos(false).length;
  $('showShortRow').classList.toggle('hidden', !(settings.hideShort && hiddenCount > 0));
  $('showShortText').textContent = `Show ${hiddenCount} short clip${hiddenCount === 1 ? '' : 's'} (likely ads)`;

  $('foundList').innerHTML = vids.length ? vids.map((v) => {
    const idx = all.findIndex((x) => x.u === v.u);
    const item = makeItem(v.u, { poster: v.p });
    return `
      <li>
        ${itemThumb(item, v.d)}
        <div class="grow">
          <div class="item-title">${esc(labelFromURL(v.u) || KIND_LABEL[v.kind] || 'Video')}</div>
          <div class="item-sub">${esc([KIND_LABEL[v.kind] || 'Video', v.d > 0 ? clock(v.d) : '', hostOf(v.u)].filter(Boolean).join(' · '))}</div>
        </div>
        <button class="icon-btn" data-f="play" data-i="${idx}" aria-label="Play"><svg><use href="#i-play"/></svg></button>
        <button class="icon-btn" data-f="queue" data-i="${idx}" aria-label="Add to Up Next"><svg><use href="#i-plus"/></svg></button>
      </li>`;
  }).join('') : '<li class="empty">No playable videos on that page. If it uses an embedded player, open it below.</li>';

  const frames = found.f || [];
  $('framesBox').classList.toggle('hidden', !frames.length);
  $('framesList').innerHTML = frames.map((f) => `
    <li>
      <div class="grow"><div class="item-title">${esc(f.t || hostOf(f.u))}</div><div class="item-sub mono">${esc(f.u)}</div></div>
      <a class="btn" href="${esc(f.u)}" target="_blank" rel="noopener">Open</a>
    </li>`).join('');
}

function renderSites() {
  $('sitesList').innerHTML = sites.length ? sites.map((s, i) => `
    <li>
      <div class="grow"><div class="item-title">${esc(s.title)}</div><div class="item-sub">${esc(hostOf(s.url))}</div></div>
      <a class="btn" href="${esc(s.url)}" target="_blank" rel="noopener">Open</a>
      <button class="icon-btn" data-s="remove" data-i="${i}" aria-label="Remove"><svg><use href="#i-x"/></svg></button>
    </li>`).join('') : '<li class="empty">Add sites you watch often.</li>';
}

function renderDiagnostics() {
  const rows = [
    ['Secure connection (needed for casting)', window.isSecureContext],
    ['AirPlay', airplay.supported],
    ['Chromecast', cc.ready],
    ['Built-in HLS streams', !!video.canPlayType('application/vnd.apple.mpegurl')],
    ['Lock screen controls', 'mediaSession' in navigator],
    ['Installed on Home Screen', isStandalone()],
  ];
  $('diag').innerHTML = rows.map(([name, ok]) => `<span>${esc(name)}</span><span class="${ok ? 'yes' : 'no'}">${ok ? 'Yes' : 'No'}</span>`).join('');
}

function renderAll() {
  renderPlayer();
  renderQueue();
  renderHistory();
  renderFound();
  renderSites();
  renderCastState();
}

// ---------------------------------------------------------------- tabs

function showTab(name) {
  document.querySelectorAll('section.view').forEach((s) => s.classList.toggle('active', s.id === 'view-' + name));
  document.querySelectorAll('nav.tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
  if (name === 'find' && found && found.fresh) {
    found.fresh = false;
    store.set('found', found);
    renderFound();
  }
}

document.querySelectorAll('nav.tabs button').forEach((b) => b.addEventListener('click', () => {
  showTab(b.dataset.tab);
  window.scrollTo({ top: 0 });
}));
document.addEventListener('click', (e) => {
  const go = e.target.closest('[data-goto]');
  if (go) { e.preventDefault(); showTab(go.dataset.goto); }
});

// ---------------------------------------------------------------- controls wiring

$('playPause').addEventListener('click', () => engine.toggle());
$('back30').addEventListener('click', () => engine.skip(-30));
$('back10').addEventListener('click', () => engine.skip(-10));
$('fwd10').addEventListener('click', () => engine.skip(10));
$('fwd30').addEventListener('click', () => engine.skip(30));
$('stopBtn').addEventListener('click', () => { maybeSaveProgress(true); engine.stop(); });
$('nextBtn').addEventListener('click', playNextInQueue);
$('startOverBtn').addEventListener('click', () => { engine.seek(0); $('resumeBanner').classList.add('hidden'); });
$('seek').addEventListener('input', () => { seeking = true; $('tCur').textContent = clock(Number($('seek').value)); });
$('seek').addEventListener('change', () => { engine.seek(Number($('seek').value)); seeking = false; });
$('volume').addEventListener('change', (e) => engine.setVolume(Number(e.target.value)));
$('speedSelect').addEventListener('change', (e) => engine.setRate(Number(e.target.value)));
$('sleepSelect').addEventListener('change', (e) => setSleep(e.target.value));

$('airplayBtn').addEventListener('click', () => {
  if (!current) { toast('Play a video first'); return; }
  if (video.webkitShowPlaybackTargetPicker) video.webkitShowPlaybackTargetPicker();
  else if (video.remote) video.remote.prompt().catch(() => {});
});
$('chromecastBtn').addEventListener('click', () => {
  if (!cc.ready) return;
  if (cc.connected) {
    window.cast.framework.CastContext.getInstance().endCurrentSession(true);
    return;
  }
  window.cast.framework.CastContext.getInstance().requestSession().catch(() => {});
});
$('remoteBtn').addEventListener('click', () => {
  if (video.remote) video.remote.prompt().catch((err) => toast(err && err.name === 'NotSupportedError' ? 'This video can’t be cast from this browser.' : 'No TV chosen'));
});

$('queueCurrentBtn').addEventListener('click', () => { if (current) addToQueue(current); });
$('copyLinkBtn').addEventListener('click', async () => {
  if (!current || current.isLocal) { toast('Nothing to copy'); return; }
  try { await navigator.clipboard.writeText(current.url); toast('Link copied'); } catch (e) { toast('Couldn’t copy'); }
});

$('pasteBtn').addEventListener('click', async () => {
  try {
    const text = await navigator.clipboard.readText();
    if (text) $('linkInput').value = text.trim();
  } catch (e) {
    $('linkInput').focus();
    toast('Press and hold in the box, then tap Paste');
  }
});

function linkFromInput() {
  const text = $('linkInput').value.trim();
  const match = text.match(/https?:\/\/\S+/);
  return match ? match[0] : '';
}

$('playLinkBtn').addEventListener('click', () => {
  const url = linkFromInput();
  if (!url) { toast('Paste a link that starts with http'); return; }
  if (!looksLikeMedia(url)) {
    showTab('find');
    toast('That looks like a web page. Open it and use Find videos.');
    window.open(url, '_blank', 'noopener');
    return;
  }
  playItem(makeItem(url));
});
$('queueLinkBtn').addEventListener('click', () => {
  const url = linkFromInput();
  if (!url) { toast('Paste a link that starts with http'); return; }
  addToQueue(makeItem(url));
});

$('fileInput').addEventListener('change', (e) => {
  const file = e.target.files && e.target.files[0];
  e.target.value = '';
  if (!file) return;
  const url = URL.createObjectURL(file);
  playItem(makeItem(url, {
    title: file.name.replace(/\.[a-z0-9]+$/i, ''),
    kind: (file.type || '').startsWith('audio/') ? 'audio' : 'mp4',
    isLocal: true,
  }));
});

$('queueList').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-q]');
  if (!b) return;
  const i = Number(b.dataset.i);
  if (b.dataset.q === 'play') {
    const [item] = queue.splice(i, 1);
    saveQueue();
    renderQueue();
    playItem(item);
  } else if (b.dataset.q === 'up' && i > 0) {
    [queue[i - 1], queue[i]] = [queue[i], queue[i - 1]];
    saveQueue();
    renderQueue();
  } else if (b.dataset.q === 'remove') {
    queue.splice(i, 1);
    saveQueue();
    renderQueue();
  }
});
$('clearQueue').addEventListener('click', () => { queue = []; saveQueue(); renderQueue(); });

function playFromHistory(e) {
  playItem(makeItem(e.url, { title: e.title, kind: e.kind, page: e.page, poster: e.poster, duration: e.duration }));
}
function onHistoryClick(ev) {
  const b = ev.target.closest('button[data-h]');
  if (!b) return;
  const entry = b.dataset.url ? watchHistory.find((x) => x.url === b.dataset.url) : watchHistory[Number(b.dataset.i)];
  if (!entry) return;
  if (b.dataset.h === 'play') playFromHistory(entry);
  else if (b.dataset.h === 'remove') { watchHistory = watchHistory.filter((x) => x !== entry); saveHistory(); renderHistory(); }
}
$('historyList').addEventListener('click', onHistoryClick);
$('continueList').addEventListener('click', onHistoryClick);
$('clearHistory').addEventListener('click', () => { watchHistory = []; saveHistory(); renderHistory(); });

$('foundList').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-f]');
  if (!b) return;
  const idx = Number(b.dataset.i);
  const v = foundVideos(true)[idx];
  if (!v) return;
  const item = foundItem(v, idx);
  if (b.dataset.f === 'play') playItem(item); else addToQueue(item);
});
$('showShort').addEventListener('change', renderFound);

$('sitesList').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-s]');
  if (!b) return;
  sites.splice(Number(b.dataset.i), 1);
  store.set('sites', sites);
  renderSites();
});
$('addSiteForm').addEventListener('submit', (e) => {
  e.preventDefault();
  let url = $('siteInput').value.trim();
  if (url && !/^https?:\/\//i.test(url)) url = 'https://' + url;
  if (!isWebURL(url)) { toast('Enter a web address'); return; }
  sites.push({ title: hostOf(url), url });
  store.set('sites', sites);
  $('siteInput').value = '';
  renderSites();
});

// Settings
function bindToggle(id, key, after) {
  const el = $(id);
  el.checked = !!settings[key];
  el.addEventListener('change', () => {
    settings[key] = el.checked;
    saveSettings();
    if (after) after();
  });
}
bindToggle('resumeToggle', 'resume');
bindToggle('hideShortToggle', 'hideShort', renderFound);
bindToggle('autoNextToggle', 'autoNext');
$('shuffleToggle').checked = shuffle;
$('shuffleToggle').addEventListener('change', (e) => { shuffle = e.target.checked; store.set('shuffle', shuffle); });
$('repeatSelect').value = repeatMode;
$('repeatSelect').addEventListener('change', (e) => { repeatMode = e.target.value; store.set('repeat', repeatMode); });
$('resetAll').addEventListener('click', () => {
  if (!$('resetAll').dataset.confirm) {
    $('resetAll').dataset.confirm = '1';
    $('resetAll').textContent = 'Tap again to erase everything';
    return;
  }
  try { Object.keys(localStorage).filter((k) => k.startsWith('castpilot.')).forEach((k) => localStorage.removeItem(k)); } catch (e) { /* ignore */ }
  location.reload();
});

// ---------------------------------------------------------------- the "Find videos" bookmarklet

/* Runs inside the website the user is looking at. It must not contain "#" or "%" characters
 * (bookmark addresses treat them specially) and every statement ends with ";" so it survives
 * being squashed onto one line. */
function finderSource() {
  var A = '__APP__';
  var out = [], seen = {}, subs = [], ss = {}, frames = [];
  var M = /\.(m3u8|mpd|mp4|m4v|mov|webm|mkv|mp3|m4a|aac|ogg|oga|wav|flac)([?&\x23]|$)/i;
  var S = /\.(vtt|srt)$/i;
  var SEG = /\.(ts|m4s|cmfv|cmfa|key|jpg|jpeg|png|gif|webp|js|css|json)$/i;
  var AD = /(doubleclick|googlesyndication|googleads|imasdk|adservice|adsystem|adnxs|springserve|spotx|tremorhub|innovid|teads|moatads|pubmatic)/i;
  function abs(u) { try { return new URL(u, document.baseURI).href; } catch (e) { return null; } }
  function path(u) { try { return new URL(u).pathname; } catch (e) { return String(u); } }
  function add(u, h, d, p) { u = abs(u); if (!u || !/^https?:/i.test(u) || seen[u] || AD.test(u)) { return; } seen[u] = 1; out.push({ u: u, h: h, d: d || 0, p: p || '' }); }
  function sub(u, l, g) { u = abs(u); if (!u || !/^https?:/i.test(u) || ss[u]) { return; } ss[u] = 1; subs.push({ u: u, l: l || '', g: g || '' }); }
  function scan(doc) {
    var vids = doc.querySelectorAll('video,audio');
    for (var i = 0; i < vids.length; i++) {
      var v = vids[i];
      var d = isFinite(v.duration) ? v.duration : 0;
      var p = v.poster ? abs(v.poster) : '';
      var s = v.currentSrc || v.src;
      if (s && !/^(blob|data):/i.test(s)) { add(s, 'element', d, p); }
      var srcs = v.querySelectorAll('source');
      for (var j = 0; j < srcs.length; j++) { if (srcs[j].src && !/^(blob|data):/i.test(srcs[j].src)) { add(srcs[j].src, 'element', d, p); } }
      var tr = v.querySelectorAll('track');
      for (var k = 0; k < tr.length; k++) { if (tr[k].src) { sub(tr[k].src, tr[k].label, tr[k].srclang); } }
    }
    var links = doc.querySelectorAll('a[href]');
    for (var m = 0; m < links.length && m < 3000; m++) { if (M.test(path(links[m].href))) { add(links[m].href, 'link', 0, ''); } }
    var og = doc.querySelectorAll('meta[property^="og:video"]');
    for (var n = 0; n < og.length; n++) { if (og[n].content && /^https?:/i.test(og[n].content)) { add(og[n].content, 'meta', 0, ''); } }
    var fr = doc.querySelectorAll('iframe');
    for (var f = 0; f < fr.length; f++) {
      var ok = false;
      try { if (fr[f].contentDocument) { scan(fr[f].contentDocument); ok = true; } } catch (e) { ok = false; }
      if (!ok && fr[f].src && /^https?:/i.test(fr[f].src) && fr[f].offsetWidth > 150 && frames.length < 10) { frames.push({ u: fr[f].src, t: fr[f].title || '' }); }
    }
  }
  try { scan(document); } catch (e) { out = out; }
  try {
    var es = performance.getEntriesByType('resource');
    for (var q = 0; q < es.length; q++) {
      var nm = es[q].name;
      var pa = path(nm);
      if (S.test(pa)) { sub(nm, '', ''); } else if (!SEG.test(pa) && M.test(nm)) { add(nm, 'network', 0, ''); }
    }
  } catch (e) { out = out; }
  var data = { t: document.title, u: location.href, v: out.slice(0, 40), s: subs.slice(0, 20), f: frames };
  var url = A + '\x23import=' + encodeURIComponent(JSON.stringify(data));
  var w = window.open(url, '_blank');
  if (!w) { location.href = url; }
}

function appURL() {
  return location.origin + location.pathname.replace(/index\.html$/, '');
}

function bookmarkletCode() {
  const body = finderSource.toString().replace(/\s*\n\s*/g, ' ').replace('__APP__', appURL());
  return 'javascript:(' + body + ')();';
}

function setupBookmarklet() {
  const code = bookmarkletCode();
  $('bookmarkletCode').textContent = code;
  $('bookmarkletLink').setAttribute('href', code);
  $('bookmarkletLink').addEventListener('click', (e) => { e.preventDefault(); toast('Drag this link to your bookmarks bar'); });
  $('copyBookmarklet').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(code);
      toast('Copied. Now follow steps 2–4.');
    } catch (e) {
      const range = document.createRange();
      range.selectNodeContents($('bookmarkletCode'));
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      $('bookmarkletCode').closest('details').open = true;
      toast('Select the code below and copy it');
    }
  });
}

// ---------------------------------------------------------------- links into the app

function handleIncoming() {
  const hash = location.hash || '';
  if (hash.startsWith('#import=')) {
    try {
      const data = JSON.parse(decodeURIComponent(hash.slice(8)));
      if (data && typeof data === 'object') {
        found = { t: String(data.t || ''), u: String(data.u || ''), v: Array.isArray(data.v) ? data.v : [], s: Array.isArray(data.s) ? data.s : [], f: Array.isArray(data.f) ? data.f : [], date: Date.now(), fresh: true };
        store.set('found', found);
        window.history.replaceState(null, '', location.pathname);
        renderFound();
        showTab('find');
        const n = foundVideos(false).length;
        toast(n ? `Found ${n} video${n === 1 ? '' : 's'}` : 'No videos found on that page');
        if (n === 1) {
          const all = foundVideos(true);
          const only = foundVideos(false)[0];
          const idx = all.findIndex((x) => x.u === only.u);
          playItem(foundItem(only, idx));
        }
        return;
      }
    } catch (e) {
      toast('Couldn’t read the videos from that page');
    }
  }
  const params = new URLSearchParams(location.search);
  const title = params.get('title') || '';
  const play = params.get('v') || params.get('play');
  const q = params.get('q') || params.get('queue');
  const shared = params.get('url') || ((params.get('text') || '').match(/https?:\/\/\S+/) || [])[0];
  let handled = false;
  if (play && isWebURL(play)) { playItem(makeItem(play, { title })); handled = true; }
  if (q && isWebURL(q)) { addToQueue(makeItem(q, { title })); handled = true; }
  if (!handled && shared && isWebURL(shared)) {
    if (looksLikeMedia(shared)) playItem(makeItem(shared, { title }));
    else { $('linkInput').value = shared; toast('Open the page and use Find videos to pick its video'); }
    handled = true;
  }
  if (handled || location.search) window.history.replaceState(null, '', location.pathname);
}
window.addEventListener('hashchange', handleIncoming);

// ---------------------------------------------------------------- install hint, start-up

function isStandalone() {
  return window.navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
}

function setupInstallHint() {
  const ios = /iPhone|iPad|iPod/i.test(navigator.userAgent);
  if (ios && !isStandalone() && !store.get('installHintDismissed', false)) $('installHint').hidden = false;
  $('dismissInstall').addEventListener('click', () => {
    $('installHint').hidden = true;
    store.set('installHintDismissed', true);
  });
}

function setupShortcutExamples() {
  const base = appURL();
  $('shortcutPlay').textContent = `${base}?v=https://example.com/video.mp4&title=My%20video`;
  $('shortcutQueue').textContent = `${base}?q=https://example.com/video.mp4`;
}

$('autoNextToggle').checked = !!settings.autoNext;
setupMediaSessionHandlers();
setupBookmarklet();
setupShortcutExamples();
setupInstallHint();
initChromecast();
renderAll();
renderDiagnostics();
handleIncoming();
setInterval(renderPlayer, 500);
document.addEventListener('visibilitychange', () => { if (document.hidden) maybeSaveProgress(true); });
window.addEventListener('pagehide', () => maybeSaveProgress(true));

if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

// Exposed for automated tests.
window.CastPilot = { detectKind, srtToVtt, parseVariants, bookmarkletCode, finderSource, makeItem, dequeueNext, get queue() { return queue; } };

# CastPilot (web app)

The web version of CastPilot. You can add it to your iPhone's Home Screen; nothing goes through the App Store and there's no sideloading.

## What it does

- **Play any video link** (`.mp4`, `.m3u8`, `.webm`, `.mov`, audio) and send it to a TV:
  - **AirPlay** from Safari on iPhone, iPad or Mac: Apple TV and AirPlay TVs (many Samsung, LG, Sony, Vizio and Roku models).
  - **Chromecast / Google TV** from Chrome on Android or a computer, with a TV volume control. (Chromecast can't be reached from an iPhone browser.)
- **Find videos on websites** with the *Find videos* Safari bookmark (a bookmarklet). It collects the page's videos, streams and subtitles and opens them in CastPilot. It hides short clips (likely ads) and lists embedded players to open.
- **Up Next queue** with reordering, repeat (all or one), shuffle and auto-play.
- **Resume where you left off**, plus a history with progress bars and a *Continue watching* list.
- **Playback speed** (0.5×–2×), **sleep timer** (15–90 min or end of video), **quality picker** for HLS streams, and **subtitles** from the page or from a `.srt`/`.vtt` file.
- **Lock screen and Control Center controls.**
- **Play videos from the phone** (with AirPlay).
- **Links for Shortcuts:** `?v=<video url>&title=<title>` plays, `?q=<video url>` queues. On Android, CastPilot also shows up in the Share menu once installed.
- Works offline for the app itself, and keeps everything in your own browser.

## What it can't do (compared with the iPhone app)

Browsers aren't allowed to search your home network for devices or reach them directly. So DLNA smart TVs and Roku's own casting aren't available, and there's no "iPhone relay" for websites that block TVs. Use AirPlay instead, which most recent TVs support, or the native app in `../CastPilot`.

## Putting it online

It's plain static files (`index.html`, `app.js`, `sw.js`, `manifest.webmanifest`, icons) with no build step. Any HTTPS host works:

- **GitHub Pages:** the workflow `.github/workflows/castpilot-web-pages.yml` publishes this folder whenever `main` changes. Turn it on once under **Settings › Pages › Source: GitHub Actions**. Pages is free for public repositories; private ones need a paid GitHub plan.
- **Netlify Drop:** drag this folder onto https://app.netlify.com/drop.

Then open the address in Safari on your iPhone and tap **Share › Add to Home Screen**.

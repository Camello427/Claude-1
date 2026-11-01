# CastPilot: cast web videos from iPhone to your TV

CastPilot is an iPhone app with a built-in web browser. It finds the videos on whatever page you open and plays them on your TV.

It works with:

| Device | How | Controls |
|---|---|---|
| **Chromecast, Google TV, Android TV**, TVs with Chromecast built-in | Google Cast protocol, built in (no Google SDK) | Play/pause, seek, ±10 s/30 s, volume, stop |
| **Smart TVs with DLNA**: most Samsung, LG, Sony, Panasonic, Philips, Hisense, TCL; also Xbox, Kodi, etc. | UPnP AVTransport | Play/pause, seek, ±10 s/30 s, volume, stop |
| **Roku** players and Roku TVs | Roku External Control Protocol | Play/pause, stop (Roku doesn't allow seeking from outside) |
| **Apple TV and AirPlay TVs** | iOS AirPlay | Full iOS player controls |

## Features

**Finding and casting videos**
- **Video finder in the browser.** It watches `<video>` tags and the page's network requests (HLS `.m3u8`, DASH `.mpd`, MP4, WebM, MOV, MKV, audio). This includes videos inside embedded players.
- **One-tap casting.** A "videos found" button shows up on any page with video. Tap a video to see its options, then cast.
- **Quality picker** for HLS streams (4K, 1080p, 720p…), on the TV and on the phone.
- **Subtitles.** It finds `.vtt`/`.srt` files on the page, or you can load your own from Files. They're sent as WebVTT to Chromecast (with an on/off toggle) and as SRT to Samsung, LG and other DLNA TVs.
- **Hide short clips.** Videos under 30 seconds are usually ads, so they're tucked away.
- **Auto-cast** (optional). The main video on a page goes to your TV by itself.
- **Cast a link.** Paste any `.mp4` or `.m3u8` address.
- **Cast videos from your iPhone**, from Photos, the Files app or downloads.
- **Download videos** (direct video files) to watch or cast later.

**While it plays**
- **Remote control.** Play/pause, seek, ±10 s/30 s, volume and stop, plus a mini "now casting" bar while you keep browsing.
- **Up Next queue** with "Play next", reordering, **repeat** (all or one), **shuffle**, and auto-advance.
- **Resume where you left off**, with a "Start over" button, plus a **Recently cast** list and a "Continue watching" card on the start page.
- **Playback speed** from 0.5× to 2× (Chromecast).
- **Sleep timer.** 15–90 minutes, or the end of the video.
- **Lock screen & Control Center controls** for the TV.
- **Full Roku remote:** arrows, OK, Back, Home, rewind/fast-forward, instant replay, TV volume, and typing into search boxes.
- **Move playback** to another TV mid-video.
- **iPhone relay.** A small web server on the phone that passes video to the TV with the website's Referer, User-Agent, cookies and CORS headers. It also rewrites HLS playlists so every segment goes through it. This fixes most "the TV says it can't play this" problems. It's on automatically for HLS streams, and the remote has a **Try again through iPhone relay** button.

**Browser**
- **Tabs and private tabs**, with page previews.
- **Find on page**, bookmarks, history, desktop-site mode, a choice of search engine.
- **Browser identity switcher** (iPad, Mac, Android or Windows) for sites that only serve video to certain browsers.
- **Pop-up and redirect blocker.** It stops pop-up windows and pop-unders, and stops pages from suddenly sending you to an ad site. A banner shows what was blocked, with an **Open** button; an address-bar shield counts blocks per page; and you can allow pop-ups on sites you trust.
- **Ad blocker** with a built-in list of ad and pop-under networks.
- **Face ID lock** for the whole app.
- **Links from other apps and Shortcuts:** `castpilot://open?url=…`, `castpilot://cast?url=…&title=…`, `castpilot://queue?url=…` (see Settings › Shortcuts & other apps).

## Two ways to get it on your iPhone

### Option A: you have a Mac (recommended)

1. Install **Xcode** from the Mac App Store, and XcodeGen: `brew install xcodegen`
2. In this folder, run:
   ```sh
   xcodegen generate
   open CastPilot.xcodeproj
   ```
3. In Xcode, select the **CastPilot** target, then **Signing & Capabilities**:
   - Sign in with your Apple ID and pick it as the **Team** (a free Apple ID works).
   - Change the **Bundle Identifier** to something unique, e.g. `com.yourname.castpilot`.
4. Plug in your iPhone, select it at the top of Xcode, and press **Run** (▶).
5. On the iPhone, the first time only: **Settings › General › VPN & Device Management**, then trust your developer certificate. Also turn on **Developer Mode** if iOS asks.

With a free Apple ID the app works for 7 days, then you press Run again. A paid Apple Developer account ($99/yr) makes that 1 year and allows TestFlight/App Store.

### Option B: no Mac

Every push to GitHub builds the app on a GitHub-hosted Mac (`.github/workflows/castpilot-ios.yml`) and attaches an **unsigned `.ipa`**:

1. Open the repo on GitHub, then **Actions › CastPilot iOS build**, then the latest green run.
2. Download the **CastPilot-unsigned-ipa** artifact and unzip it.
3. Install it with **Sideloadly** (Windows/Mac) or **AltStore**. Both sign the app with your own Apple ID as they install it.

## First launch

- iOS asks to let CastPilot **find devices on your local network**. Tap **Allow**, or no TVs will show up. You can change it later under Settings › Privacy & Security › Local Network.
- Your iPhone and TV must be on the **same Wi-Fi network**.

## How to use

1. Type a website or search in the address bar.
2. Start the video on the page. A blue **"N videos found — tap to cast"** button appears.
3. Tap it, pick the video (streams marked *HLS* are usually the main one), then **Cast to…**.
4. Pick your TV. The remote opens. Close it any time and keep browsing; the bar at the bottom brings it back.

To play on an **Apple TV or AirPlay TV**: open the cast list, tap the AirPlay icon and pick your TV, then choose **Play on iPhone / AirPlay** for a video.

## Limitations (shared by every app of this kind)

- **DRM-protected services** (Netflix, Disney+, Prime Video, Max, most live-TV apps) can't be cast. Use their own apps or cast buttons. YouTube is better cast from the YouTube app.
- **DLNA TV formats vary.** Most TVs play MP4 (H.264/AAC). HLS support depends on the model. If one fails, try the iPhone relay or another video on the page.
- **Roku** casting uses Roku's built-in "Play on Roku" channel. On recent Roku TVs, **AirPlay** gives a better experience.
- **Device discovery.** Chromecasts are found via Bonjour. DLNA TVs and Rokus are found by asking every address on your home network directly, because apps need special permission from Apple to use multicast. If a TV still doesn't appear, use **Add a device by IP address**.

## How it's built

Plain SwiftUI with no third-party dependencies, iOS 17+.

```
Sources/
  App/          AppState (ties everything together), app entry point
  Browser/      WKWebView model, injected video-finder JavaScript, ad blocker
  Casting/
    Chromecast/ Cast v2 protocol: TLS channel, protobuf framing, media controller
    DLNA/       SSDP discovery (multicast + unicast sweep), UPnP description parser, AVTransport/RenderingControl SOAP
    Roku/       ECP controller
    DeviceManager, CastSession (remote-control state)
  Server/       iPhone relay HTTP server (proxy + HLS rewriting + local files), background keep-alive
  Views/        Browser, video list, device picker, remote, phone player, library, settings, local videos
Config/Info.plist   Local-network, Bonjour, ATS and background-audio settings
project.yml         XcodeGen project definition
```

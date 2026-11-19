# MacRemote

View and control a Mac from a web browser over the internet. MacRemote runs on the Mac you want to access. The other device opens an invitation link and requests access, which you approve on the Mac.

Built by [kuatsaparali](https://github.com/kuatsaparali).

## Download

Download the app from [GitHub Releases](https://github.com/kuatsaparali/RemoteMac/releases/latest).

| Your Mac | Download |
| --- | --- |
| Apple Silicon, including M1, M2, M3, M4 and later | [MacRemote for Apple Silicon](https://github.com/kuatsaparali/RemoteMac/releases/download/v0.7.0/MacRemote-0.7.0-macOS-arm64.zip) |
| Intel processor | [MacRemote for Intel](https://github.com/kuatsaparali/RemoteMac/releases/download/v0.7.0/MacRemote-0.7.0-macOS-x86_64.zip) |

The standalone downloads require macOS 15 Sequoia or later and an internet connection, matching the bundled cloudflared binaries. Find your processor in **Apple menu → About This Mac**. Release downloads include the connection services, so you can launch the app from Finder without installing Homebrew, Node.js or Cloudflare Tunnel.

## Open the app

1. Download the ZIP for your processor and double-click it to extract **MacRemote.app**.
2. Drag **MacRemote.app** to **Applications** and open it.
3. Allow **Screen Recording** and **Accessibility** when prompted. Use the **Разрешить** (Allow) buttons in MacRemote to open the corresponding macOS settings.
4. If macOS asks you to quit and reopen MacRemote after granting permission, do so. Return to the app and check that both permissions show **Включено** (Enabled).

This release uses an ad hoc signature and has not been notarized by Apple. If macOS blocks the first launch and you choose to proceed, open **System Settings → Privacy & Security → Open Anyway** after trying to open it. [Apple's first-launch instructions](https://support.apple.com/en-us/102445)

The Mac app supports **Russian and English**. Use the **Русский / English** selector in the top-right corner to switch instantly. Your choice is saved for the next launch, and the initial language follows your macOS language. Buttons, setup instructions, session status and app error messages follow your selection. macOS system menus and permission dialogs use the macOS language settings. The viewer can choose **Русский** or **English** in the browser header. The browser remembers the choice for the same address.

## Start a session

1. On the Mac you want to control, click **Создать ссылку** (Create link). The app starts its bundled relay and a temporary Cloudflare Tunnel. Creating the connection can take up to 90 seconds.
2. Click **Скопировать ссылку** (Copy link) and send the invitation to the device you will use to connect.
3. Open the complete invitation in a browser on that device, including everything after `#`, and click **Подключиться** (Connect).
4. On the Mac, click **Разрешить доступ** (Allow access) to approve the request. The browser then displays the Mac's main screen and plays its system audio when supported. Use **Sound on / Sound off** in the browser to mute or unmute playback on the viewing device.
5. Click inside the remote screen to send mouse and keyboard input. Press **Shift + Esc** to release keyboard focus back to the browser.
6. To write to each other, open **Chat** in the browser or use the chat in the Mac app. On the Mac, **Session chat** turns chat on or off for both participants.
7. To finish, click **Завершить сеанс** (End session) on the Mac or **Отключиться** (Disconnect) in the browser.

Keep MacRemote open and the Mac awake and unlocked during the session. Closing the app stops its connection services. Each invitation accepts one viewer. Create a new link after a disconnection or declined request.

The browser chat opens beside the screen on desktop and below it on phones. Hiding chat leaves the session running. The last 60 messages are kept in memory until the session ends.

On a touchscreen, a tap sends a mouse click. Typing requires a physical keyboard. Some keyboard shortcuts are intercepted by the browser or operating system. The remote Mac's selected keyboard layout determines the typed text.

## Troubleshooting

- **The connection takes too long.** Check your internet connection and try creating another link. Temporary tunnels depend on Cloudflare availability and may be restricted by your network.
- **The viewer cannot open the invitation.** Copy the entire link with the app's Copy link button. After restarting a session, use its new invitation. If the browser reports a DNS error for the temporary hostname, try another network, such as mobile data, or retry after your network refreshes its DNS cache.
- **Permissions show as disabled.** Check MacRemote under Screen Recording and Accessibility in System Settings, then quit and reopen it. An update may require you to remove the old permission entry and add the new app.
- **The screen or input stops working.** Confirm that the Mac is awake and unlocked and that the permissions are enabled, then create a new session.

## Connection and privacy

MacRemote captures the main display with ScreenCaptureKit and injects mouse and keyboard events through Core Graphics after you approve access. Screen video, system audio, chat messages and input commands are encrypted with AES-GCM between the Mac and browser. The stream excludes the microphone. The session encryption key is included in the invitation's URL fragment after `#`. Treat the full invitation as private.

The bundled relay listens on a randomly assigned loopback port. A temporary Cloudflare Tunnel makes that service reachable through HTTPS. The browser client is delivered through the same tunnel, and Cloudflare participates in serving that client. For startup checks, the app can fall back to Cloudflare public DNS if the local resolver cannot find the new tunnel hostname. The temporary hostname changes for each session. [Cloudflare Tunnel documentation](https://developers.cloudflare.com/tunnel/concepts/#quick-tunnels)

This version supports one main display and one viewer, at a maximum capture size of 1440 × 960. Compatible browsers receive H.264 video encoded through VideoToolbox at up to 120 frames per second. On phones and tablets with touch-first browsers, capture is capped at 1024 × 720 and 60 fps with a lower target bitrate. These browsers can use the platform H.264 decoder. Desktop viewers prefer software decoding to avoid buffering sparse screen updates. If video decoding is unavailable or fails, the session switches to JPEG at up to 20 frames per second. New hosts and viewers use encrypted frame acknowledgments to limit the stream to eight unacknowledged H.264 frames or two JPEG frames, so a slow connection does not build up an old-frame backlog. Legacy viewers continue to receive JPEG at up to 12 frames per second. The actual frame rate depends on the source display, the viewing device and the connection. System audio uses a short playback buffer to keep the picture and sound in sync. On supported iPhone browsers, MacRemote requests media playback so the audio can play in Silent Mode. If the stream is still silent, check the media output volume and try opening the invitation directly in Safari.

## Use your own relay

Enable **Использовать свой сервер** (Use your own server) in the app to enter an HTTPS relay address and its host key. This mode uses your existing relay instead of starting the bundled services.

To run the relay from source, install Node.js 22 or later and run the following commands from the repository root.

```bash
cd relay
npm ci
npm start
```

The relay listens on `127.0.0.1:8787` by default. Its address and a generated host key are printed at startup. For internet access, configure an HTTPS reverse proxy that forwards WebSocket upgrades for `/ws` and serves the relay at the domain root. `PORT`, `BIND_HOST` and `MACREMOTE_HOST_KEY` can be set through environment variables. Keep the host key on the host Mac and relay.

## Build from source

Install Apple's Command Line Tools and use a macOS 13 or later SDK.

```bash
git clone https://github.com/kuatsaparali/RemoteMac.git
cd RemoteMac
./macos/build.sh
```

This builds the native app for the current architecture in `macos/dist/MacRemote.app`. For a source-only build, use an external relay through **Use your own server**. Use the standalone packaging command below to bundle the connection services with the app.

To build the standalone release downloads, install Python 3 and Node.js 22 or later, then run the following command on macOS.

```bash
python3 macos/package-release.py
```

The script builds a universal native executable, downloads pinned Node.js and cloudflared archives from their upstream sources, verifies their SHA-256 checksums and packages separate Apple Silicon and Intel apps. ZIP files and `SHA256SUMS.txt` are written to `macos/release/`. Downloaded dependencies are cached under `macos/.release-cache/`. To choose a different installed SDK, set `MACREMOTE_SDKROOT`.

Release apps contain Node.js v22.23.5, cloudflared 2026.11.0 and ws 8.23.0. Their license notices are included in each app under `Contents/Resources/Licenses`. The packaging script uses an ad hoc signature by default. A Developer ID signing identity can be supplied through `MACREMOTE_SIGN_IDENTITY`, with notarization handled separately.

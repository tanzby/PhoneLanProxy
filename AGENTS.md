# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

PhoneLanProxy is an iOS TCP proxy: a Mac connects to a proxy port on the iPhone, and the iPhone forwards traffic out over its own network connection (Wi-Fi/cellular). A single fixed port (`10808`) auto-detects the protocol by the first byte of the connection:

- No-auth SOCKS5 `CONNECT`
- HTTP/1.1 absolute-form requests
- HTTPS via `CONNECT` (opaque TCP tunnel — the phone never decrypts TLS)

Not supported: UDP, TLS interception outside of `CONNECT` tunneling, VPN/TUN. There is no authentication or encryption on the proxy itself — it's only meant for a trusted LAN.

## Commands

Core library (Swift Package, `swift-tools-version: 6.0`, Swift 6 strict concurrency):

```sh
swift build
swift test
swift test --filter SOCKS5ProtocolTests        # run one test target/class
swift test --filter HTTPProxyProtocolTests/testCONNECTParsesIPv6Authority  # run one test method
```

App target (SwiftUI iOS app; not part of the SPM manifest, lives in `App/`) plus the `PhoneLanProxyWidgets` Live Activity extension (`Widgets/`):

- Open `PhoneLanProxy.xcodeproj` in Xcode, select the `PhoneLanProxy` scheme (it builds and embeds the widget extension).
- Signing: team `WU2N563FGA` (free Personal Team — 7-day profiles, no NetworkExtension). Bundle ids are `com.zubingtan.PhoneLanProxy` and `com.zubingtan.PhoneLanProxy.Widgets`; the extension id must stay prefixed by the app id. Deployment target iOS 17+.
- Run on simulator or device, tap "启动代理" (start proxy) to listen on TCP `10808`.

```sh
xcodebuild test -project PhoneLanProxy.xcodeproj -scheme PhoneLanProxy -destination 'platform=iOS Simulator,name=iPhone 18 Pro'   # Core + AppModel tests on the simulator
swift scripts/generate_app_icon.swift App/Assets.xcassets/AppIcon.appiconset   # regenerate the app icon (drawn with CoreGraphics; SF Symbols are not allowed in app icons)
scripts/build_ipa.sh   # unsigned Release build/PhoneLanProxy.ipa for AltStore/SideStore, which re-sign it with the user's Apple Account
```

CI (`.github/workflows/build-ipa.yml`) runs `build_ipa.sh` on every push/PR; a pushed `v*` tag publishes the IPA as a GitHub Release. Keep its runner on the same Xcode major as local development: SDK concurrency annotations differ between majors, so an older CI Xcode fails Swift 6 builds that pass locally.

The app has no entitlements file, App Groups, or keychain sharing (background audio, Live Activities, and local network are Info.plist-only), so it survives AltStore/SideStore re-signing, which appends the signer's Team ID to every bundle id. Keep it that way, or sideloaded installs break.

The Xcode project is hand-maintained with explicit file references and synthetic object IDs (no synchronized groups): adding a file means adding a `PBXFileReference`, a group entry, and a `PBXBuildFile` in each target that compiles it.

Black-box protocol acceptance (run against an already-running proxy — simulator or real device):

```sh
python3 scripts/socks5_acceptance.py
```

Spins up local IPv4/IPv6 TCP and HTTP test servers (stdlib only, no dependencies installed, no system network settings touched) and drives the live proxy end-to-end: SOCKS5 no-auth negotiation, IPv4/IPv6/domain `CONNECT`, fragmented/coalesced reads, target-failure `REP` codes, bidirectional large-payload relay and half-close, HTTPS `CONNECT` tunneling, HTTP absolute-form→origin-form rewriting, `Proxy-Connection` header stripping, and malformed-request error handling. For a real iPhone (not simulator), pass `--proxy-host`, `--target-host`, `--bind-host 0.0.0.0`, `--target-domain`, `--target-ipv6`, `--bind-ipv6 ::` so the test servers are reachable from the phone's LAN.

Long-running, real-device-only background acceptance scripts (see README's layered acceptance section):

```sh
python3 scripts/background_acceptance.py       # repeated fresh CONNECT tunnels over time — proxy keeps accepting new connections while backgrounded
python3 scripts/background_hold_acceptance.py  # one CONNECT tunnel held open and reused — proves the same tunnel survives backgrounding, not just new ones
```

There is no linter/formatter configured in this repo.

## Architecture

### Connection dispatch flow

`ProxyServer` ([Sources/PhoneLanProxyCore/ProxyServer.swift](Sources/PhoneLanProxyCore/ProxyServer.swift)) listens via `NWListener` on port `10808` on a private serial `DispatchQueue`. Each inbound `NWConnection` is wrapped in a `ProxySession` ([ProxySession.swift](Sources/PhoneLanProxyCore/ProxySession.swift)), keyed by a UUID in `ProxyServer.sessions`.

`ProxySession` buffers the client's first bytes and is the **sole protocol-sniffing point**: if the first byte is `0x05` (`SOCKS5Wire.version`) it builds a `SOCKS5Session`, otherwise an `HTTPProxySession` — handing off the already-buffered bytes via `initialData` so nothing is lost and the client connection isn't started twice.

- **SOCKS5Session** ([SOCKS5Session.swift](Sources/PhoneLanProxyCore/SOCKS5Session.swift)): state machine `.greeting → .waitingForMethodResponse → .request → .connecting → .relaying → .finished`. Only no-auth method and `CONNECT` command are supported. Wire parsing/encoding lives in `SOCKS5Wire` ([SOCKS5Protocol.swift](Sources/PhoneLanProxyCore/SOCKS5Protocol.swift)).
- **HTTPProxySession** ([HTTPProxySession.swift](Sources/PhoneLanProxyCore/HTTPProxySession.swift)): state machine `.readingHeaders → .connecting → .relaying → .finished`. Handles both `CONNECT` tunnels and absolute-form→origin-form HTTP rewriting (rebuilds `Host`, drops `Proxy-Connection`/`Connection`/`Keep-Alive` and sends `Connection: close`, because after the first request the session is a raw pipe to that one origin and must not be reused for another host; also strips device-identifying headers — `User-Agent`, every Client Hint (the `Sec-CH-*` family incl. the UA hints), and the legacy device/network characteristic hints (`DPR`, `Device-Memory`, `Viewport-Width`, `Downlink`, `X-Requested-With`, …) — so a plaintext-HTTP origin — or a VPN on the phone's egress — can't tell the request came from the Mac. This only touches plaintext HTTP; `CONNECT`/HTTPS is an opaque tunnel, so the TLS fingerprint and the encrypted User-Agent inside it are unchanged). Wire parsing lives in `HTTPProxyWire` ([HTTPProxyProtocol.swift](Sources/PhoneLanProxyCore/HTTPProxyProtocol.swift)).

Once the outbound `NWConnection` to the target is ready, both session types hand off to **TCPRelay** ([TCPRelay.swift](Sources/PhoneLanProxyCore/TCPRelay.swift)), which pumps bytes bidirectionally with a single receive / single dependent send in flight per direction (the back-pressure mechanism), and closes each direction's write side independently (`closeRemoteWrite`/`closeClientWrite`) before final teardown, to correctly propagate half-close.

`NetworkUtilities.swift` holds shared helpers: `SOCKS5NetworkUtilities` (bound-address formatting, POSIX-error→SOCKS5-reply-code mapping), `ProxyTimeouts` (10s client handshake, 15s outbound connect), and `QueueTimeout` (the one-shot timer every session uses). Outbound connects treat `NWConnection` `.waiting` as failure — Network.framework reports refused/unroutable targets that way and would otherwise retry forever — so the timeout only bounds black-holed targets and must stay generous for slow VPN/cellular paths.

### Concurrency model

No actors. All core classes (`ProxyServer`, `ProxySession`, `SOCKS5Session`, `HTTPProxySession`, `TCPRelay`) are `final class ... : @unchecked Sendable`, confining their mutable state to a single owned `DispatchQueue`, under Swift 6 strict concurrency (`swiftLanguageModes: [.v6]` in [Package.swift](Package.swift)). This is intentional — `Network.framework`'s `NWListener`/`NWConnection` APIs are closure/queue-based, not `async`. Follow the same queue-confinement pattern for new I/O code in this layer rather than introducing actors or `async`/`await` around `NWConnection` callbacks.

### App target (`App/`)

Not part of the SPM manifest; built via `PhoneLanProxy.xcodeproj`. Imports `PhoneLanProxyCore` as a real library dependency (no protocol/session logic is duplicated).

- `AppModel` ([App/AppModel.swift](App/AppModel.swift)): `@MainActor @Observable` supervisor driven by user intent (`wantsRunning`), not by the last reported status. Only `stopProxy()` stops the proxy. A `.failed` listener is restarted with backoff (1s→30s cap, injected `sleep` for tests) and immediately on returning to the foreground; keep-alive problems only degrade background execution. Snapshot filtering: while wanted, `.stopped` snapshots are late echoes and ignored; while not wanted, only `.stopped` is applied. Dependencies sit behind local protocols (`ProxyServing`, `LANAddressMonitoring`, `BackgroundAudioKeeping`, `LiveActivityManaging`) for test substitutability.
- `LANAddressMonitor` ([App/LANAddressMonitor.swift](App/LANAddressMonitor.swift)): detects the current LAN address via `NWPathMonitor`. Returns nil on the simulator by design.
- `BackgroundAudioKeepAlive` ([App/BackgroundAudioKeepAlive.swift](App/BackgroundAudioKeepAlive.swift)): `@MainActor`, keeps the process alive by looping zero-volume silent audio (`.playback` + `.mixWithOthers`, so other apps' music/video neither interrupt it nor are affected). Never fails outright: reports `KeepAliveState` (`.active/.recovering/.degraded`), resumes after interruptions regardless of `.shouldResume`, retries 1s/3s/10s, rebuilds after media-services reset, and has a 30s watchdog; `ensurePlaying()` is the foreground retry hook. NetworkExtension is deliberately not used: the real use case shares the phone's corporate VPN egress, and a packet tunnel would take the single VPN slot.
- `ProxyLiveActivityController` ([App/ProxyLiveActivityController.swift](App/ProxyLiveActivityController.swift)): owns the Live Activity. Event-driven only (start, health/connection changes, stop), no heartbeat and no stale date: device logs show liveactivitiesd rejects every update from a process that is "only playing background media" — exactly the silent-audio keepalive while locked — and wrapping the update in `beginBackgroundTask` does not change that, so any stale date would turn a healthy proxy gray. Sends are skipped while the app is in the background (they would be rejected) and the latest state is sent on `didBecomeActive`, all inside the controller; updates throttled to one per 5s; ends leftovers from a previous process at init. `Activity` is not `Sendable`, so only its `id` crosses isolation and nonisolated helpers look the instance up.

### Live Activity (`Shared/`, `Widgets/`)

- `ProxyActivityAttributes` ([Shared/ProxyActivityAttributes.swift](Shared/ProxyActivityAttributes.swift)) is compiled into the app, the widget extension, and the test target (not Core, which must build on macOS).
- `ProxyLiveActivityWidget` ([Widgets/ProxyLiveActivityWidget.swift](Widgets/ProxyLiveActivityWidget.swift)): expanded and Lock Screen show only the proxy status — green running, gray recovering; compact/minimal show only the status-colored `wifi.router.fill` glyph. No presentation shows connection count, LAN address, or port.

### Tests

`Tests/PhoneLanProxyCoreTests/`:

- `AppModelLifecycleTests.swift` — `AppModel` supervision against fake `ProxyServing`/`LANAddressMonitoring`/`BackgroundAudioKeeping`/`LiveActivityManaging` doubles and a recording `sleep`: keep-alive failure never blocks or stops the listener, listener failure restarts with resetting backoff, stop cancels a pending restart, foreground return restarts immediately and re-checks audio, late snapshots around stop/quick-restart are ignored, Live Activity start/update/end/recreate. Compiled only in the Xcode test target (guarded by `canImport(UIKit/AVFoundation/ActivityKit)`), so `swift test` on macOS skips it.
- `HTTPProxyProtocolTests.swift` — unit tests for `HTTPProxyWire.parse`: CONNECT authority parsing (incl. IPv6, fragmentation), absolute-form rewriting, rejection of malformed/oversized requests.
- `SOCKS5ProtocolTests.swift` — unit tests for `SOCKS5Wire` greeting/request parsing and response encoding (incl. IPv4/IPv6/domain addresses, fragment boundaries, invalid input).

Protocol-level and background-lifecycle behavior that can't be unit-tested lives in the `scripts/*.py` black-box acceptance scripts instead (see Commands above), since those need a live listening proxy (simulator or real device).

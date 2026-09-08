# Packet proxy engine

Settings → Proxy runs the Packet Rust client **inside the app** as a loopback SOCKS5
listener. There is no NetworkExtension and no VPN profile.

## The proxy is a hop, not a transport

`transportMode` has three values: `direct`, `bridge_text`, `offline`. The proxy is
orthogonal to all of them — it only changes *where the bytes go*, never the chat protocol,
the message types, or the socket implementation.

| key | meaning |
| --- | --- |
| `packetProxyEnabled` | the Use Proxy switch, mirrored into the engine config |
| `packetProxyHost` / `packetProxyPort` | where the engine bound its SOCKS listener |
| `packetStatus` / `packetLastError` | last start result, for the sheet |

`PacketProxyRoute.current()` is the single resolver. Two consumers:

- `VibeHTTP.shared` — the app's HTTP session. `URLSession.shared` when the proxy is off,
  a SOCKS-configured session when it is on. Pooled and rebuilt when the port changes.
- `ChatPhoenixClient.makeURLSessionConfiguration` — the Phoenix socket and every pinned
  request built through it.

`ChatEngine` will not open the socket while the proxy is on but has not bound a port; it
starts the engine and retries. It never falls back to direct — a proxy the user switched on
must not be bypassed.

## Removed: the mesh

The old `packet_mesh` transport (bridge bundle, peer descriptors, ticket, `text_only_v1`
media blocking, 384 KB image / 2 MB voice caps, `phantom_start_mesh`) is gone. Legacy
sessions carrying `transportMode=packet_mesh` migrate to `direct` at launch.
`/packet/bootstrap` is still fetched, but only for the proxy entries the server offers.

## Entries are the user's

Vibe ships no proxy configurations. The list starts empty; the user pastes a `vless://`
or `trojan://` link. Three rules protect what they store:

- A Keychain read that fails returns "unreadable", not "empty", and `mutate` refuses to
  write on top of it — an update can never save an empty list over real entries.
- `mergeServerProfiles` is additive only. Deleting an entry records its endpoint, so a
  later `/packet/bootstrap` refresh cannot bring it back.
- The engine no longer substitutes its built-in node (`RealityConfig::iran_default`) for a
  link it cannot parse — an invalid link is an error. It also rotates SNIs only among the
  names the config declares; rotating onto one the server's `serverNames` omits fails
  REALITY auth every time and restarts Xray in a loop.

## Start paths

`PacketProxyEngine.start(profile:)` picks the FFI entry point from the profile's stack:

| stack | FFI |
| --- | --- |
| `directSock` | `phantom_start_layered_carrier_full` |
| `packetChain` | carrier first, then native |
| `packetNative` | `phantom_start_full`, or `phantom_start` for a plain start |

Transport raw values are read by the Rust side — `reality` must stay `7`.

## Rebuilding the vendored engine

`ios/Vendor/Packet/**/*.a` is gitignored (~240 MB). A fresh clone must build it:

```sh
cd ~/Desktop/packet
./scripts/build-packet-xray.sh
# --crate-type staticlib: the cdylib does not link on iOS (tun2socks), and cargo
# fails the whole --lib build with it.
cargo rustc -p phantom-client --release --target aarch64-apple-ios \
  --features embedded-xray --lib --crate-type staticlib
cargo rustc -p phantom-client --release --target aarch64-apple-ios-sim \
  --features embedded-xray --lib --crate-type staticlib
./scripts/copy-vibe-artifacts.sh  # copies both archives into ios/Vendor/Packet
```

`libpacket_xray.a` only exists for arm64 (device + sim); the x86_64 sim slice is built
without `--features embedded-xray`, so REALITY is unavailable there.

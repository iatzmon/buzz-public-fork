# bip340 (Buzz copy)

A copy of [bip340 0.3.1](https://github.com/fiatjaf/dart-bip340) (MIT, see
`LICENSE`). The `nostr` package signs and verifies every event through it.

`lib/src/bip340_dart.dart`, `helpers.dart`, and `hex.dart` are the upstream
files, unchanged. `lib/src/bip340.dart` is new: in the web build it calls
`globalThis.buzzSchnorr` (from `web/buzz_schnorr.js`, built from
`@noble/curves`) and falls back to the Dart code when that object is missing,
an input is not lowercase hex of the expected length, or the call throws. Native
builds use the Dart code only.

Why: dart2js runs the BigInt point math about 100 times slower than native
code (about 85 ms per signature and 120 ms per check in Chrome), and the
browser has no background isolate, so this work froze the page.

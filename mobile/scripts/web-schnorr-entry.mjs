/**
 * BIP-340 Schnorr for the web build, bundled into `web/buzz_schnorr.js`.
 *
 * dart2js runs the `bip340` package's BigInt math about 100 times slower than
 * native code, and the browser build has no background isolate, so every
 * signature check and every signing call blocked the page. `packages/bip340`
 * calls these functions in the browser and keeps the Dart code as the
 * fallback.
 *
 * Same @noble/curves version the desktop app locks. Regenerate with
 * `just mobile-web-schnorr` after changing this file or that version.
 */
import { schnorr } from "@noble/curves/secp256k1.js";
import { bytesToHex, hexToBytes } from "@noble/curves/utils.js";

globalThis.buzzSchnorr = Object.freeze({
  sign: (secretKey, message, aux) =>
    bytesToHex(
      schnorr.sign(hexToBytes(message), hexToBytes(secretKey), hexToBytes(aux)),
    ),
  verify: (publicKey, message, signature) => {
    try {
      return schnorr.verify(
        hexToBytes(signature),
        hexToBytes(message),
        hexToBytes(publicKey),
      );
    } catch {
      return false;
    }
  },
  getPublicKey: (secretKey) =>
    bytesToHex(schnorr.getPublicKey(hexToBytes(secretKey))),
});

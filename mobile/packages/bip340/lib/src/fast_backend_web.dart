// Browser backend: `globalThis.buzzSchnorr` from `web/buzz_schnorr.js`.
// Each function returns null when the backend is missing or throws, so the
// caller falls back to the Dart code and keeps its error behavior.
import 'dart:js_interop';

@JS('buzzSchnorr')
external _BuzzSchnorr? get _backend;

extension type _BuzzSchnorr._(JSObject _) implements JSObject {
  external String sign(String secretKey, String message, String aux);
  external bool verify(String publicKey, String message, String signature);
  external String getPublicKey(String secretKey);
}

String? sign(String privateKey, String message, String aux) {
  try {
    return _backend?.sign(privateKey, message, aux);
  } catch (_) {
    return null;
  }
}

bool? verify(String publicKey, String message, String signature) {
  try {
    return _backend?.verify(publicKey, message, signature);
  } catch (_) {
    return null;
  }
}

String? getPublicKey(String privateKey) {
  try {
    return _backend?.getPublicKey(privateKey);
  } catch (_) {
    return null;
  }
}

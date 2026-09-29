import 'bip340_dart.dart' as dart_impl;
import 'fast_backend_stub.dart'
    if (dart.library.js_interop) 'fast_backend_web.dart' as fast;

export 'bip340_dart.dart' show verifyWithPoint;

// Lowercase only: the Dart hex decoder rejects uppercase, and both paths must
// agree on which inputs are errors.
final _hex = RegExp(r'^[0-9a-f]*$');

bool _isHex(String value, int length) =>
    value.length == length && _hex.hasMatch(value);

/// Generates a schnorr signature using the BIP-340 scheme.
///
/// privateKey must be 32-bytes hex-encoded, i.e., 64 characters.
/// message must also be 32-bytes hex-encoded (a hash of the _actual_ message).
/// aux must be 32-bytes random bytes, generated at signature time.
/// It returns the signature as a string of 64 bytes hex-encoded, i.e., 128 characters.
/// For more information on BIP-340 see bips.xyz/340.
String sign(String privateKey, String message, String aux) {
  if (_isHex(privateKey, 64) && _isHex(message, 64) && _isHex(aux, 64)) {
    final signature = fast.sign(privateKey, message, aux);
    if (signature != null) return signature;
  }
  return dart_impl.sign(privateKey, message, aux);
}

/// Verifies a schnorr signature using the BIP-340 scheme.
///
/// publicKey must be 32-bytes hex-encoded, i.e., 64 characters
///   (if you have a pubkey with 33 bytes just remove the first one).
/// message must also be 32-bytes hex-encoded (a hash of the _actual_ message).
/// signature must be 64-bytes hex-encoded, i.e., 128 characters.
/// It returns true if the signature is valid, false otherwise.
/// For more information on BIP-340 see bips.xyz/340.
bool verify(String publicKey, String message, String signature) {
  if (_isHex(publicKey, 64) && _isHex(message, 64) && _isHex(signature, 128)) {
    final valid = fast.verify(publicKey, message, signature);
    if (valid != null) return valid;
  }
  return dart_impl.verify(publicKey, message, signature);
}

/// Produces the public key from a private key
///
/// Takes privateKey, a 32-bytes hex-encoded string, i.e. 64 characters.
/// Returns a public key as also 32-bytes hex-encoded.
String getPublicKey(String privateKey) {
  if (_isHex(privateKey, 64)) {
    final publicKey = fast.getPublicKey(privateKey);
    if (publicKey != null) return publicKey;
  }
  return dart_impl.getPublicKey(privateKey);
}

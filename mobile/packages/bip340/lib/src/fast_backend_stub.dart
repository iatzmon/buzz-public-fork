// Native builds have no fast backend; `bip340.dart` uses the Dart code.

String? sign(String privateKey, String message, String aux) => null;

bool? verify(String publicKey, String message, String signature) => null;

String? getPublicKey(String privateKey) => null;

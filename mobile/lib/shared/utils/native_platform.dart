import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// The web build reports the browser's platform (iOS on iPhone and iPad
// Safari, Android in Chrome on Android) but contains none of the app's native
// code: no platform views and no method channels. Gate native features on
// these checks instead of the platform alone.

/// Whether the app runs as the native iOS app.
bool get isNativeIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Whether the app runs as the native Android app.
bool get isNativeAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Whether the theme targets iOS and native iOS views are available.
bool usesNativeIos(BuildContext context) =>
    !kIsWeb && Theme.of(context).platform == TargetPlatform.iOS;

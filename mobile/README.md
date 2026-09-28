# Buzz Mobile

Flutter mobile client for Buzz.

See [VISION_MOBILE.md](../VISION_MOBILE.md) for intended behavior and
architecture.

## Setup

Use the Flutter SDK pinned by the repository. Activate Hermit from the repo
root before resolving packages or running any Flutter command:

```bash
cd /path/to/buzz
. ./bin/activate-hermit
./bin/just mobile-install
```

`mobile-build-android` intentionally builds with `--no-pub`. If an IDE or an
external Flutter SDK has touched `mobile/.dart_tool`, rerun `mobile-install`
with the pinned SDK before building so `flutter_test`, `sky_engine`, and the
engine all come from the same Flutter version.

## Run

```bash
# From repo root (applies a worktree-isolated debug identity and starts/reuses Simulator):
just mobile-dev

# Direct (uses the app's configured community; apply worktree overrides first):
cd mobile && flutter run --dart-define=BUZZ_PUSH_GATEWAY_URL=https://push.example
```

### Worktree-aware debug identity

Debug builds produced from a git worktree get a unique app identifier keyed
to the **worktree directory name**
(`xyz.block.buzz.dogfood.mobile.<slug>` on iOS,
`xyz.block.buzz.mobile.<slug>` on Android) plus a display-only branch label
in the app name (`Buzz (my-branch)`, or a short SHA when the worktree is
detached). Because the identifier follows the directory rather than the
branch, one worktree keeps exactly one installed app — and its login state —
across branch switches, and builds from multiple worktrees install side by
side, mirroring the desktop dev experience. Release and profile builds
always keep the production identity and name.

`just mobile-dev` and `just mobile-build-android` apply this automatically by
running `scripts/mobile-worktree-overrides.sh`, which writes two gitignored
files:

- `mobile/ios/Flutter/WorktreeOverrides.xcconfig` (included by Debug builds
  only; a developer's `AppOverrides.xcconfig` is included after it, so
  app-specific overrides like a personal `BUNDLE_IDENTIFIER` for device
  signing always win)
- `mobile/android/worktree.properties` (read by the debug build type only)

Android developers can keep a stable local test identity that takes precedence
over the generated worktree values by creating the gitignored
`mobile/android/AppOverrides.properties`:

```properties
appName=Buzz Pairing
applicationIdSuffix=.device_pairing_e2e1
```

These values are consumed by the debug build type only. The standard
`just mobile-build-android` command can still be used; regenerating
`worktree.properties` does not overwrite `AppOverrides.properties`. Release
and profile builds keep the production `Buzz` name and application ID.

For direct Xcode / Android Studio / `flutter run` development, run
`./scripts/mobile-worktree-overrides.sh` from the repo root once per branch
switch to refresh the display label (the install identity never changes);
the persisted files are then picked up by any subsequent build. In the main
checkout the script is a no-op that removes stale override files, restoring
the plain `Buzz` identity. To enable push in direct Xcode builds and Runner tests, supply a
`BUZZ_PUSH_GATEWAY_URL` build setting in the gitignored
`mobile/ios/Flutter/AppOverrides.xcconfig`; the build phase validates and
passes it through as a Flutter Dart define. Since `//` begins an xcconfig
comment, spell the origin as `BUZZ_PUSH_GATEWAY_URL = https:/$()/push.example`.

For an Android debug build that must remain installed alongside other Buzz
worktree builds, set an explicit launcher name and package suffix when invoking
the generator or a recipe that invokes it:

```bash
BUZZ_PUSH_GATEWAY_URL="https://push.example" \
BUZZ_ANDROID_DEBUG_APP_NAME="Buzz Huddles" \
BUZZ_ANDROID_DEBUG_ID_SUFFIX=".huddles_829c" \
./bin/just mobile-build-android
```

This example produces the debug-only package
`xyz.block.buzz.mobile.huddles_829c` with the launcher label `Buzz Huddles`.
The suffix must start with a dot followed by a lowercase letter and may contain
only lowercase letters, digits, and underscores. Release and profile builds
ignore these overrides and retain the production package and name.

To remove leftover worktree-suffixed installs from booted iOS simulators and
connected Android emulators, run `just mobile-clean` (add `--dry-run` via
`./scripts/mobile-worktree-clean.sh --dry-run` to preview). Production
installs are never touched.

### iOS push capability

Every iOS artifact builds and embeds the Notification Service Extension and
native push bridge. Runtime activation is fail-closed and scoped to the current
relay. After authenticated connectivity and a fully valid NIP-11 `nip-pl` push
descriptor, Buzz independently requests display permission and registers with
APNs. Display denial or request failure does not gate the device token, gateway
enrollment, or lease publication, so a later user opt-in can display pushes
without rebuilding transport authority. An absent, malformed, or unreachable
descriptor leaves push inactive without partial enrollment.

Mobile builds without a gateway origin succeed with push unavailable. To enable
push, supply the gateway origin explicitly:

```bash
flutter build ios --dart-define=BUZZ_PUSH_GATEWAY_URL=https://push.example
flutter build apk --dart-define=BUZZ_PUSH_GATEWAY_URL=https://push.example
```

The iOS and Android build gates validate any supplied define, rejecting empty or
malformed values. Release/profile builds require an HTTPS origin without an
explicit port. An absent define disables permission requests, APNs registration,
gateway enrollment, and lease publication; Settings shows push as unavailable.
No production gateway is selected implicitly. Enrollment
grants and crash-recovery journals are scoped to this origin. Push has not
shipped to existing users, so there is no legacy-state or cross-gateway
migration. Changing gateways requires fresh enrollment; old installations
expire under their original gateway's lease policy. Current-gateway response
loss is still retried from the exact journaled request.

Relay rollout remains an explicit deployment opt-in. Only deployments with
`BUZZ_PUSH_ENABLED=true` advertise the descriptor and process push. See
`docs/push-gateway-deployment.md` for the canonical gateway profile contract,
manual physical-device proof, measurements, and rollback procedure.

For local physical-device development, override the identity and sandbox
environments in the gitignored `mobile/ios/Flutter/AppOverrides.xcconfig`:

```xcconfig
BUNDLE_IDENTIFIER = com.example.buzz.mobile
BUZZ_DEVELOPMENT_TEAM = YOUR_TEAM_ID
BUZZ_IOS_PUSH_ENVIRONMENT = development
BUZZ_APP_ATTEST_ENVIRONMENT = development
BUZZ_PUSH_GATEWAY_URL = https:/$()/push.example
```

Use your personal bundle ID and team above. Provision both the parent and its
`.NotificationService` extension. Configure an isolated gateway with the matching
App Attest application ID, APNs topic and sandbox certificate. Development
attestation requires the explicit `personal-dev-app-attest` gateway build feature
and `BUZZ_PUSH_APP_ATTEST_ENVIRONMENT=development`; ordinary gateway builds accept
production attestation only. See `docs/push-gateway-deployment.md`.
This validates the personal client/relay/gateway integration, not the internally
distributed dogfood artifact. Validate dogfood separately using the signed
internal release and its production gateway configuration.

Parent app identifiers require Apple's Communication
Notifications capability and a regenerated app provisioning profile. The
Notification Service Extension profile does not require that capability.
Enable it on the personal development App ID for local rich-presentation
validation. Enabling it on the Block dogfood and eventual App Store App IDs is
a release follow-up and is not performed by this repository change. Without a
matching parent profile, source and unit validation still work, but the app
cannot be signed for a physical device.

APNs and the gateway continue to carry only the constant opaque wake-up. The
extension fetches the message from the scoped relay, verifies message, sender
profile, and channel-metadata signatures, and uses a bounded App Group cache
for names and app-rendered avatar thumbnails. It never fetches an avatar URL;
missing, stale, or invalid enrichment falls back to the verified message with a
short sender pubkey, community subtitle, and no image.

## Checks

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test --dart-define=BUZZ_PUSH_GATEWAY_URL=https://push.example
```

Or from the repo root: `just mobile-check` and `just mobile-test`.

## Web build

The same app builds for the browser:

```bash
flutter build web --base-href /app/
```

`--base-href` must match the path the app is served under. Serve `build/web`
from the relay's own origin, or add the page's origin to the
relay's `BUZZ_CORS_ORIGINS`. The relay rejects HTTP calls from other origins.
Sign in with a pairing code from Desktop (Settings, mobile pairing, copy code).

Not available in the browser yet: attachment upload, voice notes, camera,
sharing, push notifications and the app badge.

The browser reports its own platform (iOS in Safari on iPhone and iPad), but the
web build has none of the app's native code. Gate native views and method
channels on `isNativeIos`, `isNativeAndroid` or `usesNativeIos(context)` from
`lib/shared/utils/native_platform.dart`, not on the platform alone.

## Android release signing

Android release builds fail unless all upload-key inputs are supplied through the
environment:

- `BUZZ_ANDROID_UPLOAD_KEYSTORE_PATH`: path to a CI-vended keystore file
- `BUZZ_ANDROID_UPLOAD_KEYSTORE_PASSWORD`
- `BUZZ_ANDROID_UPLOAD_KEY_ALIAS`
- `BUZZ_ANDROID_UPLOAD_KEY_PASSWORD`

The keystore path must be absolute, and the keystore must remain outside the
repository. Development and debug builds do not require these variables.

Release pipelines that sign through the central APK Signer service instead of
a local upload keystore must set `BUZZ_ANDROID_RELEASE_SIGNING=external`. That
mode produces an unsigned release bundle and refuses to run if any
`BUZZ_ANDROID_UPLOAD_*` value is also set.

## Architecture

```
lib/
├── main.dart              # Entry point, Riverpod bootstrap
├── app.dart               # MaterialApp with theme
├── shared/
│   └── theme/             # Catppuccin light/dark, spacing tokens, extensions
└── features/
    └── home/              # Placeholder home surface
```

- **State management:** Riverpod + Hooks (`HookConsumerWidget`)
- **Theme:** Catppuccin Latte (light) / Macchiato (dark) — matches desktop
- **Spacing:** `Grid` tokens for consistent spacing
- **Linting:** `flutter_lints` + `riverpod_lint` via `custom_lint`
- **Feature isolation:** No cross-feature imports except `shared/`

## Creating channels and forums

On Home, tap **+**, then **Create channel** or **Create forum**. Enter a name,
choose Public or Private visibility, optionally set an expiry, and submit with
the keyboard's Done action. The app opens the created channel or forum.

## Foldables and larger windows

The authenticated workspace uses two panes at 720 logical pixels of available
width: Home, Activity, or Search starts in a 320–360 pixel sidebar, while the
selected conversation and its thread navigation occupy the remaining space.
At 600–719 pixels, the channel menu is a 320-pixel overlay that closes when a
conversation is selected. The conversation keeps its width underneath; tap the
exposed conversation, Hide sidebar, or Back to dismiss the menu. A 48-pixel
Show sidebar control remains available. Below 600 pixels, only the active pane
is visible. Layout follows the current
window constraints, including multi-window resizing, rather than device model
or orientation. Both widget trees and the detail navigator stay mounted across
these changes, preserving drafts, cursor selection, and scroll controllers.
Drag the divider to resize the sidebar between 320 and 560 logical pixels,
subject to leaving at least 320 pixels for the conversation. The 48-pixel
control strip contains a Hide/Show sidebar button and a large drag target.
Double-tap the drag target (or press Home when it has keyboard focus) to reset
its width; Left/Right arrows adjust it in 24-pixel steps. Assistive technologies
can also increase or decrease its width. Width and collapse choices are retained
while this workspace is mounted, including across folding and orientation
changes; they are not persisted across app restarts. A physical separating
hinge fixes pane boundaries, so resizing is disabled there but the toggle stays
available on the unobstructed detail screen.

System Back unwinds the detail stack before returning to the list and respects
page dismissal guards. Switching communities clears the old detail stack.

A separating vertical hinge becomes the pane gap when both sides are usable;
otherwise the larger unobstructed region is used. Horizontal half-open folds
also use the larger region. Flat, non-occluding folds do not divide the UI.

Before shipping an Android build, verify on a physical foldable:

- Open a channel or DM, type an unsent draft, scroll, and open a thread. Fold,
  unfold, and rotate repeatedly; check the draft, selection, and Back behavior.
- Repeat with the keyboard open and in Android split-screen mode.
- Open conversations from Activity, Search, and notification links; verify they
  use the detail pane and that Home's quick actions remain tappable.
- Exercise attachment menus, media viewers, and Huddle minimize/restore while
  changing the window size. Verify voice-note cancellation when a route covers
  the recorder.

Widget regressions cover the shell geometry, real Home/channel composer,
deep-link dispatch, hinge gaps, RTL pane ordering, keyboard insets, dismissal
guards, and community changes. These tests do not replace physical-device
validation of Android's display handoff or process recreation.

### Android emulator regression

`integration_test/adaptive_workspace_test.dart` drives the production Home and
channel composer with synthetic local data. It verifies divider dragging,
collapse/restore, draft/widget retention, and actual Android display-size changes
between inner-screen, cover-screen, and portrait dimensions. It uses no live relay.

Start a dedicated Android emulator, then run from `mobile/`:

```sh
BUZZ_TEST_DEVICE=emulator-5582 flutter drive --no-pub -d emulator-5582 \
  --driver=test_driver/adaptive_workspace_driver.dart \
  --target=integration_test/adaptive_workspace_test.dart
```

Use the actual dedicated emulator serial in both places. The driver refuses
physical devices, changes its display size/density, saves screenshots under
`build/adaptive-workspace-screenshots` (override with `BUZZ_TEST_SCREENSHOTS`),
and clears the emulator's size/density overrides when the test reports its
result. Use a disposable emulator without display overrides you need to keep.
The dimensions simulate window/aspect changes; this does not certify Samsung
hardware's cover-display handoff behavior.

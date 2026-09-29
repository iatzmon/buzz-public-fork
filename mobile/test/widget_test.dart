import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:buzz/app.dart';
import 'package:buzz/features/age_gate/age_signal_provider.dart';
import 'package:buzz/shared/auth/auth.dart';
import 'package:buzz/shared/theme/theme_provider.dart';

void main() {
  testWidgets('App renders pairing page when unauthenticated', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => _FakeAuthNotifier()),
          ageSignalProvider.overrideWith(() => _AllowedAgeSignalNotifier()),
          savedPrefsProvider.overrideWithValue(prefs),
        ],
        child: const App(),
      ),
    );
    await tester.pump();
    expect(find.text('Welcome to Buzz'), findsOneWidget);
  });

  testWidgets('App keeps the same themes when it rebuilds', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => _FakeAuthNotifier()),
          ageSignalProvider.overrideWith(() => _AllowedAgeSignalNotifier()),
          savedPrefsProvider.overrideWithValue(prefs),
        ],
        child: const App(),
      ),
    );
    await tester.pump();
    final before = tester.widget<MaterialApp>(find.byType(MaterialApp));

    // A new but equal theme would make MaterialApp animate between the two,
    // which briefly brightens icons such as the sidebar toggle.
    tester.element(find.byType(App)).markNeedsBuild();
    await tester.pump();
    final after = tester.widget<MaterialApp>(find.byType(MaterialApp));

    expect(after, isNot(same(before)));
    expect(after.theme, same(before.theme));
    expect(after.darkTheme, same(before.darkTheme));
  });
}

class _AllowedAgeSignalNotifier extends AgeSignalNotifier {
  @override
  AgeSignalState build() => AgeSignalState.allowed;

  @override
  Future<void> request() async {}
}

class _FakeAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async {
    return const AuthState(status: AuthStatus.unauthenticated);
  }
}

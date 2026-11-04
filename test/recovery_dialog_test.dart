// The recovery code screen: the code is shown, can only be dismissed after
// "I have saved this code", and the one-time offer never needs it.
import 'package:flutter/material.dart';
import 'package:flutter_application_1/features/settings/recovery_section.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the code is shown and Done waits for the confirmation', (
    tester,
  ) async {
    const code = 'ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345-6789-AB';
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => const RecoveryCodeDialog(code: code),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(code), findsOneWidget);
    // Done is disabled until the person confirms.
    FilledButton done() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('recovery-done')),
    );
    expect(done().onPressed, isNull);
    // Tapping outside does not dismiss it.
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.text(code), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery-saved')));
    await tester.pump();
    expect(done().onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('recovery-done')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text(code), findsNothing, reason: 'shown once, then gone');
  });
}

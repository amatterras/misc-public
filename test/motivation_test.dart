import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/features/motivation/motivation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String quoteSource;
  late String greetingSource;

  setUpAll(() async {
    quoteSource = await rootBundle.loadString('assets/motivation/quotes.json');
    greetingSource = await rootBundle.loadString(
      'assets/motivation/greetings.json',
    );
  });

  test(
    'bundled libraries contain 1,000 quotes and six greeting slots',
    () async {
      final service = MotivationService(
        localTime: () => LocalTimeSnapshot(
          now: DateTime(2026, 10, 23, 7, 30),
          utcOffset: const Duration(hours: 3),
        ),
        nextIndex: (_) => 0,
      );
      await service.load();

      expect(service.quotes, hasLength(1001));
      expect(service.quotes.first.id, 'q0001');
      expect(service.quotes.first.order, 1);
      expect(service.quotes.last.id, 'q1001');
      expect(service.quotes.last.order, 1001);
      expect(
        service.quotes.where((quote) => quote.attribution.isNotEmpty),
        hasLength(400),
      );
      expect(
        service.quotes.where((quote) => quote.attribution.isEmpty),
        hasLength(601),
      );
      expect(
        service.quotes.map((quote) => quote.collection).toSet(),
        hasLength(5),
      );
      expect(service.slots, hasLength(6));
      expect(
        service.slots.map((slot) => slot.greetings.length),
        [201, 101, 201, 101, 201, 101],
      );
      expect(service.greeting, service.slots[0].greetings.first);
      service.dispose();
    },
  );

  const mehLine = 'meh. -sesil melek merev';

  test('the meh. line is in every greeting pool and in the quote pool, '
      'exactly, and can be selected', () async {
    // Exact text in the files themselves.
    final quotesRaw = File('assets/motivation/quotes.json').readAsStringSync();
    final greetingsRaw = File(
      'assets/motivation/greetings.json',
    ).readAsStringSync();
    expect(quotesRaw, contains('"quote": "$mehLine"'));
    expect(RegExp(RegExp.escape('"$mehLine"')).allMatches(greetingsRaw), hasLength(6));

    // Every greeting slot can show it (it is the 101st of each slot).
    for (final hour in [6, 10, 14, 19, 22, 2]) {
      final service = MotivationService(
        localTime: () => LocalTimeSnapshot(
          now: DateTime(2026, 10, 23, hour, 30),
          utcOffset: const Duration(hours: 3),
        ),
        nextIndex: (n) => 100,
      );
      await service.load();
      expect(service.greeting, mehLine, reason: 'hour $hour');
      service.dispose();
    }

    // The quote comes up when the hourly quote rolls through the deck.
    var now = DateTime(2026, 10, 23, 0, 30);
    final service = MotivationService(
      localTime: () =>
          LocalTimeSnapshot(now: now, utcOffset: const Duration(hours: 3)),
      nextIndex: (n) => n ~/ 2,
    );
    await service.load();
    final seen = <String>{service.quote!.text};
    for (var i = 0; i < 1001 && !seen.contains(mehLine); i++) {
      now = now.add(const Duration(hours: 1));
      service.refresh();
      seen.add(service.quote!.text);
    }
    expect(seen, contains(mehLine));
    expect(service.quotes.last.text, mehLine);
    expect(service.quotes.last.attribution, '');
    service.dispose();
  });

  test('greeting time slots use local clock boundaries', () {
    expect(MotivationService.greetingSlotIndex(4), 5);
    expect(MotivationService.greetingSlotIndex(5), 0);
    expect(MotivationService.greetingSlotIndex(7), 0);
    expect(MotivationService.greetingSlotIndex(8), 1);
    expect(MotivationService.greetingSlotIndex(12), 2);
    expect(MotivationService.greetingSlotIndex(17), 3);
    expect(MotivationService.greetingSlotIndex(21), 4);
    expect(MotivationService.greetingSlotIndex(0), 5);
  });

  testWidgets('greeting window remains for 60 seconds then dismisses', (
    tester,
  ) async {
    final service = MotivationService(
      localTime: () => LocalTimeSnapshot(
        now: DateTime(2026, 10, 23, 7, 30),
        utcOffset: const Duration(hours: 3),
      ),
      nextIndex: (_) => 0,
    );
    service.loadFromSources(quoteSource, greetingSource);
    expect(service.greetingVisible, isTrue);

    await tester.pump(const Duration(seconds: 59));
    expect(service.greetingVisible, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(service.greetingVisible, isFalse);

    service.dispose();
  });

  test(
    'a manually dismissed greeting remains dismissed after restart',
    () async {
      var persisted = false;
      final service = MotivationService(
        localTime: () => LocalTimeSnapshot(
          now: DateTime(2026, 10, 23, 7, 30),
          utcOffset: const Duration(hours: 3),
        ),
        nextIndex: (_) => 0,
        onGreetingDismissed: () async {
          persisted = true;
        },
      );
      service.loadFromSources(quoteSource, greetingSource);
      expect(service.greetingVisible, isTrue);
      service.dismissGreeting();
      await Future<void>.delayed(Duration.zero);
      expect(persisted, isTrue);
      expect(service.greetingVisible, isFalse);
      service.dispose();

      final restarted = MotivationService(
        localTime: () => LocalTimeSnapshot(
          now: DateTime(2026, 10, 23, 7, 30),
          utcOffset: const Duration(hours: 3),
        ),
        nextIndex: (_) => 0,
        greetingDismissed: persisted,
      );
      restarted.loadFromSources(quoteSource, greetingSource);
      expect(restarted.greetingVisible, isFalse);
      restarted.showGreeting();
      expect(restarted.greetingVisible, isFalse);
      restarted.dispose();
    },
  );

  testWidgets('quote changes on the next local-hour boundary', (tester) async {
    final fakeStart = tester.binding.clock.now();
    final localStart = DateTime(2026, 10, 23, 7, 59);
    LocalTimeSnapshot time() => LocalTimeSnapshot(
      now: localStart.add(tester.binding.clock.now().difference(fakeStart)),
      utcOffset: const Duration(hours: 3),
    );
    final service = MotivationService(localTime: time, nextIndex: (_) => 0);
    service.loadFromSources(quoteSource, greetingSource);
    final firstQuote = service.quote;

    await tester.pump(const Duration(seconds: 59));
    expect(service.quote, firstQuote);
    await tester.pump(const Duration(seconds: 1));

    expect(service.quote, isNot(firstQuote));
    expect(service.activeGreetingSlotIndex, 1);
    service.showGreeting();
    expect(service.greeting, service.slots[1].greetings.first);
    service.dispose();
  });

  test('resume recalculates after timezone and local-date changes', () async {
    var time = LocalTimeSnapshot(
      now: DateTime(2026, 10, 23, 23, 59),
      utcOffset: const Duration(hours: 3),
    );
    final service = MotivationService(
      localTime: () => time,
      nextIndex: (_) => 0,
    );
    service.loadFromSources(quoteSource, greetingSource);
    final beforeMidnight = service.quote;
    expect(service.activeGreetingSlotIndex, 4);

    time = LocalTimeSnapshot(
      now: DateTime(2026, 10, 24),
      utcOffset: const Duration(hours: 3),
    );
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    final afterMidnight = service.quote;
    expect(afterMidnight, isNot(beforeMidnight));
    expect(service.activeGreetingSlotIndex, 5);

    time = LocalTimeSnapshot(
      now: DateTime(2026, 10, 24, 5, 30),
      utcOffset: const Duration(hours: 4),
    );
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(service.quote, isNot(afterMidnight));
    expect(service.activeGreetingSlotIndex, 0);
    service.showGreeting();
    expect(service.greeting, service.slots[0].greetings.first);
    service.dispose();
  });
}

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

      expect(service.quotes, hasLength(1000));
      expect(service.quotes.first.id, 'q0001');
      expect(service.quotes.first.order, 1);
      expect(service.quotes.last.id, 'q1000');
      expect(service.quotes.last.order, 1000);
      expect(
        service.quotes.where((quote) => quote.attribution.isNotEmpty),
        hasLength(400),
      );
      expect(
        service.quotes.where((quote) => quote.attribution.isEmpty),
        hasLength(600),
      );
      expect(
        service.quotes.map((quote) => quote.collection).toSet(),
        hasLength(5),
      );
      expect(service.slots, hasLength(6));
      expect(
        service.slots.map((slot) => slot.greetings.length),
        everyElement(100),
      );
      expect(service.greeting, service.slots[0].greetings.first);
      service.dispose();
    },
  );

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

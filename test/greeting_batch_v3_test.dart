// The 300-greeting batch (v3): integrated once, in the right pools, shown
// only inside its own local-time window, mixed with the older greetings of
// the same pool; the pool follows the device clock.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/features/motivation/motivation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String greetingSource;
  setUpAll(() async {
    greetingSource = await rootBundle.loadString(
      'assets/motivation/greetings.json',
    );
  });

  // The attached file, kept unchanged as a fixture.
  final batch =
      (jsonDecode(File('test/data/theapp_greetings_300_v3.json').readAsStringSync())
              as List)
          .cast<Map<String, dynamic>>();
  const slotIndex = {'early_morning': 0, 'noon': 2, 'late_evening': 4};

  Map<int, Set<String>> byPool() => {
    for (final e in slotIndex.entries)
      e.value: {
        for (final r in batch)
          if (r['time_slot'] == e.key) r['text'] as String,
      },
  };

  LocalTimeSnapshot at(int h, int m, [int offsetHours = 3]) => LocalTimeSnapshot(
    now: DateTime(2026, 10, 26, h, m),
    utcOffset: Duration(hours: offsetHours),
  );

  test('the file is valid: 300 records, 100 per group, unique', () {
    expect(batch, hasLength(300));
    for (final slot in slotIndex.keys) {
      expect(batch.where((r) => r['time_slot'] == slot), hasLength(100));
    }
    for (final r in batch) {
      expect(r['id'], isA<String>());
      expect((r['text'] as String).trim(), isNotEmpty);
      expect(slotIndex.containsKey(r['time_slot']), isTrue);
    }
    expect(batch.map((r) => r['id']).toSet(), hasLength(300));
    expect(batch.map((r) => r['text']).toSet(), hasLength(300));
    String field(String slot, String key) =>
        batch.firstWhere((r) => r['time_slot'] == slot)[key] as String;
    expect(field('early_morning', 'start_local_time'), '05:00');
    expect(field('early_morning', 'end_local_time'), '07:59');
    expect(field('noon', 'start_local_time'), '12:00');
    expect(field('noon', 'end_local_time'), '16:59');
    expect(field('late_evening', 'start_local_time'), '21:00');
    expect(field('late_evening', 'end_local_time'), '23:59');
  });

  test('each greeting is in its own pool exactly once, nowhere else', () {
    final slots = MotivationService.parseGreetingSlots(greetingSource);
    final pools = byPool();
    for (var i = 0; i < slots.length; i++) {
      for (final entry in pools.entries) {
        for (final text in entry.value) {
          final count = slots[i].greetings.where((g) => g == text).length;
          expect(count, entry.key == i ? 1 : 0, reason: '$text in pool $i');
        }
      }
    }
    expect(slots.map((s) => s.greetings.length), [
      201,
      101,
      201,
      101,
      201,
      101,
    ]);
    expect(slots.fold<int>(0, (n, s) => n + s.greetings.length), 906);
    expect(slots.expand((s) => s.greetings).toSet(), hasLength(901));
  });

  test('the earlier greetings are all still there, in order', () {
    final slots = MotivationService.parseGreetingSlots(greetingSource);
    expect(slots[0].greetings.first, 'up already? suspicious.');
    for (var i = 0; i < 6; i++) {
      expect(slots[i].greetings[100], 'meh. -sesil melek merev');
    }
    final pools = byPool();
    for (final i in pools.keys) {
      expect(slots[i].greetings.skip(101).toSet(), pools[i]);
    }
  });

  test('a greeting only appears in its own time window', () async {
    final pools = byPool();
    final all = pools.values.expand((p) => p).toSet();
    for (var h = 0; h < 24; h++) {
      for (final m in [0, 59]) {
        final pool = MotivationService.greetingSlotIndex(h);
        for (final pick in <int Function(int)>[(n) => n - 1, (n) => 0]) {
          final service = MotivationService(
            localTime: () => at(h, m),
            nextIndex: pick,
          );
          await service.load();
          final shown = service.greeting!;
          final foreign = pools.containsKey(pool)
              ? all.difference(pools[pool]!)
              : all;
          expect(foreign.contains(shown), isFalse, reason: '$h:$m -> $shown');
          service.dispose();
        }
      }
    }
  });

  test('the exact boundaries of this batch and its neighbours', () {
    int slot(int h) => MotivationService.greetingSlotIndex(h);
    expect(slot(4), 5); // 04:59 still overnight
    expect(slot(5), 0); // 05:00 early morning starts
    expect(slot(7), 0); // 07:59 still early morning
    expect(slot(8), 1);
    expect(slot(11), 1);
    expect(slot(12), 2); // 12:00 noon starts
    expect(slot(16), 2); // 16:59 still noon
    expect(slot(17), 3);
    expect(slot(20), 3);
    expect(slot(21), 4); // 21:00 late evening starts
    expect(slot(23), 4); // 23:59 still late evening
    expect(slot(0), 5); // midnight
  });

  test('random selection reaches old and new greetings of one pool', () async {
    final slots = MotivationService.parseGreetingSlots(greetingSource);
    final fresh = byPool()[0]!;
    final picks = <String>{};
    for (final index in [0, 50, 99, 100, 101, 150, 200]) {
      final service = MotivationService(
        localTime: () => at(6, 30),
        nextIndex: (n) => index.clamp(0, n - 1),
      );
      await service.load();
      picks.add(service.greeting!);
      expect(service.greeting, slots[0].greetings[index]);
      service.dispose();
    }
    expect(picks.any(fresh.contains), isTrue, reason: 'a new one');
    expect(picks.any((g) => !fresh.contains(g)), isTrue, reason: 'an old one');
  });

  test('the pool follows the clock: boundary, midnight, timezone, resume',
      () async {
    var now = DateTime(2026, 10, 26, 7, 59);
    var offset = const Duration(hours: 3);
    final service = MotivationService(
      localTime: () => LocalTimeSnapshot(now: now, utcOffset: offset),
      nextIndex: (n) => n - 1,
    );
    await service.load();
    expect(service.activeGreetingSlotIndex, 0);
    now = DateTime(2026, 10, 26, 8, 0);
    service.refresh();
    expect(service.activeGreetingSlotIndex, 1);
    now = DateTime(2026, 10, 26, 16, 59);
    service.refresh();
    expect(service.activeGreetingSlotIndex, 2);
    now = DateTime(2026, 10, 26, 23, 59);
    service.refresh();
    expect(service.activeGreetingSlotIndex, 4);
    now = DateTime(2026, 10, 27, 0, 0); // midnight rollover
    service.refresh();
    expect(service.activeGreetingSlotIndex, 5);
    now = DateTime(2026, 10, 27, 6, 0); // timezone change
    offset = const Duration(hours: 9);
    service.refresh();
    expect(service.activeGreetingSlotIndex, 0);
    now = DateTime(2026, 10, 27, 13, 0); // resume after a long time away
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    service.showGreeting();
    expect(service.activeGreetingSlotIndex, 2);
    expect(byPool()[2]!.contains(service.greeting), isTrue);
    service.dispose();
  });
}

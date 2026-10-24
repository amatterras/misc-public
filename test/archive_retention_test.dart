import 'dart:io';
import 'dart:convert';

import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late DateTime now;
  late Workspace workspace;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('theapp_archive_retention_');
    now = DateTime.utc(2026, 10, 24, 12);
    workspace = Workspace(root, now: () => now);
    await workspace.load();
  });

  tearDown(() async {
    workspace.dispose();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  CalendarEntry entry({
    String id = 'entry-1',
    bool archived = false,
    DateTime? archivedAt,
  }) {
    return CalendarEntry(
      id: id,
      category: CalendarCategory.events,
      name: 'Trip',
      createdAt: now,
      updatedAt: now,
      startDate: DateTime(2026, 11, 1),
      archived: archived,
      archivedAt: archivedAt,
    );
  }

  test(
    'archive timestamp is recorded and exact seven-day cutoff tombstones',
    () async {
      workspace.saveEntry(entry());
      workspace.setArchived('entry-1', true);
      expect(workspace.entries['entry-1']!.archivedAt, now);

      final beforeBoundary = now.add(
        const Duration(days: 7) - const Duration(microseconds: 1),
      );
      expect(
        await workspace.purgeExpiredArchivedEntries(now: beforeBoundary),
        isEmpty,
      );
      expect(workspace.entries['entry-1'], isNotNull);

      final atBoundary = now.add(const Duration(days: 7));
      expect(await workspace.purgeExpiredArchivedEntries(now: atBoundary), [
        'entry-1',
      ]);
      expect(workspace.entries['entry-1'], isNull);
      expect(workspace.entries.tombstones, contains('entry-1'));
    },
  );

  test(
    'restore clears the retention timestamp and re-archive starts a new term',
    () async {
      workspace.saveEntry(entry());
      workspace.setArchived('entry-1', true);
      final firstArchive = workspace.entries['entry-1']!.archivedAt;

      now = now.add(const Duration(days: 6));
      workspace.setArchived('entry-1', false);
      expect(workspace.entries['entry-1']!.archivedAt, isNull);
      expect(
        await workspace.purgeExpiredArchivedEntries(
          now: now.add(const Duration(days: 30)),
        ),
        isEmpty,
      );

      workspace.setArchived('entry-1', true);
      expect(workspace.entries['entry-1']!.archivedAt, now);
      expect(workspace.entries['entry-1']!.archivedAt, isNot(firstArchive));
    },
  );

  test('legacy archived records get seven safe days from migration', () async {
    final legacy = entry(archived: true).toJson()..remove('archivedAt');
    await workspace.store.write('data', 'calendar_entries', {
      'schema': 2,
      'records': [legacy],
      'revs': const {},
      'tombstones': const {},
    });
    await workspace.entries.load();

    expect(workspace.entries['entry-1']!.archivedAt, now);
    expect(
      await workspace.purgeExpiredArchivedEntries(
        now: now.add(const Duration(days: 7)),
      ),
      ['entry-1'],
    );
  });

  test('active entries are never purged, even with an old timestamp', () async {
    workspace.saveEntry(
      entry(
        archived: false,
        archivedAt: now.subtract(const Duration(days: 90)),
      ),
    );
    expect(await workspace.purgeExpiredArchivedEntries(now: now), isEmpty);
    expect(workspace.entries['entry-1'], isNotNull);
  });

  test('an older app backup cannot restore an expired entry', () async {
    workspace.saveEntry(entry());
    workspace.setArchived('entry-1', true);
    await workspace.flush();
    final oldBackup = await workspace.backups.snapshot('before-expiry');

    now = now.add(const Duration(days: 7));
    await workspace.purgeExpiredArchivedEntries(now: now);
    expect(workspace.entries['entry-1'], isNull);

    await workspace.backups.restore(oldBackup);
    workspace.dispose();
    workspace = Workspace(root, now: () => now);
    await workspace.load();
    expect(workspace.entries['entry-1'], isNull);
    expect(workspace.entries.tombstones, contains('entry-1'));
  });

  test(
    'expiration scrubs managed backups and carries its sync lock forward',
    () async {
      workspace.saveEntry(entry());
      workspace.setArchived('entry-1', true);
      workspace.saveEntry(entry(id: 'unrelated'));
      await workspace.flush();
      final backup = await workspace.backups.snapshot('before-expiry-copy');
      final copies = Directory('${root.path}${Platform.pathSeparator}files');
      workspace.backups.copiesDir = copies;
      final exportedCopy = await workspace.backups.copyTo(backup, copies);

      now = now.add(const Duration(days: 7));
      await workspace.purgeExpiredArchivedEntries(now: now);

      for (final directory in [backup, exportedCopy]) {
        final data = jsonDecode(
          await File(
            '${directory.path}${Platform.pathSeparator}data'
            '${Platform.pathSeparator}calendar_entries.json',
          ).readAsString(),
        ) as Map<String, dynamic>;
        final records = (data['records'] as List).cast<Map<String, dynamic>>();
        expect(records.map((record) => record['id']), contains('unrelated'));
        expect(
          records.map((record) => record['id']),
          isNot(contains('entry-1')),
        );
        expect(data['tombstones'], contains('entry-1'));

        final expirations = jsonDecode(
          await File(
            '${directory.path}${Platform.pathSeparator}data'
            '${Platform.pathSeparator}calendar_entry_expirations.json',
          ).readAsString(),
        ) as Map<String, dynamic>;
        expect(expirations['records'], isNotEmpty);
        final ledger = jsonDecode(
          await File(
            '${directory.path}${Platform.pathSeparator}retention'
            '${Platform.pathSeparator}expired_calendar_entries.json',
          ).readAsString(),
        ) as Map<String, dynamic>;
        expect(ledger['ids'], contains('entry-1'));
      }

      final restoredRoot = Directory(
        '${root.path}${Platform.pathSeparator}restored-on-another-device',
      );
      await workspace.backups.restoreTo(backup, restoredRoot);
      final restored = Workspace(restoredRoot, now: () => now);
      await restored.load();
      expect(restored.entries['entry-1'], isNull);
      expect(restored.entries['unrelated'], isNotNull);
      expect(restored.calendarExpirations['entry-1'], isNotNull);
      restored.dispose();
    },
  );
}

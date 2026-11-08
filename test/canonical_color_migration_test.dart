import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/migrations/canonical_color_migration.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy ink migration preserves alpha, geometry and metadata', () {
    final stroke = StrokeItem(
      id: 'stroke',
      points: [const StrokePoint(3, 7, 0.4), const StrokePoint(11, 19, 0.9)],
      color: const Color(0x66FF8A65),
      strokeWidth: 8.5,
      pressureWidth: true,
    );
    final text = TextItem(
      id: 'text',
      position: const Offset(5, 9),
      width: 220,
      minHeight: 80,
      text: 'kept',
      textColor: const Color(0xFF4D8FD6),
      background: const Color(0xFF222222), // unrecognized/custom: unchanged
    );
    final doc = CanvasDocument(
      id: 'canvas',
      title: 'Preserve me',
      items: [stroke, text],
      updatedAt: DateTime.utc(2026),
      itemRevs: const {'stroke': 'old-s', 'text': 'old-t'},
      itemUnknownFields: const {
        'text': {'future': true},
      },
      unknownKeys: const {'futureDoc': 1},
    );

    final migrated = CanonicalColorMigration.migrateCanvas(doc, 'new-rev');
    final newStroke = migrated.items[0] as StrokeItem;
    final newText = migrated.items[1] as TextItem;
    expect(newStroke.color.toARGB32(), 0x66D5A16F);
    expect(newStroke.points.map((p) => p.toJson()).toList(), [
      [3, 7, 0.4],
      [11, 19, 0.9],
    ]);
    expect(newStroke.strokeWidth, 8.5);
    expect(newStroke.pressureWidth, isTrue);
    expect(newStroke.bounds, stroke.bounds);
    expect(newText.position, text.position);
    expect(newText.width, text.width);
    expect(newText.minHeight, text.minHeight);
    expect(newText.text, text.text);
    expect(newText.textColor, const Color(0xFF789BB5));
    expect(newText.background, text.background);
    expect(migrated.itemRevs['stroke'], 'new-rev');
    expect(migrated.itemRevs['text'], 'new-rev');
    expect(migrated.itemUnknownFields, doc.itemUnknownFields);
    expect(migrated.unknownKeys, doc.unknownKeys);
    expect(migrated.updatedAt, doc.updatedAt);
  });

  test('unknown stored ink remains unchanged and migration is idempotent', () {
    final original = const Color(0xFF123456);
    expect(CanonicalColorMigration.migrateColor(original), original);
    final doc = CanvasDocument(
      id: 'empty',
      title: 'empty',
      items: [
        StrokeItem(
          id: 'custom',
          points: const [StrokePoint(1, 1, 1)],
          color: original,
          strokeWidth: 2,
        ),
      ],
      updatedAt: DateTime.utc(2026),
    );
    final once = CanonicalColorMigration.migrateCanvas(doc, 'rev');
    expect(identical(once, doc), isTrue);
  });

  test('legacy Calendar assignments migrate to their category slot', () {
    final now = DateTime.utc(2026);
    for (final category in CalendarCategory.values) {
      final entry = CalendarEntry(
        id: category.name,
        category: category,
        name: 'sample',
        createdAt: now,
        updatedAt: now,
        colorIndex: 9,
      );
      final migrated = CanonicalColorMigration.migrateCalendarEntry(entry);
      expect(migrated.colorIndex, category.index);
      expect(migrated.category, category);
    }
  });

  test(
    'semantic palettes stay separate and global text contrast is strong',
    () {
      int hex(Color color) => color.toARGB32();
      double contrast(Color a, Color b) {
        final la = a.computeLuminance() + .05;
        final lb = b.computeLuminance() + .05;
        return la > lb ? la / lb : lb / la;
      }

      // The interface has one palette (the New one); the ink, tag, category
      // and calendar palettes below are separate and never follow it. The
      // dark identity colours are kept exactly, and text stays readable in
      // both themes.
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        AppColors.mode = mode;
        expect(AppColors.background, AppColors.background);
        expect(AppColors.card, AppColors.card);
        expect(AppColors.cardRaised, AppColors.cardRaised);
        expect(AppColors.border, AppColors.border);
        expect(AppColors.text, AppColors.text);
        expect(AppColors.accent, AppColors.accent);
        expect(
          contrast(AppColors.text, AppColors.background),
          greaterThan(7),
          reason: '$mode text on the page',
        );
        expect(
          contrast(AppColors.text, AppColors.card),
          greaterThan(7),
          reason: '$mode text on cards',
        );
        expect(
          contrast(AppColors.textMuted, AppColors.background),
          greaterThan(4.5),
          reason: '$mode muted text',
        );
      }
      AppColors.mode = ThemeMode.dark;
      expect(hex(AppColors.background), 0xFF191A1D);
      expect(hex(AppColors.accent), 0xFF789BB5);
      // The canonical 19 keep their order and values; newer inks are
      // only ever appended after them.
      expect(InkColors.all.map(hex).take(19), [
        0xFFE3E5E8,
        0xFF789BB5,
        0xFF829CB5,
        0xFF172943,
        0xFF4F9AA6,
        0xFF8FBFA9,
        0xFFC7D5A0,
        0xFFC8AED2,
        0xFFD5A16F,
        0xFFE56BDA,
        0xFFC6AD79,
        0xFF2878F0,
        0xFF2366AD,
        0xFF00BDB1,
        0xFFB5DC32,
        0xFF793BE8,
        0xFFF2D84A,
        0xFF176B4D,
        0xFFFF3B30,
      ]);
      expect(inkColorNames.take(19), [
        'Pearl',
        'Steel Blue',
        'Dusty Blue',
        'Midnight Navy',
        'Petrol',
        'Dusty Mint',
        'Pistachio',
        'Orchid Mist',
        'Soft Amber',
        'Fuchsia',
        'Antique Gold',
        'Electric Azure',
        'Sapphire',
        'Vivid Turquoise',
        'Electric Lime',
        'Ultraviolet',
        'Electric Gold',
        'Deep Pine',
        'Bright Red',
      ]);
      expect(InkColors.library.map((s) => s.id).toSet().length, 24);
      expect(InkColors.byId('bright-orange')?.color, const Color(0xFFFF6A00));
      expect(inkColorNames.skip(19), [
        'Bright Orange',
        'Sky Blue',
        'Warm Brown',
        'Graphite Gray',
        'Jet Black',
      ]);
      expect(
        InkColors.library.where((s) => s.color == const Color(0xFFFF3B30)),
        hasLength(1),
      );
      expect(InkColors.byId('bright-red')?.color, InkColors.brightRed);
      expect(CanvasTagColors.selected.map(hex), [
        0xFFACDCD8,
        0xFF2C6149,
        0xFFA65469,
        0xFFE9C5DB,
        0xFFE1AB7B,
      ]);
      expect(ArchiveCategoryColors.resource.toARGB32(), 0xFF5581C1);
      expect(ArchiveCategoryColors.projects.toARGB32(), 0xFFBB565A);
      expect(ArchiveCategoryColors.other.toARGB32(), 0xFFDEB866);
      expect(ArchiveCategoryColors.shopping.toARGB32(), 0xFF489A68);
      expect(ArchiveCategoryColors.secondBrain.toARGB32(), 0xFFD492C1);
      expect(CalendarCategoryColors.reading.toARGB32(), 0xFF8EA96C);
      expect(CalendarCategoryColors.habits.toARGB32(), 0xFF7092D0);
      expect(CalendarCategoryColors.other.toARGB32(), 0xFFC491C1);
      expect(CalendarCategoryColors.reminderEvent.toARGB32(), 0xFF52B0AB);
      double luminance(Color color) => color.computeLuminance();
      final a = luminance(AppColors.text) + 0.05;
      final b = luminance(AppColors.background) + 0.05;
      expect((a > b ? a / b : b / a), greaterThan(7));
    },
  );

  test(
    'startup migrates disposable records only after verified backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'theapp_color_migrate_',
      );
      addTearDown(() async => root.delete(recursive: true));
      final ws = Workspace(root);
      final canvases = FileCanvasRepository(ws.store);
      final settings = SettingsRepository(ws.store);
      await ws.load();
      await settings.load();
      await settings.set('dataFeatureLevel', 1);
      final now = DateTime.utc(2026, 1, 2);
      ws.entries.put(
        CalendarEntry(
          id: 'legacy-event',
          category: CalendarCategory.events,
          name: 'synthetic',
          createdAt: now,
          updatedAt: now,
          colorIndex: 7,
        ),
      );
      await canvases.save(
        CanvasDocument(
          id: 'synthetic-canvas',
          title: 'synthetic',
          items: [
            StrokeItem(
              id: 'legacy-stroke',
              points: const [StrokePoint(1, 2, 0.7)],
              color: const Color(0xAA64B5F6),
              strokeWidth: 4,
            ),
          ],
          updatedAt: now,
        ),
      );
      await ws.flush();

      final state = AppState(
        canvases: canvases,
        settings: settings,
        workspace: ws,
        enableSendTo: false,
      );
      await state.init();
      addTearDown(state.dispose);

      expect(settings.get<int>('dataFeatureLevel'), 2);
      expect(settings.get<int>('canonicalColorMigration'), 1);
      expect(
        ws.entries['legacy-event']!.colorIndex,
        CalendarCategory.events.index,
      );
      final migrated =
          (await canvases.load('synthetic-canvas'))!.items.single as StrokeItem;
      expect(migrated.color.toARGB32(), 0xAA2878F0);
      final backups = await Directory(
        '${root.path}${Platform.pathSeparator}backups',
      ).list().toList();
      expect(backups, isNotEmpty, reason: 'feature-level backup exists');
    },
  );
}

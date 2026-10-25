// A realistic workspace in the shapes THEapp stored BEFORE the data-safety
// update (commit 2847c5a): linked notes/folders/tasks, a photo and a PDF
// with real bytes, an Archive link whose URL has a query, Reading entries
// with author/highlights (and a `quotes` field written by another
// version), a timed and an untimed habit with completion history, user tag
// colours, a mindmap with coloured strokes, a note card, a photo and a
// connection, app settings, a Google link, and one collection still in
// the oldest file format (schema 1: no revisions, ISO-date tombstones).
//
// The marker strings let tests prove that logs never contain content.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_application_1/data/models/calendar_models.dart';
import 'package:flutter_application_1/data/models/calendar_sync_models.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/models/record.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';

const secretBodyMarker = 'SECRET-BODY-7f3a';
const secretQueryMarker = 'SECRETQUERY9b2c';
const archiveUrl =
    'https://example.org/papers/Thesis.pdf?token=$secretQueryMarker&v=2#p3';

class PreUpdateFixture {
  PreUpdateFixture(this.dir);
  final Directory dir;

  late String folderId,
      subfolderId,
      noteId,
      linkedNoteId,
      photoAssetId,
      pdfAssetId,
      linkAssetId,
      readingId,
      readingQuotesId,
      untimedHabitId,
      timedHabitId,
      eventId,
      projectId,
      taskId,
      subtaskId,
      tagId,
      canvasId,
      calendarLinkId;
  late int tagColor;
  late Color strokeColor;
  late Set<String> untimedCheckoffs;
  final sep = Platform.pathSeparator;

  File file(String rel) => File('${dir.path}$sep${rel.replaceAll('/', sep)}');
}

Future<Uint8List> fixturePng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xFF35A99A), BlendMode.src);
  final image = await recorder.endRecording().toImage(4, 3);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
}

/// Minimal valid one-page PDF.
Uint8List fixturePdf() => Uint8List.fromList(
  utf8.encode(
    '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
    '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n'
    'trailer<</Root 1 0 R>>\n%%EOF\n',
  ),
);

Future<PreUpdateFixture> buildPreUpdateWorkspace(Directory dir) async {
  final f = PreUpdateFixture(dir);
  final ws = Workspace(dir);
  await ws.load();

  final folder = ws.createFolder('School');
  f.folderId = folder.id;
  f.subfolderId = ws.createFolder('Physics', parentId: folder.id).id;

  final photo = await ws.imageAssetFromBytes(await fixturePng(), 'png');
  f.photoAssetId = photo.id;
  final pdfSource = File('${dir.parent.path}${f.sep}fixture-source.pdf')
    ..writeAsBytesSync(fixturePdf());
  final pdf = await ws.documentAssetFromFile(pdfSource);
  f.pdfAssetId = pdf.id;
  final link = ws.linkAsset(archiveUrl, title: 'Thesis');
  f.linkAssetId = link.id;

  final note = ws.createNote(
    title: 'Lab notes',
    body: 'Measurements $secretBodyMarker',
    folderId: f.subfolderId,
    assetIds: [photo.id, pdf.id],
  );
  f.noteId = note.id;
  f.linkedNoteId = ws
      .createNote(
        title: 'Summary',
        body: 'See [[Lab notes]]',
        folderId: f.folderId,
      )
      .id;

  f.tagColor = 0xFF00BDB1;
  final tag = ws.createTag('Sources', f.tagColor).tag;
  f.tagId = tag.id;
  ws.assets.put(
    ws.assets[link.id]!.copyWith(linkTags: ['tag:${tag.id}', 'resource']),
  );

  final project = ws.createTask('Exam week', isExam: true);
  f.projectId = project.id;
  final task = ws.createTask('Revise optics', parentId: project.id);
  f.taskId = task.id;
  ws.tasks.put(task.copyWith(noteIds: [note.id], assetIds: [pdf.id]));
  f.subtaskId = ws.createTask('Flashcards', parentId: task.id).id;

  final now = DateTime.now();
  final today = dateOnly(now);
  CalendarEntry entry(String id, CalendarCategory c, String name) =>
      CalendarEntry(
        id: id,
        category: c,
        name: name,
        createdAt: today.subtract(const Duration(days: 40)),
        updatedAt: now,
      );
  f.readingId = 'reading-1';
  ws.entries.put(
    entry(f.readingId, CalendarCategory.reading, 'Optics').copyWith(
      author: 'E. Hecht',
      highlights: 'Chapter 4 on refraction',
      totalPages: () => 700,
      currentPage: 120,
      readingLog: {
        dayKey(today.subtract(const Duration(days: 2))): 20,
        dayKey(today.subtract(const Duration(days: 1))): 15,
      },
      assetIds: [pdf.id],
    ),
  );
  f.readingQuotesId = 'reading-2';
  ws.entries.put(
    entry(
      f.readingQuotesId,
      CalendarCategory.reading,
      'Essays',
    ).copyWith(author: 'M. de Montaigne'),
  );
  f.untimedHabitId = 'habit-untimed';
  f.untimedCheckoffs = {
    for (var d = 1; d <= 9; d++) dayKey(today.subtract(Duration(days: d))),
  };
  ws.entries.put(
    entry(f.untimedHabitId, CalendarCategory.habits, 'Stretch').copyWith(
      startDate: () => today.subtract(const Duration(days: 30)),
      checkoffs: f.untimedCheckoffs,
    ),
  );
  f.timedHabitId = 'habit-timed';
  ws.entries.put(
    entry(f.timedHabitId, CalendarCategory.habits, 'Run').copyWith(
      startDate: () => today.subtract(const Duration(days: 20)),
      weekdays: {1, 3, 5},
      startMinutes: () => 7 * 60 + 30,
      durationMinutes: () => 30,
      checkoffs: {
        for (var d = 1; d <= 20; d++)
          if ({1, 3, 5}.contains(today.subtract(Duration(days: d)).weekday))
            dayKey(today.subtract(Duration(days: d))),
      },
    ),
  );
  f.eventId = 'event-1';
  ws.entries.put(
    entry(f.eventId, CalendarCategory.events, 'Conference').copyWith(
      startDate: () => today.add(const Duration(days: 3)),
      endDate: () => today.add(const Duration(days: 5)),
    ),
  );
  ws.days.put(
    DayRecord(
      id: dayKey(today),
      text: 'Day note',
      assetIds: [photo.id],
      updatedAt: now,
    ),
  );
  f.calendarLinkId = 'google-link-1';
  ws.calendarLinks.put(
    CalendarLink(
      id: f.calendarLinkId,
      provider: 'google',
      calendarId: 'primary',
      remoteId: 'remote-1',
      hash: 'h1',
      updatedAt: now,
      entryId: f.eventId,
    ),
  );
  // Deleted earlier: a tombstone that must survive.
  final gone = ws.createNote(title: 'Old draft');
  ws.notes.remove(gone.id);

  // A mindmap with user colours, a photo, a note card and a connection.
  f.canvasId = 'canvas-1';
  f.strokeColor = const Color(0xCC2878F0); // marker with alpha
  final repo = FileCanvasRepository(ws.store);
  await repo.save(
    CanvasDocument(
      id: f.canvasId,
      title: 'Optics map',
      updatedAt: now,
      folderId: f.folderId,
      items: [
        TextItem(
          id: 't1',
          position: const Offset(100, 80),
          width: 220,
          minHeight: 60,
          text: 'Refraction',
          textColor: const Color(0xFFE56BDA),
        ),
        NoteCardItem(
          id: 'n1',
          position: const Offset(420, 80),
          width: 220,
          noteId: note.id,
        ),
        ImageItem(
          id: 'i1',
          position: const Offset(100, 300),
          width: 160,
          minHeight: 120,
          assetId: photo.id,
        ),
        LinkItem(
          id: 'l1',
          position: const Offset(420, 300),
          width: 240,
          assetId: link.id,
        ),
        const ConnectorItem(id: 'c1', fromId: 't1', toId: 'n1'),
        StrokeItem(
          id: 's1',
          points: const [
            StrokePoint(10, 10, 0.4),
            StrokePoint(60, 40, 0.7),
            StrokePoint(120, 30, 0.6),
          ],
          color: f.strokeColor,
          strokeWidth: 3.5,
        ),
      ],
    ),
  );
  await ws.flush();
  ws.dispose();

  // Another version wrote `quotes` on the second Reading entry.
  final entriesFile = f.file('data/calendar_entries.json');
  final json = jsonDecode(entriesFile.readAsStringSync()) as Map;
  for (final r in json['records'] as List) {
    if (r['id'] == f.readingQuotesId) {
      r['quotes'] = ['Que sais-je?', 'Every man bears the whole form'];
    }
  }
  entriesFile.writeAsStringSync(jsonEncode(json));

  // The oldest file format: schema 1, ISO-date tombstones, no revisions.
  f
      .file('data/inbox.json')
      .writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'records': [
            {
              'id': 'inbox-1',
              'text': 'Captured idea',
              'createdAt': '2026-09-01T10:00:00.000Z',
              'updatedAt': '2026-09-01T10:00:00.000Z',
            },
          ],
          'tombstones': {'inbox-0': '2026-08-30T09:00:00.000Z'},
        }),
      );

  // App settings that are part of the user's setup.
  f.file('settings/app.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({
        'dataFeatureLevel': 2,
        'canonicalColorMigration': 1,
        'penWidth': 3.5,
        'dotOpacity.mindmap': 0.35,
        'dateOrder': 'dayMonth',
        'firstWeekday': 1,
      }),
    );
  return f;
}

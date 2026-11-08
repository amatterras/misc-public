// Regressions for the integration of master into ui/new-design (2026-11-08):
// places where a master feature met a ui/new-design / QA-audit change.
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/sync/canvas_merge.dart';
import 'package:flutter_application_1/sync/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasSyncState fresh({List<CanvasLayer> layers = const []}) => CanvasSyncState(
  items: [],
  itemRevs: {},
  tombstones: {},
  title: 'Map',
  folderId: null,
  metaRev: null,
  layers: layers,
);

SyncChange meta(Map<String, dynamic> data) => SyncChange(
  collection: 'canvases',
  id: 'c1',
  rev: '0001792610475963-0002-dev2',
  deleted: false,
  data: data,
);

void main() {
  // QA audit: unreadable canvas metadata is left on the hub instead of
  // failing the canvas every sync. Master: Mindmap layers travel in that
  // metadata. Malformed layers must be skipped the same way.
  test('malformed layers in synced metadata are skipped, not fatal', () {
    const keep = [CanvasLayer(id: 'l1', name: 'Ink')];
    final state = fresh(layers: keep);
    late Set<String> applied;
    expect(
      () => applied = applyCanvasChanges(state, 'c1', [
        meta({'title': 'New title', 'layers': 'not a list'}),
      ], (_, _) => false),
      returnsNormally,
    );
    expect(applied, isNot(contains('canvases/c1')));
    expect(state.title, 'Map', reason: 'nothing half-applied');
    expect(state.layers, keep);
  });

  test('readable layers in synced metadata are applied with the rest', () {
    final state = fresh();
    final applied = applyCanvasChanges(state, 'c1', [
      meta({
        'title': 'Planned',
        'layers': [
          const CanvasLayer(id: 'a', name: 'Sketch', hidden: true).toJson(),
          const CanvasLayer(id: 'b', name: 'Notes', locked: true).toJson(),
        ],
      }),
    ], (_, _) => false);
    expect(applied, contains('canvases/c1'));
    expect(state.title, 'Planned');
    expect(state.layers.map((l) => l.id), ['a', 'b']);
    expect(state.layers.first.hidden, isTrue);
    expect(state.layers.last.locked, isTrue);
  });
}

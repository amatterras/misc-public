// Archive (object library) labels: the five canonical categories, custom
// tags from the shared registry (at most 15), filtering, deletion and
// isolation from every other kind of record.
import 'dart:io';

import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/library_models.dart';
import 'package:flutter_application_1/data/models/object_library_models.dart';
import 'package:flutter_application_1/data/models/tag_models.dart';
import 'package:flutter_application_1/data/repositories/library_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_application_1/features/links/link_tags.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Workspace ws;
  late LibraryRepository repo;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('theapp_libtags_');
    ws = Workspace(dir);
    await ws.load();
    repo = LibraryRepository(ws);
  });
  tearDown(() {
    repo.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<LibraryObject> site(String name) => repo.save(
    type: LibraryObjectType.website,
    sourceUrl: 'https://$name.example',
    title: name,
  );

  test('the five canonical category colors are unchanged', () {
    expect({for (final c in LinkTag.values) c.id: c.color.toARGB32()}, {
      'resource': 0xFF3060B0,
      'projects': 0xFFB03040,
      'other': 0xFFF0C060,
      'shopping': 0xFF409060,
      'second-brain': 0xFFE0A0D0,
    });
    expect(ArchiveCategoryColors.resource, LinkTag.resource.color);
  });

  test('categories and tags filter with AND; unknown ids are ignored', () async {
    final a = await site('a');
    final b = await site('b');
    await site('c');
    final reading = ws.createTag('Reading', 0xFF2878F0).tag;
    await repo.setCategory(a.id, 'resource', true);
    await repo.setCategory(b.id, 'resource', true);
    await repo.setCategory(a.id, 'nonsense', true);
    await repo.setTags(b.id, {reading.id, 'no-such-tag'});
    expect(repo.categoriesOf(a.id), {'resource'});
    expect(repo.tagIdsOf(b.id), {reading.id});

    List<String> titles(Set<String> cats, Set<String> tags) =>
        [
          for (final o in repo.withLabels(
            repo.objects,
            categories: cats,
            tagIds: tags,
          ))
            o.title,
        ]..sort();
    expect(titles({'resource'}, {}), ['a', 'b']);
    expect(titles({}, {reading.id}), ['b']);
    expect(titles({'resource'}, {reading.id}), ['b']);
    expect(titles({'shopping'}, {}), isEmpty);
    expect(titles({}, {}), ['a', 'b', 'c']);

    await repo.setCategory(a.id, 'resource', false);
    expect(titles({'resource'}, {}), ['b']);
  });

  test('labels are searchable and survive a reload', () async {
    final a = await site('a');
    final tag = ws.createTag('Reading', 0xFF2878F0).tag;
    await repo.setTags(a.id, {tag.id});
    await repo.setCategory(a.id, 'projects', true);
    expect(repo.search('tag:Reading').items.map((o) => o.id), [a.id]);
    expect(repo.search('Projects').items.map((o) => o.id), [a.id]);

    await ws.flush();
    final reopened = Workspace(dir);
    await reopened.load();
    final again = LibraryRepository(reopened);
    expect(again.categoriesOf(a.id), {'projects'});
    expect(again.tagIdsOf(a.id), {tag.id});
    again.dispose();
    reopened.dispose();
  });

  test('at most 15 tags: the 16th is refused; reuse and deleting still work', () {
    for (var i = 0; i < CustomTag.maxTags; i++) {
      ws.createTag('tag $i', 0xFF2878F0);
    }
    expect(CustomTag.maxTags, 15);
    expect(ws.customTags.all, hasLength(15));
    expect(
      () => ws.createTag('one too many', 0xFF2878F0),
      throwsArgumentError,
    );
    expect(ws.customTags.all, hasLength(15));
    // The same name (any case) reuses the existing tag instead of failing.
    expect(ws.createTag('TAG 3', 0xFF2878F0).existed, isTrue);
    // Deleting one makes room.
    ws.deleteTag(ws.tagNamed('tag 0')!.id);
    expect(ws.createTag('fresh', 0xFF2878F0).existed, isFalse);
    expect(ws.customTags.all, hasLength(15));
  });

  test('deleting a tag removes it from library objects, not the objects', () async {
    final a = await site('a');
    final tag = ws.createTag('Reading', 0xFF2878F0).tag;
    await repo.setTags(a.id, {tag.id});
    expect(ws.deleteTag(tag.id), 1);
    expect(repo.tagIdsOf(a.id), isEmpty);
    expect(repo.objects.map((o) => o.id), [a.id]);
  });

  test('the Archive only holds its own objects', () async {
    final a = await site('a');
    // Other records with the same labels are never part of the library.
    ws.assets.put(
      Asset(
        id: 'legacy',
        kind: AssetKind.link,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        url: 'https://legacy.example',
        linkTags: const ['resource'],
      ),
    );
    await repo.setCategory(a.id, 'resource', true);
    final shown = repo.withLabels(repo.objects, categories: {'resource'});
    expect(shown.map((o) => o.id), [a.id]);
    expect(repo.search('legacy').items, isEmpty);
    // Labels cannot be put on something that is not a library object.
    await repo.setCategory('legacy', 'resource', true);
    expect(repo.categoriesOf('legacy'), isEmpty);
  });
}

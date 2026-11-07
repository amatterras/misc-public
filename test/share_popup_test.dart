import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level checks of the iOS share popup. They cannot show that Swift
/// compiles or how the popup looks (that needs the Codemagic build and a
/// device); they pin the parts that are easy to break silently.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final controller = read('ios/ShareExtension/ShareViewController.swift');
  final greetings = read('ios/ShareExtension/ShareGreetings.swift');
  // Only the view code: from the popup marker on.
  final view = controller.substring(controller.indexOf('// MARK: popup'));

  test('the 120 supplied greetings are present, verbatim and in order', () {
    final inSwift = RegExp(
      r'^    "(.*)",$',
      multiLine: true,
    ).allMatches(greetings).map((m) => m.group(1)).toList();
    final supplied = read('test/fixtures/share_greetings.txt')
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    expect(supplied.length, 120);
    expect(inSwift, supplied);
    expect(inSwift.toSet().length, 120, reason: 'no duplicates');
    expect(inSwift.first, 'Good find.');
    expect(inSwift.last, "Well, aren't we resourceful.");
  });

  test('one greeting is chosen per session and never re-rolled', () {
    // Chosen in viewDidLoad, stored in the model; the view only reads it.
    expect(
      RegExp(r'ShareGreetings\.random\(\)').allMatches(controller).length,
      1,
    );
    expect(controller, contains('model.greeting = ShareGreetings.random()'));
    expect(view, isNot(contains('ShareGreetings')));
    expect(view, isNot(contains('randomElement')));
  });

  test('ShareGreetings.swift is compiled into the extension only', () {
    final project = read('ios/Runner.xcodeproj/project.pbxproj');
    expect(
      RegExp('ShareGreetings.swift in Sources').allMatches(project).length,
      2,
      reason: 'the build-file entry and its one entry in the source phase',
    );
    expect(project, contains('path = ShareGreetings.swift'));
  });

  test('popup geometry: floating, 74% x 60%, margins, no sheet', () {
    expect(view, contains('container.width * 0.74'));
    expect(view, contains('container.height * 0.60'));
    expect(view, contains('static let margin: CGFloat = 20'));
    // iPad: capped so it floats instead of covering most of the screen
    expect(view, contains('static let maxWidth: CGFloat = 560'));
    expect(view, contains('min(430, tall)'));
    // presented over full screen with every surrounding layer transparent
    expect(controller, contains('get { .overFullScreen }'));
    expect(controller, contains('clearSurroundings()'));
    expect(view, contains('static let radius: CGFloat = 24'));
    // the overlay is its own layer; the popup is positioned, not stretched
    expect(view, contains('.position(x: metrics.centerX'));
    expect(view, isNot(contains('presentationDetents')));
  });

  test('structure: misc., ONE glass container, done. outside it', () {
    expect(view, contains('Text("misc.")'));
    expect(view, contains('Text("done.")'));
    expect(
      RegExp(r'Material\.ultraThinMaterial').allMatches(view).length,
      1,
      reason: 'a single blurred container, not two',
    );
    final glass = view.substring(
      view.indexOf('private var glassContainer'),
      view.indexOf('private var linkSection'),
    );
    expect(glass, contains('linkSection'));
    expect(glass, contains('tagSection'));
    expect(glass, isNot(contains('doneButton')));
  });

  test('tags: existing ones only, exactly one selectable, none created', () {
    expect(view, contains('ForEach(model.tags)'));
    expect(view, contains('model.selectedTag = tag.id'));
    expect(view, isNot(contains('TextField')));
    expect(view, isNot(contains('TextEditor')));
    expect(controller, contains('archive_share_tags.json'));
  });

  test('every written word is SF Pro bold and white', () {
    expect(view, contains('.system(size: size, weight: .bold)'));
    for (final other in [
      '.regular',
      '.medium',
      '.semibold',
      '.heavy',
      '.light',
      'design: .rounded',
      'design: .serif',
      'design: .monospaced',
      '.custom(',
    ]) {
      expect(view, isNot(contains(other)), reason: other);
    }
    // each visible Text(...) is followed by a white foreground
    final texts = RegExp(r'Text\(').allMatches(view).length;
    final whites = RegExp(r'\.foregroundColor\(\.white\)')
        .allMatches(view)
        .length;
    expect(whites, greaterThanOrEqualTo(texts));
    expect(view, isNot(contains('foregroundStyle')));
  });

  test('saving: guarded against repeats, dismisses only after success', () {
    expect(controller, contains('guard !model.saving, !model.finished'));
    expect(controller, contains('self.model.finished = true'));
    final ok = controller.indexOf('self.model.finished = true');
    final done = controller.indexOf('completeRequest', ok);
    expect(done, greaterThan(ok));
    // failures keep the popup open with the content still there
    expect(controller, contains('The rest remain available to retry.'));
    // the old unconditional delayed dismissal is gone
    expect(controller, isNot(contains('asyncAfter(deadline: .now() + 1.5)')));
  });

  test('the unused message catalog is gone', () {
    expect(
      read('ios/ShareExtension/Info.plist'),
      isNot(contains('THEappShareMessages')),
    );
    expect(controller, isNot(contains('share_messages.json')));
  });
}

/// Which interface the app shows. The choice is stored in this device's own
/// settings file (never synced), so Windows, iPad and iPhone can differ.
/// Nothing stored means [original]: an existing install never changes by
/// itself.
enum InterfaceVersion {
  /// The interface exactly as it was before the redesign.
  original,

  /// The redesigned interface (lib/new_ui). Same data, same pages, same
  /// actions; only the presentation differs.
  newDesign;

  static const settingsKey = 'interfaceVersion';

  String get label => switch (this) {
    original => 'Original',
    newDesign => 'New',
  };

  /// What is written to the settings file.
  String get stored => switch (this) {
    original => 'original',
    newDesign => 'new',
  };

  /// Anything unknown, missing or corrupt reads as [original].
  static InterfaceVersion fromStored(Object? value) =>
      value == 'new' ? newDesign : original;
}

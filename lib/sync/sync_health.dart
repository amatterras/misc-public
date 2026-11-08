// Sync Health: turns the facts about this device's sync (connected or not,
// waiting changes, conflicts, last attempts) into one plain-language
// diagnosis and the safe next steps. Pure logic, so it is easy to test.
//
// Nothing here touches data. Text meant to be copied or shown in history is
// scrubbed: no addresses, keys, tokens or note text ever appear in it.
import 'sync_scheduler.dart' show SyncConnection;

/// One finished sync attempt, in plain words.
class SyncAttempt {
  const SyncAttempt(this.at, this.ok, this.text);
  final DateTime at;
  final bool ok;
  final String text;
}

/// Removes anything that looks like an address, a key or a long token.
String scrubDiagnostic(String text) {
  var s = text.replaceAll(RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://\S+'), '[address]');
  s = s.replaceAll(
    RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b'),
    '[address]',
  );
  s = s.replaceAll(RegExp(r'\b[\w-]+\.ts\.net\b'), '[address]');
  s = s.replaceAll(RegExp(r'\b[A-Za-z0-9_\-+/=]{24,}\b'), '[hidden]');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > 160 ? '${s.substring(0, 157)}...' : s;
}

enum SyncLevel { ok, waiting, attention, problem }

enum SyncStep {
  /// Nothing to do.
  none,
  syncNow,
  reviewConflicts,
  turnOnSync,

  /// Disconnect and pair again with a new code.
  pairAgain,
}

/// What is known about sync right now.
class SyncFacts {
  const SyncFacts({
    required this.paired,
    required this.needsPairing,
    required this.enabled,
    required this.connection,
    required this.syncing,
    required this.lastSynced,
    required this.pendingCount,
    required this.conflictCount,
    this.lastAttemptFailed = false,
  });

  final bool paired;
  final bool needsPairing;
  final bool enabled;
  final SyncConnection connection;
  final bool syncing;
  final DateTime? lastSynced;

  /// Local records not yet on the hub.
  final int pendingCount;
  final int conflictCount;
  final bool lastAttemptFailed;
}

class SyncDiagnosis {
  const SyncDiagnosis({
    required this.level,
    required this.title,
    required this.detail,
    required this.steps,
    this.help = const [],
  });

  final SyncLevel level;
  final String title;
  final String detail;

  /// Safe actions the center offers, best first.
  final List<SyncStep> steps;

  /// Plain-words things to check, when the fix is outside the app.
  final List<String> help;
}

String _changes(int n) => n == 1 ? '1 change' : '$n changes';

/// The one most important thing about sync right now.
SyncDiagnosis diagnoseSync(SyncFacts f) {
  if (!f.paired && !f.needsPairing) {
    return const SyncDiagnosis(
      level: SyncLevel.ok,
      title: 'This device is not connected to a sync hub',
      detail:
          'Everything is stored on this device only. Nothing is waiting to '
          'sync. Connect a hub in Settings if you want your devices to share '
          'your data.',
      steps: [SyncStep.none],
    );
  }
  if (f.needsPairing) {
    return SyncDiagnosis(
      level: SyncLevel.problem,
      title: 'This device must be paired again',
      detail:
          'The hub does not accept this device any more (it was removed, '
          'the hub was reset, or the sync key is missing). Your data here is '
          'safe${f.pendingCount > 0 ? ' and ${_changes(f.pendingCount)} will be sent after pairing' : ''}.',
      steps: const [SyncStep.pairAgain],
      help: const [
        'Disconnect this device in Settings, then pair it again with a new '
            'code from the hub.',
      ],
    );
  }
  if (!f.enabled) {
    return SyncDiagnosis(
      level: SyncLevel.attention,
      title: 'Sync is switched off',
      detail:
          'Changes are saved here'
          '${f.pendingCount > 0 ? ' (${_changes(f.pendingCount)} waiting)' : ''}'
          ' and go out when sync is turned back on. Nothing is deleted.',
      steps: const [SyncStep.turnOnSync],
    );
  }
  if (f.connection == SyncConnection.paused) {
    return SyncDiagnosis(
      level: SyncLevel.attention,
      title: 'Sync is paused on the PC',
      detail:
          'The switch on the PC is off. Your changes are saved here'
          '${f.pendingCount > 0 ? ' (${_changes(f.pendingCount)} waiting)' : ''}'
          ' and sync once it is turned on.',
      steps: const [SyncStep.none],
      help: const ['Turn "Sync between devices" on in the PC app.'],
    );
  }
  if (f.connection == SyncConnection.blocked) {
    // The hub answers but refuses this device's sync for a reason waiting
    // does not fix (e.g. an app version it does not accept). The scheduler
    // retries calmly on its own.
    return SyncDiagnosis(
      level: SyncLevel.problem,
      title: 'The hub refuses to sync with this device',
      detail:
          'Your changes are saved here'
          '${f.pendingCount > 0 ? ' (${_changes(f.pendingCount)} waiting)' : ''}'
          '. The hub can be reached but does not accept sync from this device '
          'right now; the app asks again by itself every few minutes.',
      steps: const [SyncStep.syncNow],
      help: const [
        'Update misc. on this device and on the PC to the same version.',
        'If this device was removed from the hub, disconnect and pair again.',
      ],
    );
  }
  if (f.connection == SyncConnection.offline) {
    return SyncDiagnosis(
      level: SyncLevel.waiting,
      title: 'The hub cannot be reached',
      detail:
          'Your changes are saved on this device'
          '${f.pendingCount > 0 ? ' (${_changes(f.pendingCount)} waiting)' : ''}'
          ' and will be sent as soon as the hub is back. The app keeps '
          'trying.',
      steps: const [SyncStep.syncNow],
      help: const [
        'Check that the PC is on and misc. (or its hub) is running there.',
        'Check that this device is on the same network, or that Tailscale '
            'is connected.',
        'Press Sync now to try again right away.',
      ],
    );
  }
  if (f.conflictCount > 0) {
    return SyncDiagnosis(
      level: SyncLevel.attention,
      title: f.conflictCount == 1
          ? '1 conflict needs a look'
          : '${f.conflictCount} conflicts need a look',
      detail:
          'The same item was changed on two devices. Both versions were '
          'kept: nothing was lost. Choose which one to keep.',
      steps: const [SyncStep.reviewConflicts, SyncStep.syncNow],
    );
  }
  if (f.lastAttemptFailed && !f.syncing) {
    return SyncDiagnosis(
      level: SyncLevel.waiting,
      title: 'The last sync did not finish',
      detail:
          'Your changes are safe on this device'
          '${f.pendingCount > 0 ? ' (${_changes(f.pendingCount)} waiting)' : ''}'
          '. It will try again by itself.',
      steps: const [SyncStep.syncNow],
    );
  }
  if (f.pendingCount > 0) {
    return SyncDiagnosis(
      level: SyncLevel.waiting,
      title: '${_changes(f.pendingCount)} waiting to sync',
      detail: f.syncing
          ? 'Sending now.'
          : 'They go out within a minute, or press Sync now.',
      steps: const [SyncStep.syncNow],
    );
  }
  if (f.lastSynced == null) {
    return const SyncDiagnosis(
      level: SyncLevel.waiting,
      title: 'Waiting for the first sync',
      detail: 'This device is paired and will sync shortly.',
      steps: [SyncStep.syncNow],
    );
  }
  return const SyncDiagnosis(
    level: SyncLevel.ok,
    title: 'Everything is synced',
    detail: 'Nothing is waiting and there are no conflicts.',
    steps: [SyncStep.none],
  );
}

String connectionLabel(SyncFacts f) {
  if (!f.paired && !f.needsPairing) return 'Not connected';
  if (f.needsPairing) return 'Needs pairing';
  if (!f.enabled) return 'Switched off';
  return switch (f.connection) {
    SyncConnection.live => 'Connected (live)',
    SyncConnection.polling => 'Connected',
    SyncConnection.offline => 'Hub not reachable',
    SyncConnection.paused => 'Paused on the PC',
    SyncConnection.stopped => 'Not running',
    SyncConnection.blocked => 'Refused by the hub',
  };
}

String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String agoLabel(DateTime? at, DateTime now) =>
    at == null ? 'not yet' : _ago(at, now);

/// Text to copy for support or a bug report. Counts and states only.
String syncDiagnosticsText({
  required SyncFacts facts,
  required SyncDiagnosis diagnosis,
  required Map<String, int> pendingByKind,
  required List<SyncAttempt> history,
  required DateTime now,
}) {
  final b = StringBuffer()
    ..writeln('misc. sync report')
    ..writeln('Status: ${diagnosis.title}')
    ..writeln('Connection: ${connectionLabel(facts)}')
    ..writeln('Sync switch: ${facts.enabled ? 'on' : 'off'}')
    ..writeln('Last successful sync: ${agoLabel(facts.lastSynced, now)}')
    ..writeln('Changes waiting: ${facts.pendingCount}')
    ..writeln('Conflicts: ${facts.conflictCount}');
  for (final e in pendingByKind.entries) {
    b.writeln('  waiting ${e.key}: ${e.value}');
  }
  b.writeln('Recent attempts:');
  for (final a in history.reversed.take(10)) {
    b.writeln(
      '  ${a.ok ? 'ok  ' : 'FAIL'} ${_ago(a.at, now)}: ${scrubDiagnostic(a.text)}',
    );
  }
  return b.toString();
}

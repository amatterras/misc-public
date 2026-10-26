// Cross-Device Handoff: each device records where its user is (which page,
// which note or mindmap, the middle of the mindmap view) and another device
// can resume it on request. It is not live collaboration: nothing moves by
// itself, nothing takes input focus, and resuming never discards anything.
//
// Storage uses an existing synced record type: a revoked ShareLink of kind
// 'handoff' (id `handoff-<device id>`, so each device owns one record and
// two devices never overwrite each other). A revoked link can never be
// served by the hub. The record holds ids and numbers only: no titles, no
// text. The receiving device looks titles up in its own copy of the data.
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import '../../app/app_state.dart';
import '../../data/models/knowledge_models.dart';

const handoffKind = 'handoff';

String handoffRecordId(String deviceId) => 'handoff-$deviceId';

/// Where one device's user is.
class ResumeState {
  const ResumeState({
    required this.deviceId,
    required this.deviceName,
    required this.at,
    required this.page,
    this.noteId,
    this.canvasId,
    this.center,
  });

  final String deviceId;

  /// The device's own name (not a person's); shown to tell devices apart.
  final String deviceName;
  final DateTime at;

  /// An [AppPage] name.
  final String page;
  final String? noteId;
  final String? canvasId;

  /// The world point in the middle of the mindmap view. The receiving device
  /// keeps its own zoom and window size (layout stays per device).
  final Offset? center;

  /// Same place, ignoring who/when (used to avoid writing unchanged state).
  bool sameSpot(ResumeState o) =>
      page == o.page &&
      noteId == o.noteId &&
      canvasId == o.canvasId &&
      ((center == null && o.center == null) ||
          (center != null &&
              o.center != null &&
              (center! - o.center!).distance < 40));

  Map<String, dynamic> toJson() => {
    'page': page,
    'at': at.toUtc().toIso8601String(),
    'name': deviceName,
    'noteId': ?noteId,
    'canvasId': ?canvasId,
    if (center != null) 'cx': center!.dx.roundToDouble(),
    if (center != null) 'cy': center!.dy.roundToDouble(),
  };

  /// Null when [raw] is not a usable state (damaged or from a future
  /// version); nothing is guessed.
  static ResumeState? fromJson(String deviceId, Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    final page = raw['page'];
    if (at == null || page is! String || page.isEmpty) return null;
    String? id(Object? v) => v is String && v.isNotEmpty ? v : null;
    final cx = raw['cx'], cy = raw['cy'];
    return ResumeState(
      deviceId: deviceId,
      deviceName: raw['name'] is String ? raw['name'] as String : 'Another device',
      at: at.toUtc(),
      page: page,
      noteId: id(raw['noteId']),
      canvasId: id(raw['canvasId']),
      center: cx is num && cy is num
          ? Offset(cx.toDouble(), cy.toDouble())
          : null,
    );
  }

  ShareLink toRecord() => ShareLink(
    id: handoffRecordId(deviceId),
    kind: handoffKind,
    sourceId: deviceId,
    title: '',
    body: jsonEncode(toJson()),
    createdAt: at,
    updatedAt: at,
    revoked: true,
  );

  static ResumeState? fromRecord(ShareLink l) {
    if (l.kind != handoffKind || l.sourceId.isEmpty) return null;
    try {
      return fromJson(l.sourceId, jsonDecode(l.body));
    } catch (_) {
      return null;
    }
  }
}

/// A state from [maxAge] ago is "old": offered, but never suggested.
const staleAfter = Duration(hours: 24);

/// States this close in time can both be "the latest": the user picks.
const conflictWindow = Duration(minutes: 5);

class ResumeChoice {
  const ResumeChoice({
    required this.candidates,
    required this.suggested,
    required this.needsChoice,
    required this.localIsNewer,
  });

  /// Other devices' states, newest first.
  final List<ResumeState> candidates;

  /// The one to offer first, when it is unambiguous.
  final ResumeState? suggested;

  /// Several recent states compete: ask, do not guess.
  final bool needsChoice;

  /// This device was used after the newest other state.
  final bool localIsNewer;
}

/// Picks among other devices' states, predictably:
/// * old states (over 24 h) are listed but never suggested;
/// * one recent state newer than this device's own is suggested;
/// * several recent states within 5 minutes of each other, or one within
///   5 minutes of this device's own use, need the user's choice.
ResumeChoice chooseResume(
  List<ResumeState> others, {
  required ResumeState? local,
  required DateTime now,
}) {
  final list = [...others]..sort((a, b) => b.at.compareTo(a.at));
  final fresh = [
    for (final s in list)
      if (now.difference(s.at) <= staleAfter) s,
  ];
  final newest = list.isEmpty ? null : list.first;
  final localIsNewer =
      local != null && (newest == null || local.at.isAfter(newest.at));
  if (fresh.isEmpty) {
    return ResumeChoice(
      candidates: list,
      suggested: null,
      needsChoice: false,
      localIsNewer: localIsNewer,
    );
  }
  final top = fresh.first;
  final rivals = fresh
      .skip(1)
      .where((s) => top.at.difference(s.at) <= conflictWindow);
  final againstLocal =
      local != null &&
      !local.sameSpot(top) &&
      (top.at.difference(local.at)).abs() <= conflictWindow;
  final needs = rivals.isNotEmpty || againstLocal;
  return ResumeChoice(
    candidates: list,
    suggested: needs || localIsNewer ? null : top,
    needsChoice: needs,
    localIsNewer: localIsNewer,
  );
}

/// Records this device's place and reads the others'.
class HandoffService {
  HandoffService(this.s, {DateTime Function()? now, this.interval})
    : _now = now ?? DateTime.now;

  final AppState s;
  final DateTime Function() _now;
  final Duration? interval;
  Timer? _timer;
  ResumeState? _last;

  /// Smallest gap between two writes, so moving around does not make a
  /// stream of sync traffic.
  static const minGap = Duration(seconds: 15);

  bool get enabled => s.settings.get<bool>('handoffEnabled') ?? true;

  Future<void> setEnabled(bool on) async {
    await s.settings.set('handoffEnabled', on);
    if (on) {
      start();
      publishNow();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void start() {
    if (!enabled) return;
    _timer?.cancel();
    _timer = Timer.periodic(interval ?? minGap, (_) => publishNow());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Where this device's user is now (null before the device is known).
  ResumeState? capture() {
    final device = s.workspace.device;
    if (device == null) return null;
    final page = s.page;
    String? noteId, canvasId;
    Offset? center;
    switch (page) {
      case AppPage.notes:
        noteId = s.selectedNoteId;
      case AppPage.canvas:
        final c = s.canvas;
        if (c != null) {
          canvasId = c.id;
          if (!c.viewportSize.isEmpty) {
            center = (c.viewportSize.center(Offset.zero) - c.offset) / c.scale;
          }
        }
      default:
        break;
    }
    return ResumeState(
      deviceId: device.id,
      deviceName: device.name,
      at: _now().toUtc(),
      page: page.name,
      noteId: noteId,
      canvasId: canvasId,
      center: center,
    );
  }

  /// Writes the current place if it changed. Returns whether it wrote.
  bool publishNow() {
    if (!enabled) return false;
    final now = capture();
    if (now == null) return false;
    final last = _last;
    if (last != null && last.sameSpot(now)) return false;
    _last = now;
    s.workspace.shares.put(now.toRecord());
    return true;
  }

  /// The state this device last wrote.
  ResumeState? get own {
    final id = s.workspace.device?.id;
    if (id == null) return null;
    final l = s.workspace.shares[handoffRecordId(id)];
    return l == null ? null : ResumeState.fromRecord(l);
  }

  /// States other devices wrote (damaged ones are ignored).
  List<ResumeState> others() {
    final me = s.workspace.device?.id;
    return [
      for (final l in s.workspace.shares.all)
        if (l.kind == handoffKind && l.sourceId != me)
          ?ResumeState.fromRecord(l),
    ]..sort((a, b) => b.at.compareTo(a.at));
  }

  ResumeChoice choice() =>
      chooseResume(others(), local: own, now: _now().toUtc());

  /// Whether this device's latest place has not reached the hub yet.
  Future<bool> ownUnsynced() async {
    final id = s.workspace.device?.id;
    if (id == null) return false;
    return s.syncRecordPending('shares', handoffRecordId(id));
  }
}

enum ResumeOutcome {
  opened,

  /// The note or mindmap is not on this device (yet): it may not have
  /// synced here.
  notOnThisDevice,
}

/// Opens [r] on this device. Unsaved work is saved first, nothing is
/// closed or discarded, and the device keeps its own zoom.
Future<ResumeOutcome> applyResume(AppState s, ResumeState r) async {
  await s.flush();
  if (r.noteId != null && r.page == AppPage.notes.name) {
    if (s.workspace.notes[r.noteId!] == null) {
      return ResumeOutcome.notOnThisDevice;
    }
    s.openNote(r.noteId!);
    return ResumeOutcome.opened;
  }
  if (r.canvasId != null && r.page == AppPage.canvas.name) {
    if (!s.canvasList.any((c) => c.id == r.canvasId)) {
      return ResumeOutcome.notOnThisDevice;
    }
    await s.openCanvas(r.canvasId!);
    final c = s.canvas;
    final center = r.center;
    if (c != null && center != null) {
      for (var i = 0; i < 20 && c.viewportSize.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!c.viewportSize.isEmpty) c.centerOn(center, c.viewportSize);
    }
    return ResumeOutcome.opened;
  }
  final page = AppPage.values.where((p) => p.name == r.page).firstOrNull;
  if (page != null) s.goTo(page);
  return ResumeOutcome.opened;
}

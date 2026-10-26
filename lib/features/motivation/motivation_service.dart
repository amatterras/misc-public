import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LocalTimeSnapshot {
  const LocalTimeSnapshot({required this.now, required this.utcOffset});

  /// Wall-clock time returned by the operating system in its current zone.
  final DateTime now;
  final Duration utcOffset;

  factory LocalTimeSnapshot.system() {
    final now = DateTime.now();
    return LocalTimeSnapshot(now: now, utcOffset: now.timeZoneOffset);
  }
}

class MotivationQuote {
  const MotivationQuote({
    required this.id,
    required this.collection,
    required this.text,
    required this.attribution,
    required this.order,
  });

  final String id;
  final String collection;
  final String text;
  final String attribution;
  final int order;

  factory MotivationQuote.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final collection = json['collection'];
    final text = json['quote'];
    final attribution = json['display_attribution'] ?? json['author'] ?? '';
    final order = json['order'];
    if (id is! String ||
        id.isEmpty ||
        collection is! String ||
        collection.isEmpty ||
        text is! String ||
        text.trim().isEmpty ||
        attribution is! String ||
        order is! int) {
      throw const FormatException('Invalid motivational quote entry');
    }
    return MotivationQuote(
      id: id,
      collection: collection,
      text: text,
      attribution: attribution,
      order: order,
    );
  }
}

class GreetingSlot {
  const GreetingSlot({required this.label, required this.greetings});

  final String label;
  final List<String> greetings;
}

/// Loads the bundled libraries and owns their session and hourly timing.
class MotivationService extends ChangeNotifier with WidgetsBindingObserver {
  MotivationService({
    LocalTimeSnapshot Function()? localTime,
    int Function(int)? nextIndex,
  }) : _localTime = localTime ?? LocalTimeSnapshot.system,
       _nextIndex = nextIndex ?? Random().nextInt;

  static const greetingDuration = Duration(seconds: 60);
  static const _quotesAsset = 'assets/motivation/quotes.json';
  static const _greetingsAsset = 'assets/motivation/greetings.json';
  static const _clockPollInterval = Duration(seconds: 30);

  final LocalTimeSnapshot Function() _localTime;
  final int Function(int) _nextIndex;
  List<MotivationQuote> quotes = const [];
  List<GreetingSlot> slots = const [];
  MotivationQuote? quote;
  String? greeting;
  String? greetingSlotLabel;
  bool _loaded = false;
  bool _disposed = false;
  (int, int, int, int, int)? _quoteHourKey;
  int? _activeGreetingSlot;
  Timer? _greetingTimer;
  Timer? _quoteTimer;
  Timer? _clockPollTimer;

  bool get loaded => _loaded;
  bool get greetingVisible => greeting != null;
  int? get activeGreetingSlotIndex => _activeGreetingSlot;

  Future<void> load({AssetBundle? bundle}) async {
    if (_loaded) return;
    final assets = bundle ?? rootBundle;
    final values = await Future.wait([
      assets.loadString(_quotesAsset),
      assets.loadString(_greetingsAsset),
    ]);
    loadFromSources(values[0], values[1]);
  }

  /// Initializes from already-loaded library text. This is also useful to
  /// validate the UI with deterministic in-memory test data.
  void loadFromSources(String quoteSource, String greetingSource) {
    if (_loaded || _disposed) return;
    quotes = parseQuotes(quoteSource);
    _deck.clear();
    slots = parseGreetingSlots(greetingSource);
    // At least the original 1,000 quotes and 100 greetings per slot; the
    // user's own additions come after them.
    if (quotes.length < 1000 ||
        !quotes.asMap().entries.every(
          (entry) => entry.value.order == entry.key + 1,
        ) ||
        quotes.map((quote) => quote.id).toSet().length != quotes.length ||
        slots.length != 6 ||
        slots.any((slot) => slot.greetings.length < 100)) {
      throw const FormatException(
        'Expected 1,000+ quotes and six slots of 100+ greetings',
      );
    }
    _loaded = true;
    WidgetsBinding.instance.addObserver(this);
    final time = _localTime();
    _refreshQuote(time);
    _activeGreetingSlot = greetingSlotIndex(time.now.hour);
    _showGreetingFromActiveSlot();
    _scheduleQuoteTimer(time);
    _clockPollTimer = Timer.periodic(_clockPollInterval, (_) => refresh());
    notifyListeners();
  }

  static List<MotivationQuote> parseQuotes(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! List) {
      throw const FormatException('Quote library must be a JSON list');
    }
    final result = <MotivationQuote>[];
    for (final value in decoded) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid quote library entry');
      }
      result.add(MotivationQuote.fromJson(value));
    }
    result.sort((a, b) => a.order.compareTo(b.order));
    return result;
  }

  static List<GreetingSlot> parseGreetingSlots(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> || decoded['slots'] is! List) {
      throw const FormatException('Greeting library must contain slots');
    }
    return [
      for (final value in decoded['slots'] as List)
        if (value is Map<String, dynamic> &&
            value['label'] is String &&
            value['greetings'] is List)
          GreetingSlot(
            label: value['label'] as String,
            greetings: [
              for (final greeting in value['greetings'] as List)
                if (greeting is String && greeting.trim().isNotEmpty) greeting,
            ],
          )
        else
          throw const FormatException('Invalid greeting slot'),
    ];
  }

  /// Re-evaluates local-time content on clock changes and foreground.
  void refresh() {
    if (!_loaded || _disposed) return;
    final time = _localTime();
    final oldQuoteHour = _quoteHourKey;
    final oldSlot = _activeGreetingSlot;
    _refreshQuote(time);
    _activeGreetingSlot = greetingSlotIndex(time.now.hour);
    final changed =
        oldQuoteHour != _quoteHourKey || oldSlot != _activeGreetingSlot;
    _scheduleQuoteTimer(time);
    if (changed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  void _refreshQuote(LocalTimeSnapshot time) {
    final now = time.now;
    final hourKey = (
      now.year,
      now.month,
      now.day,
      now.hour,
      time.utcOffset.inMinutes,
    );
    if (hourKey == _quoteHourKey) return;
    _quoteHourKey = hourKey;
    quote = quotes[_nextQuoteIndex()];
  }

  // A shuffled deck of quote positions: every quote comes once before any
  // repeats, the order is random, and a new deck never starts with the
  // quote just shown. Each quote keeps its own attribution (whole records).
  final List<int> _deck = [];
  int? _lastQuote;

  int _nextQuoteIndex() {
    if (_deck.isEmpty) {
      _deck.addAll(List.generate(quotes.length, (i) => i));
      for (var i = _deck.length - 1; i > 0; i--) {
        final j = _nextIndex(i + 1);
        final t = _deck[i];
        _deck[i] = _deck[j];
        _deck[j] = t;
      }
      if (_deck.length > 1 && _deck.last == _lastQuote) {
        final t = _deck.last;
        _deck[_deck.length - 1] = _deck.first;
        _deck[0] = t;
      }
    }
    return _lastQuote = _deck.removeLast();
  }

  void _scheduleQuoteTimer(LocalTimeSnapshot time) {
    _quoteTimer?.cancel();
    final now = time.now;
    final nextHour = DateTime(now.year, now.month, now.day, now.hour + 1);
    var delay = nextHour.difference(now);
    if (delay <= Duration.zero) delay = const Duration(seconds: 1);
    _quoteTimer = Timer(delay, refresh);
  }

  /// Starts a greeting using the currently active local-time pool.
  /// The app calls this once at startup; future greeting triggers can use the
  /// same method after [refresh] has observed a clock or timezone change.
  void showGreeting() {
    if (!_loaded || _disposed) return;
    _activeGreetingSlot = greetingSlotIndex(_localTime().now.hour);
    _showGreetingFromActiveSlot();
    notifyListeners();
  }

  void _showGreetingFromActiveSlot() {
    final slot = slots[_activeGreetingSlot!];
    if (slot.greetings.isEmpty) return;
    final index = _nextIndex(slot.greetings.length)
        .clamp(0, slot.greetings.length - 1)
        .toInt();
    greeting = slot.greetings[index];
    greetingSlotLabel = slot.label;
    _greetingTimer?.cancel();
    _greetingTimer = Timer(greetingDuration, () {
      if (_disposed) return;
      greeting = null;
      notifyListeners();
    });
  }

  static int greetingSlotIndex(int hour) => switch (hour) {
    >= 5 && < 8 => 0,
    >= 8 && < 12 => 1,
    >= 12 && < 17 => 2,
    >= 17 && < 21 => 3,
    >= 21 => 4,
    _ => 5,
  };

  @override
  void dispose() {
    _disposed = true;
    _greetingTimer?.cancel();
    _quoteTimer?.cancel();
    _clockPollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

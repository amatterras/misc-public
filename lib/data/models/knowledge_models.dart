// Records for sharing and thinking: read-only share links served by the
// user's own hub, and thought experiments (assumptions kept apart from
// verified facts). Both sync.
import 'record.dart';

/// A read-only share of one item, served by the user's hub at
/// `/s/<token>`. The record id is the SHA-256 (hex) of the token, so the
/// hub can find it without the token itself being stored anywhere synced.
/// The shared content is a snapshot taken when the link was made.
class ShareLink implements Record {
  const ShareLink({
    required this.id,
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    this.expiresAt,
    this.revoked = false,
  });

  /// SHA-256 hex of the secret token.
  @override
  final String id;

  /// What was shared: 'note', 'link', 'entry', 'canvas', 'experiment'.
  final String kind;
  final String sourceId;
  final String title;

  /// Plain text; the hub escapes it before showing it.
  final String body;
  final DateTime createdAt;
  @override
  final DateTime updatedAt;
  final DateTime? expiresAt;
  final bool revoked;

  static const maxBodyChars = 200000;

  bool activeAt(DateTime now) =>
      !revoked && (expiresAt == null || now.isBefore(expiresAt!));

  ShareLink revoke() => ShareLink(
    id: id,
    kind: kind,
    sourceId: sourceId,
    title: title,
    body: body,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
    expiresAt: expiresAt,
    revoked: true,
  );

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'sourceId': sourceId,
    'title': title,
    'body': body,
    'createdAt': utcIso(createdAt),
    'updatedAt': utcIso(updatedAt),
    'expiresAt': expiresAt == null ? null : utcIso(expiresAt!),
    'revoked': revoked,
  };

  factory ShareLink.fromJson(Map<String, dynamic> j) => ShareLink(
    id: j['id'] as String,
    kind: j['kind'] as String? ?? 'note',
    sourceId: j['sourceId'] as String? ?? '',
    title: j['title'] as String? ?? '',
    body: j['body'] as String? ?? '',
    createdAt: parseDate(j['createdAt']) ?? DateTime.now(),
    updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
    expiresAt: parseDate(j['expiresAt']),
    revoked: j['revoked'] == true,
  );
}

/// Where a statement in a thought experiment comes from. Only `verified`
/// counts as a fact; everything else is shown as an assumption.
enum ClaimOrigin { assumption, verified, calculation, aiInference, unknown }

extension ClaimOriginLabel on ClaimOrigin {
  String get label => switch (this) {
    ClaimOrigin.assumption => 'Assumption',
    ClaimOrigin.verified => 'Verified fact',
    ClaimOrigin.calculation => 'Calculation',
    ClaimOrigin.aiInference => 'AI inference',
    ClaimOrigin.unknown => 'Unknown',
  };
}

/// One statement: an assumption, fact, variable value, outcome or open
/// question, with a stable id so scenarios can refer to it.
class Claim {
  const Claim({
    required this.id,
    required this.text,
    this.origin = ClaimOrigin.assumption,
    this.sourceIds = const [],
  });

  final String id;
  final String text;
  final ClaimOrigin origin;

  /// Ids of the notes/links/entries backing it (verified facts need one).
  final List<String> sourceIds;

  Claim copyWith({
    String? text,
    ClaimOrigin? origin,
    List<String>? sourceIds,
  }) => Claim(
    id: id,
    text: text ?? this.text,
    origin: origin ?? this.origin,
    sourceIds: sourceIds ?? this.sourceIds,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'origin': origin.name,
    if (sourceIds.isNotEmpty) 'sourceIds': sourceIds,
  };

  factory Claim.fromJson(Map<String, dynamic> j) => Claim(
    id: j['id'] as String,
    text: j['text'] as String? ?? '',
    origin: ClaimOrigin.values.asNameMap()[j['origin']] ?? ClaimOrigin.unknown,
    sourceIds: [
      for (final s in (j['sourceIds'] as List?) ?? const [])
        ?(s is String ? s : null),
    ],
  );
}

/// A scenario: which assumptions it relies on, its variable values and
/// its expected outcomes.
class Scenario {
  const Scenario({
    required this.id,
    required this.name,
    this.assumptionIds = const [],
    this.variables = const [],
    this.outcomes = const [],
  });

  final String id;
  final String name;
  final List<String> assumptionIds;
  final List<Claim> variables;
  final List<Claim> outcomes;

  Scenario copyWith({
    String? name,
    List<String>? assumptionIds,
    List<Claim>? variables,
    List<Claim>? outcomes,
  }) => Scenario(
    id: id,
    name: name ?? this.name,
    assumptionIds: assumptionIds ?? this.assumptionIds,
    variables: variables ?? this.variables,
    outcomes: outcomes ?? this.outcomes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'assumptionIds': assumptionIds,
    'variables': [for (final v in variables) v.toJson()],
    'outcomes': [for (final o in outcomes) o.toJson()],
  };

  factory Scenario.fromJson(Map<String, dynamic> j) => Scenario(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    assumptionIds: [
      for (final s in (j['assumptionIds'] as List?) ?? const [])
        ?(s is String ? s : null),
    ],
    variables: _claims(j['variables']),
    outcomes: _claims(j['outcomes']),
  );
}

List<Claim> _claims(Object? raw) => [
  for (final c in (raw as List?) ?? const [])
    if (c is Map<String, dynamic> && c['id'] is String) Claim.fromJson(c),
];

class ThoughtExperiment implements Record {
  const ThoughtExperiment({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.question = '',
    this.claims = const [],
    this.scenarios = const [],
    this.unknowns = const [],
  });

  @override
  final String id;
  final String title;
  final String question;

  /// Assumptions and facts shared by the scenarios.
  final List<Claim> claims;
  final List<Scenario> scenarios;

  /// Open questions nobody can answer yet.
  final List<Claim> unknowns;
  @override
  final DateTime updatedAt;

  ThoughtExperiment copyWith({
    String? title,
    String? question,
    List<Claim>? claims,
    List<Scenario>? scenarios,
    List<Claim>? unknowns,
  }) => ThoughtExperiment(
    id: id,
    title: title ?? this.title,
    question: question ?? this.question,
    claims: claims ?? this.claims,
    scenarios: scenarios ?? this.scenarios,
    unknowns: unknowns ?? this.unknowns,
    updatedAt: DateTime.now(),
  );

  /// A verified fact without a source is shown as unsupported.
  List<Claim> get unsupportedFacts => [
    for (final c in claims)
      if (c.origin == ClaimOrigin.verified && c.sourceIds.isEmpty) c,
  ];

  /// Plain-text summary (for notes, sharing and search).
  String toText() {
    final b = StringBuffer('$title\n');
    if (question.isNotEmpty) b.writeln('Question: $question');
    for (final c in claims) {
      b.writeln('- [${c.origin.label}] ${c.text}');
    }
    for (final s in scenarios) {
      b.writeln('\nScenario: ${s.name}');
      for (final id in s.assumptionIds) {
        final c = claims.where((c) => c.id == id).firstOrNull;
        if (c != null) b.writeln('  relies on: ${c.text}');
      }
      for (final v in s.variables) {
        b.writeln('  variable: ${v.text} (${v.origin.label})');
      }
      for (final o in s.outcomes) {
        b.writeln('  outcome: ${o.text} (${o.origin.label})');
      }
    }
    if (unknowns.isNotEmpty) b.writeln('\nUnknown:');
    for (final u in unknowns) {
      b.writeln('- ${u.text}');
    }
    return b.toString();
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'question': question,
    'claims': [for (final c in claims) c.toJson()],
    'scenarios': [for (final s in scenarios) s.toJson()],
    'unknowns': [for (final u in unknowns) u.toJson()],
    'updatedAt': utcIso(updatedAt),
  };

  factory ThoughtExperiment.fromJson(Map<String, dynamic> j) =>
      ThoughtExperiment(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        question: j['question'] as String? ?? '',
        claims: _claims(j['claims']),
        scenarios: [
          for (final s in (j['scenarios'] as List?) ?? const [])
            if (s is Map<String, dynamic> && s['id'] is String)
              Scenario.fromJson(s),
        ],
        unknowns: _claims(j['unknowns']),
        updatedAt: parseDate(j['updatedAt']) ?? DateTime.now(),
      );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/sync/local_hub.dart';

void main() {
  test('newlyPairedDevices: only new, not removed, not this PC', () {
    final now = [
      (id: 'pc', name: 'PC', revoked: false),
      (id: 'old', name: 'iPhone', revoked: false),
      (id: 'gone', name: 'Old iPad', revoked: true),
      (id: 'ipad', name: 'iPad', revoked: false),
    ];
    final fresh = newlyPairedDevices({'old'}, now, selfId: 'pc');
    expect(fresh.map((d) => d.id), ['ipad']);
  });

  test('localHubDevices is null in tests (no real hub touched)', () async {
    expect(await localHubDevices(), isNull);
  });
}

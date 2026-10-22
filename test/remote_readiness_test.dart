// Remote sync readiness: which hub addresses devices accept and which
// addresses the hub may listen on. Remote sync is designed to run over a
// private Tailscale network (free personal plan); nothing is exposed
// publicly. See SYNC_ARCHITECTURE.md §17.
import 'dart:io';

import 'package:flutter_application_1/hub/hub_server.dart';
import 'package:flutter_application_1/sync/sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('devices accept only this PC, private networks and Tailscale', () {
    for (final ok in [
      'http://127.0.0.1:47710',
      'http://localhost:47710',
      'http://192.168.1.20:47710',
      'http://10.0.0.5:47710',
      'http://172.16.4.2:47710',
      'http://100.101.102.103:47710', // Tailscale range 100.64.0.0/10
      'http://my-pc.tail1234.ts.net:47710', // Tailscale MagicDNS name
    ]) {
      expect(isAllowedHubUrl(Uri.parse(ok)), isTrue, reason: ok);
    }
    for (final bad in [
      'http://8.8.8.8:47710', // public address
      'http://203.0.113.9:47710',
      'http://100.128.0.1:47710', // just outside the Tailscale range
      'http://example.com:47710', // public name
      'http://hub.example.ts.net.evil.com:47710',
      'ftp://127.0.0.1:47710',
      'file:///C:/hub',
    ]) {
      expect(isAllowedHubUrl(Uri.parse(bad)), isFalse, reason: bad);
    }
  });

  test('only this PC and Tailscale count as an encrypted route', () {
    for (final yes in [
      'http://127.0.0.1:47710',
      'http://localhost:47710',
      'http://100.64.0.1:47710',
      'http://100.127.255.254:47710',
      'http://pc.tail1234.ts.net:47710',
      'http://[fd7a:115c:a1e0::1]:47710',
    ]) {
      expect(isEncryptedHubRoute(Uri.parse(yes)), isTrue, reason: yes);
    }
    for (final no in [
      'http://192.168.1.20:47710',
      'http://10.0.0.5:47710',
      'http://172.16.4.2:47710',
      'http://100.128.0.1:47710',
      'http://[fd12::1]:47710',
    ]) {
      expect(isEncryptedHubRoute(Uri.parse(no)), isFalse, reason: no);
    }
  });

  test('a client refuses to be created for a public address', () {
    expect(
      () => SyncClient(Uri.parse('http://8.8.8.8:47710')),
      throwsA(isA<SyncFailure>()),
    );
  });

  test('the hub may only listen on loopback or private addresses', () {
    for (final ok in ['127.0.0.1', '192.168.0.10', '100.64.0.1', 'fd12::1']) {
      expect(isAllowedBindAddress(InternetAddress(ok)), isTrue, reason: ok);
    }
    for (final bad in ['0.0.0.0', '8.8.8.8', '::']) {
      expect(isAllowedBindAddress(InternetAddress(bad)), isFalse, reason: bad);
    }
  });
}

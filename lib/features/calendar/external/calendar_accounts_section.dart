// Settings → Calendar accounts: connect Google Calendar and/or Outlook
// (each on its own), choose a calendar, choose whether THEapp's
// Reminder/Event entries are sent there, sync, and see the last result.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../app/theme.dart';
import '../../../platform/platform.dart' as native;
import 'external_calendar.dart';
import 'oauth.dart';

class CalendarAccountsSection extends StatefulWidget {
  const CalendarAccountsSection({super.key, required this.state});
  final AppState state;

  @override
  State<CalendarAccountsSection> createState() =>
      _CalendarAccountsSectionState();
}

class _CalendarAccountsSectionState extends State<CalendarAccountsSection> {
  final Map<String, bool> _connected = {};
  final Map<String, List<RemoteCalendar>> _calendars = {};
  final Map<String, String> _error = {};
  final Set<String> _busy = {};
  late final _googleId = TextEditingController(
    text: s.settings.get<String>('calendar.google.clientId') ?? '',
  );
  final _googleSecret = TextEditingController();
  late final _googleIos = TextEditingController(
    text: s.settings.get<String>('calendar.google.iosRedirect') ?? '',
  );
  late final _msId = TextEditingController(
    text: s.settings.get<String>('calendar.microsoft.clientId') ?? '',
  );

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.loadCalendarSecrets();
    for (final MapEntry(:key, :value) in s.calendarAccounts.entries) {
      value.connected.then((c) {
        if (mounted) setState(() => _connected[key] = c);
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_googleId, _googleSecret, _googleIos, _msId]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(String key, Future<void> Function() f) async {
    setState(() {
      _busy.add(key);
      _error.remove(key);
    });
    try {
      await f();
    } on OAuthException catch (e) {
      _error[key] = e.message;
    } on ProviderException catch (e) {
      _error[key] = e.message;
    } catch (_) {
      _error[key] = 'That did not work. Check the connection and setup.';
    }
    if (mounted) setState(() => _busy.remove(key));
  }

  Widget _account(String key, String title, List<Widget> setup) {
    final a = s.calendarAccounts[key]!;
    final connected = _connected[key] ?? false;
    final busy = _busy.contains(key);
    final last = a.lastSuccess;
    const small = TextStyle(fontSize: 12, color: AppColors.textFaint);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (!connected) ...setup,
          Wrap(
            spacing: Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!connected)
                FilledButton(
                  key: ValueKey('calendar-connect-$key'),
                  onPressed: busy
                      ? null
                      : () => _run(key, () async {
                          await _saveSetup();
                          await a.connect(
                            openBrowser: native.openUrl,
                            mobile: Platform.isIOS,
                          );
                          _connected[key] = true;
                          _calendars[key] = await a.api.calendars();
                        }),
                  child: Text(busy ? 'Waiting for sign-in…' : 'Connect'),
                )
              else ...[
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(
                          key,
                          () async => _calendars[key] = await a.api.calendars(),
                        ),
                  child: Text(
                    a.calendarName.isEmpty
                        ? 'Choose a calendar'
                        : 'Calendar: ${a.calendarName}',
                  ),
                ),
                TextButton(
                  key: ValueKey('calendar-sync-$key'),
                  onPressed: busy || a.calendarId == null
                      ? null
                      : () => _run(key, () async {
                          await a.syncOnce();
                        }),
                  child: Text(busy ? 'Syncing…' : 'Sync now'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(key, () async {
                          await a.disconnect();
                          _connected[key] = false;
                        }),
                  child: const Text('Disconnect'),
                ),
              ],
            ],
          ),
          if (_calendars[key] case final list? when connected)
            Wrap(
              spacing: 6,
              children: [
                for (final c in list)
                  ChoiceChip(
                    label: Text(c.name + (c.primary ? ' (main)' : '')),
                    selected: c.id == a.calendarId,
                    onSelected: (_) => _run(key, () async {
                      await a.chooseCalendar(c);
                      await a.syncOnce();
                    }),
                  ),
              ],
            ),
          if (connected)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: a.exportEntries,
              onChanged: (v) => _run(key, () async {
                await a.setExport(v);
                if (a.calendarId != null && connected) await a.syncOnce();
              }),
              title: const Text(
                'Also send my Reminder/Event entries there',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                'THEapp entries sync both ways. Provider-created events are '
                'shown here read-only; edit those in Google Calendar or Outlook. '
                'Connected calendars refresh every 5 minutes while the app is open.',
                style: small,
              ),
            ),
          if (a.status.isNotEmpty || last != null)
            Text(
              '${a.status}${last == null ? '' : '  ·  last success ${last.toLocal().toString().split('.').first}'}',
              style: small,
            ),
          if (_error[key] case final e?)
            Text(
              e,
              style: const TextStyle(fontSize: 12, color: AppColors.warm),
            ),
        ],
      ),
    );
  }

  Future<void> _saveSetup() async {
    await s.settings.set('calendar.google.clientId', _googleId.text.trim());
    await s.settings.set('calendar.google.iosRedirect', _googleIos.text.trim());
    await s.settings.set('calendar.microsoft.clientId', _msId.text.trim());
    if (_googleSecret.text.trim().isNotEmpty) {
      await s.setGoogleClientSecret(_googleSecret.text);
      _googleSecret.clear();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('calendar-accounts'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Optional. Uses your own Google Cloud / Microsoft app registration '
        '(set up once; see the setup notes). You sign in on the provider\'s '
        'own page; THEapp never sees your password.',
        style: TextStyle(fontSize: 12, color: AppColors.textFaint),
      ),
      const SizedBox(height: Space.sm),
      _account('google', 'Google Calendar', [
        TextField(
          controller: _googleId,
          decoration: const InputDecoration(labelText: 'Google client ID'),
        ),
        TextField(
          controller: _googleSecret,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Google client secret (Desktop app; stored protected)',
          ),
        ),
        if (Platform.isIOS)
          TextField(
            controller: _googleIos,
            decoration: const InputDecoration(
              labelText:
                  'iOS redirect (com.googleusercontent.apps.…:/oauth2redirect)',
            ),
          ),
      ]),
      _account('microsoft', 'Outlook Calendar (Microsoft)', [
        TextField(
          controller: _msId,
          decoration: const InputDecoration(
            labelText: 'Microsoft application (client) ID',
          ),
        ),
      ]),
    ],
  );
}

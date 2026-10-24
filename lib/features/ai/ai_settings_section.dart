// Settings → AI: the master switch, which service, what may be sent and
// how much. Explains costs plainly; nothing here sends anything except
// "Test connection", which sends one short test sentence.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/storage/app_log.dart';
import 'ai_service.dart';

class AiSettingsSection extends StatefulWidget {
  const AiSettingsSection({super.key, required this.state});

  final AppState state;

  @override
  State<AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends State<AiSettingsSection> {
  late final _endpoint = TextEditingController(text: ai.endpoint);
  late final _model = TextEditingController(text: ai.model);
  late final _workingRules = TextEditingController(text: ai.workingRules);
  final _key = TextEditingController();
  String? _test;
  bool _testing = false;
  bool _hasKey = false;

  AiSettings get ai => widget.state.ai;

  @override
  void initState() {
    super.initState();
    widget.state.hasAiKey.then((v) {
      if (mounted) setState(() => _hasKey = v);
    });
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _model.dispose();
    _workingRules.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _change(Future<void> Function() f) async {
    await f();
    if (mounted) setState(() {});
  }

  /// The AI activity log: when, where to, what kinds and how much.
  Future<void> _showActivity(BuildContext context) {
    final ai = widget.state.ai;
    final list = ai.activity.reversed.toList();
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'What was sent to AI',
          style: TextStyle(fontSize: 16),
        ),
        content: SizedBox(
          width: 460,
          height: 340,
          child: list.isEmpty
              ? const Center(child: Text('Nothing has been sent.'))
              : ListView(
                  children: [
                    const Text(
                      'Only a record of each request is kept here (on this '
                      'device), not what was in it.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textFaint,
                      ),
                    ),
                    for (final e in list)
                      ListTile(
                        dense: true,
                        title: Text(
                          '${'${e['at']}'.replaceFirst('T', ' ').split('.').first} UTC · ${e['tool']}',
                        ),
                        subtitle: Text(
                          '${e['local'] == true ? 'This PC' : e['host']} '
                          '(${e['model']}) · ${e['chars']} characters'
                          '${(e['images'] ?? 0) == 0 ? '' : ' · ${e['images']} picture(s)'}'
                          '${(e['sources'] as List?)?.isNotEmpty ?? false ? ' · ${(e['sources'] as List).join(', ')}' : ''}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await ai.clearActivity();
              if (context.mounted) Navigator.pop(context);
              if (mounted) setState(() {});
            },
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _test = 'Testing…';
    });
    try {
      final report = await testAiConnection(
        await widget.state.aiClient(),
        ai.model,
      );
      _test = [
        report.ok ? 'Connected.' : 'Not working yet.',
        ...report.steps,
      ].join('\n');
    } catch (e, stack) {
      // Reading the protected key can fail (e.g. moved to another user).
      AppLog.error('AI test could not start', redactSecrets('$e'), stack);
      _test =
          'The test could not start: the saved key could not be read. '
          'Save the key again.';
    }
    _testing = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(fontSize: 12, color: AppColors.textFaint);
    return Column(
      key: const ValueKey('ai-settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey('ai-enabled'),
          contentPadding: EdgeInsets.zero,
          value: ai.enabled,
          onChanged: (v) => _change(() => ai.setEnabled(v)),
          title: const Text('Use AI', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            'Off: nothing is ever sent. On: still only what you attach and '
            'send yourself from the AI window.',
            style: small,
          ),
        ),
        if (ai.enabled) ...[
          const Text(
            'Free: install Ollama on this PC and a model (e.g. llama3.2); '
            'THEapp talks to it on this PC only. A ChatGPT subscription does '
            'not include API access — the OpenAI option needs a separate '
            'API key that is paid per use.',
            style: small,
          ),
          DropdownButton<AiProvider>(
            isExpanded: true,
            value: ai.provider,
            items: [
              for (final p in AiProvider.values)
                DropdownMenuItem(value: p, child: Text(p.label)),
            ],
            onChanged: (p) => _change(() async {
              if (p == null) return;
              await ai.setProvider(p);
              // Each service keeps its own address, model and key.
              _endpoint.text = ai.endpoint;
              _model.text = ai.model;
              _hasKey = await widget.state.hasAiKey;
            }),
          ),
          TextField(
            controller: _endpoint,
            decoration: const InputDecoration(labelText: 'Address'),
            onSubmitted: (v) => _change(() => ai.setEndpoint(v)),
            onChanged: (v) => _change(() => ai.setEndpoint(v)),
          ),
          if (!ai.isLocal)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'This address is not this PC: what you send leaves the PC. '
                'Search by meaning is off for addresses outside this PC.',
                style: TextStyle(fontSize: 12, color: AppColors.warm),
              ),
            ),
          TextField(
            controller: _model,
            decoration: const InputDecoration(labelText: 'Model'),
            onChanged: (v) => _change(() => ai.setModel(v)),
          ),
          if (retiredModelWarning(ai.model) case final warning?)
            Padding(
              key: const ValueKey('ai-model-retired'),
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                warning,
                style: const TextStyle(fontSize: 12, color: AppColors.warm),
              ),
            ),
          const SizedBox(height: Space.sm),
          TextField(
            controller: _workingRules,
            minLines: 2,
            maxLines: 5,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: 'Your AI working rules',
              helperText:
                  'Included with each request you send. These guide the model; '
                  'source permissions below still control what can be sent.',
            ),
            onChanged: (v) => ai.setWorkingRules(v),
          ),
          if (ai.provider == AiProvider.gemini)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Get a key at aistudio.google.com (Google may charge for use '
                'beyond its free tier). The key is stored protected on this '
                'device only.',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
              ),
            ),
          if (ai.provider.needsKey)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _key,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: _hasKey
                          ? 'Key saved (enter to replace)'
                          : 'Key',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await widget.state.setAiKey(_key.text);
                    _key.clear();
                    _hasKey = await widget.state.hasAiKey;
                    if (mounted) setState(() {});
                  },
                  child: const Text('Save key'),
                ),
                if (_hasKey)
                  TextButton(
                    onPressed: () async {
                      await widget.state.setAiKey(null);
                      _hasKey = false;
                      if (mounted) setState(() {});
                    },
                    child: const Text('Remove'),
                  ),
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('ai-activity'),
              onPressed: () => _showActivity(context),
              icon: const Icon(Icons.receipt_long_outlined, size: 16),
              label: Text('What was sent (${ai.activity.length})'),
            ),
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Most text sent at once: ${ai.maxContextChars} characters',
            style: const TextStyle(fontSize: 13),
          ),
          Slider(
            value: ai.maxContextChars.toDouble(),
            min: 500,
            max: 20000,
            divisions: 39,
            onChanged: (v) => _change(() => ai.setMaxContextChars(v.round())),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: ai.allowImages,
            onChanged: (v) => _change(() => ai.setAllowImages(v)),
            title: const Text(
              'Mindmap selections may be sent as pictures',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const Text(
            'Content the AI may be given:',
            style: TextStyle(fontSize: 13),
          ),
          for (final source in AiSource.values)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: ai.sources.contains(source),
              title: Text(source.label),
              onChanged: (on) => _change(() {
                final next = {...ai.sources};
                on == true ? next.add(source) : next.remove(source);
                return ai.setSources(next);
              }),
            ),
          Row(
            children: [
              OutlinedButton(
                key: const ValueKey('ai-test'),
                onPressed: _testing ? null : _testConnection,
                child: const Text('Test connection'),
              ),
              const SizedBox(width: Space.md),
              Expanded(child: Text(_test ?? '', style: small)),
            ],
          ),
        ],
      ],
    );
  }
}

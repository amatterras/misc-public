// Settings → AI: the master switch, which service, what may be sent and
// how much. Explains costs plainly; nothing here sends anything except
// "Test connection", which sends one short test sentence.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
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

  Future<void> _testConnection() async {
    setState(() => _test = 'Testing…');
    try {
      final client = await widget.state.aiClient();
      final reply = await client.complete(const [
        AiMessage('user', 'Reply with the single word OK.'),
      ]);
      _test = 'Connected. The model answered: “$reply”';
    } on AiFailure catch (e) {
      _test = e.message;
    } catch (_) {
      _test = 'The test failed.';
    }
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
              await ai.setEndpoint(p.defaultEndpoint);
              _endpoint.text = ai.endpoint;
              _model.text = ai.model;
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
            onChanged: (v) => ai.setModel(v),
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
          if (ai.provider == AiProvider.openAiCompatible)
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
                onPressed: _testConnection,
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

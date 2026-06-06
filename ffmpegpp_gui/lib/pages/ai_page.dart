import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

class AIPage extends StatefulWidget {
  const AIPage({super.key});
  @override
  State<AIPage> createState() => _AIPageState();
}

class _AIPageState extends State<AIPage> {
  final _modelCtrl = TextEditingController(), _endpointCtrl = TextEditingController();
  final _keyCtrl = TextEditingController(), _promptCtrl = TextEditingController();
  bool _testing = false, _fetchingModels = false;
  String? _testResult;
  List<String> _models = [];

  @override
  void initState() {
    super.initState();
    final c = context.read<AppState>().config;
    _modelCtrl.text = c.aiModel; _endpointCtrl.text = c.aiEndpoint;
    _keyCtrl.text = c.aiKey; _promptCtrl.text = c.aiPrompt;
  }
  @override
  void dispose() { _modelCtrl.dispose(); _endpointCtrl.dispose(); _keyCtrl.dispose(); _promptCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext ctx) {
    final s = AppStrings.of(ctx.watch<AppState>().config.language);
    final sc = Theme.of(ctx).colorScheme; final clr = sc.onSurface;
    final st = ctx.read<AppState>(); final cfg = st.config;

    return Scaffold(
      appBar: AppBar(title: Text(s.navAI)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: SwitchListTile(
          title: Text(s.aiMasterSwitch, style: TextStyle(color: clr, fontWeight: FontWeight.w600)),
          subtitle: Text(s.aiDescription, style: TextStyle(fontSize: 12, color: sc.outline)),
          value: cfg.aiEnabled, onChanged: (v) => st.updateConfig((c) => c..aiEnabled = v),
        )),
        if (cfg.aiEnabled) ...[
          const SizedBox(height: 12),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(s.aiModel, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sc.primary))),
              TextButton.icon(
                icon: _fetchingModels ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_download, size: 14),
                label: Text('Fetch', style: const TextStyle(fontSize: 10)),
                onPressed: _fetchingModels ? null : _fetchModels,
              ),
            ]),
            const SizedBox(height: 4),
            if (_models.isNotEmpty)
              DropdownButtonFormField<String>(
                value: _models.contains(_modelCtrl.text) ? _modelCtrl.text : _models.first,
                isDense: true, style: TextStyle(fontSize: 12, color: clr), dropdownColor: sc.surface,
                items: _models.map((m) => DropdownMenuItem(value: m, child: Text(m, style: TextStyle(fontSize: 12, color: clr)))).toList(),
                onChanged: (v) { if (v != null) { _modelCtrl.text = v; st.updateConfig((c) => c..aiModel = v); } },
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
              )
            else
              TextField(controller: _modelCtrl, style: TextStyle(fontSize: 13, color: clr),
                  decoration: const InputDecoration(hintText: 'deepseek-chat'), onChanged: (v) => st.updateConfig((c) => c..aiModel = v)),
            const SizedBox(height: 10),
            Text(s.aiEndpoint, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sc.primary)),
            TextField(controller: _endpointCtrl, style: TextStyle(fontSize: 13, color: clr),
                decoration: const InputDecoration(hintText: 'https://api.deepseek.com'), onChanged: (v) => st.updateConfig((c) => c..aiEndpoint = v)),
            const SizedBox(height: 10),
            Text(s.aiKey, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sc.primary)),
            TextField(controller: _keyCtrl, obscureText: true, style: TextStyle(fontSize: 13, color: clr),
                decoration: const InputDecoration(hintText: 'sk-...'), onChanged: (v) => st.updateConfig((c) => c..aiKey = v)),
            const SizedBox(height: 12),
            Row(children: [
              OutlinedButton.icon(
                icon: _testing ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.wifi_find, size: 16),
                label: Text(_testing ? s.aiTesting : s.aiTest), onPressed: _testing ? null : _testConnection,
              ),
              const SizedBox(width: 8),
              if (_testResult != null) Expanded(child: Text(_testResult!, style: TextStyle(fontSize: 12, color: _testResult!.startsWith('OK') ? Colors.green : sc.error))),
              const Spacer(),
              FilledButton.icon(icon: const Icon(Icons.auto_awesome, size: 16), label: Text(s.aiRequest), onPressed: _requestAI),
            ]),
          ]))),
          const SizedBox(height: 12),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.aiPrompt, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sc.primary)),
            const SizedBox(height: 4),
            TextField(controller: _promptCtrl, maxLines: 6, style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: clr),
                decoration: const InputDecoration(border: OutlineInputBorder()), onChanged: (v) => st.updateConfig((c) => c..aiPrompt = v)),
          ]))),
        ],
      ]),
    );
  }

  Future<void> _fetchModels() async {
    final c = context.read<AppState>().config;
    setState(() => _fetchingModels = true);
    try {
      final r = await http.get(Uri.parse('${c.aiEndpoint}/models'),
          headers: {'Accept': 'application/json', 'Authorization': 'Bearer ${c.aiKey}'}).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) setState(() => _models = (jsonDecode(r.body)['data'] as List?)?.map((m) => m['id'] as String).toList() ?? []);
    } catch (_) {}
    setState(() => _fetchingModels = false);
  }

  Future<void> _testConnection() async {
    final c = context.read<AppState>().config;
    setState(() { _testing = true; _testResult = null; });
    try {
      final r = await http.post(Uri.parse('${c.aiEndpoint}/v1/chat/completions'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${c.aiKey}'},
          body: jsonEncode({'model': c.aiModel, 'messages': [{'role': 'user', 'content': 'ping'}], 'max_tokens': 5}))
          .timeout(const Duration(seconds: 15));
      setState(() => _testResult = r.statusCode == 200 ? 'OK' : '${r.statusCode}');
    } catch (_) { setState(() => _testResult = 'Error'); }
    _testing = false;
  }

  Future<void> _requestAI() async {
    final c = context.read<AppState>().config;
    final st = context.read<AppState>();
    if (!mounted) return;
    final result = await showDialog<String>(context: context, barrierDismissible: false,
        builder: (ctx) => _AIDialog(endpoint: c.aiEndpoint, model: c.aiModel, apiKey: c.aiKey, prompt: _promptCtrl.text));
    if (result != null && result.isNotEmpty && mounted) {
      final cmd = _extractCmd(result);
      st.setAICommand(cmd);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(cmd.isNotEmpty ? 'Command: $cmd' : 'No ffmpeg command found')));
    }
  }

  String _extractCmd(String t) {
    for (final l in t.split('\n')) { final x = l.trim(); if (x.startsWith('ffmpeg ')) return x; }
    final m = RegExp(r'```(?:bash|sh|shell)?\s*\n?(ffmpeg[^\n]*)', multiLine: true).firstMatch(t);
    if (m != null) return m.group(1)!.trim();
    for (final l in t.split('\n')) { if (l.contains('ffmpeg ')) return l.substring(l.indexOf('ffmpeg ')).trim(); }
    return t.trim();
  }
}

class _AIDialog extends StatefulWidget {
  final String endpoint, model, apiKey, prompt;
  const _AIDialog({required this.endpoint, required this.model, required this.apiKey, required this.prompt});
  @override
  State<_AIDialog> createState() => _AIDialogState();
}

class _AIDialogState extends State<_AIDialog> {
  String _status = 'Sending...', _result = ''; bool _done = false;
  @override
  void initState() { super.initState(); _send(); }

  Future<void> _send() async {
    try {
      final r = await http.post(Uri.parse('${widget.endpoint}/v1/chat/completions'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${widget.apiKey}'},
          body: jsonEncode({'model': widget.model, 'messages': [{'role': 'user', 'content': widget.prompt}], 'temperature': 0.3}))
          .timeout(const Duration(seconds: 120));
      if (r.statusCode == 200) { final c = jsonDecode(r.body)['choices']?[0]?['message']?['content'] ?? ''; setState(() { _status = 'Done'; _result = c.trim(); _done = true; }); }
      else { setState(() { _status = 'Error ${r.statusCode}'; _result = r.body; _done = true; }); }
    } catch (e) { setState(() { _status = 'Error: $e'; _done = true; }); }
  }

  @override
  Widget build(BuildContext ctx) {
    final sc = Theme.of(ctx).colorScheme;
    return AlertDialog(
      title: const Text('AI Result'),
      content: SizedBox(width: 500, height: 350, child: Column(children: [
        if (!_done) const Padding(padding: EdgeInsets.all(40), child: Column(children: [CircularProgressIndicator(), SizedBox(height: 20), Text('Generating...')]))
        else ...[Text(_status, style: TextStyle(fontWeight: FontWeight.w600, color: sc.primary)), const SizedBox(height: 8),
          Expanded(child: Container(width: double.infinity, padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: sc.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
              child: SingleChildScrollView(child: SelectableText(_result, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))))),
        ],
      ])),
      actions: [
        if (_done && _result.isNotEmpty) FilledButton.icon(icon: const Icon(Icons.check, size: 16), label: const Text('Use'), onPressed: () => Navigator.pop(ctx, _result)),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    );
  }
}

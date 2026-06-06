import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});
  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _logs = <String>[];
  final _scroll = ScrollController();
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    // capture stdout (typed messages)
    _stdoutSub = state.pythonProcess.responses.listen((obj) {
      _add('STDOUT: $obj');
    });
    // capture stderr
    _stderrSub = state.pythonProcess.errors.listen((line) {
      _add('STDERR: $line');
    });
  }

  void _add(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    setState(() => _logs.add('[$ts] $msg'));
    if (_autoScroll && _scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            icon: Icon(_autoScroll ? Icons.vertical_align_bottom : Icons.pause, size: 18),
            tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Clear',
            onPressed: () => setState(() => _logs.clear()),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _logs.isEmpty
          ? Center(
              child: Text('Waiting for backend output...',
                  style: TextStyle(color: scheme.outline, fontSize: 13)))
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: _logs.length,
              itemBuilder: (_, i) => Text(
                _logs[i],
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  color: _logs[i].contains('STDERR') ? Colors.orange.shade300 : scheme.onSurface,
                ),
              ),
            ),
    );
  }
}

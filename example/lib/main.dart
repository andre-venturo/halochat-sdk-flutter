// Minimal smoke screen: paste a client token (`hct_…`, minted by your backend), then send and
// watch the live timeline. Not a UI kit: real apps draw their own chat screen.

import 'package:flutter/material.dart';
import 'package:halochat_flutter/halochat_flutter.dart';

void main() => runApp(const MaterialApp(home: ExampleChat()));

class ExampleChat extends StatefulWidget {
  const ExampleChat({super.key});

  @override
  State<ExampleChat> createState() => _ExampleChatState();
}

class _ExampleChatState extends State<ExampleChat> {
  final _token = TextEditingController();
  final _text = TextEditingController();
  Stream<List<HaloChatMessage>>? _timeline;
  String? _error;

  Future<void> _connect() async {
    final token = _token.text.trim();
    await HaloChat.setUser((_) async => token);
    setState(() {
      _timeline = HaloChat.timeline(onError: (e) => setState(() => _error = '$e'));
    });
  }

  Future<void> _send() async {
    try {
      await HaloChat.send(_text.text);
      _text.clear();
    } on HaloChatException catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('halochat_flutter')),
        body: Column(children: [
          if (_timeline == null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Expanded(child: TextField(controller: _token, decoration: const InputDecoration(hintText: 'hct_…'))),
                TextButton(onPressed: _connect, child: const Text('Connect')),
              ]),
            ),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          Expanded(
            child: StreamBuilder<List<HaloChatMessage>>(
              stream: _timeline,
              builder: (context, snap) => ListView(
                children: [
                  for (final m in snap.data ?? const <HaloChatMessage>[])
                    ListTile(
                      title: Text(m.text ?? (m.hasMedia ? '[${m.mediaFilename}]' : '')),
                      subtitle: Text('${m.senderKind.name} · ${m.status?.name ?? ''}'),
                      trailing: m.isMine ? const Icon(Icons.person) : null,
                    ),
                ],
              ),
            ),
          ),
          if (_timeline != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                Expanded(child: TextField(controller: _text)),
                IconButton(onPressed: _send, icon: const Icon(Icons.send)),
              ]),
            ),
        ]),
      );
}

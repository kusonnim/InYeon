import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/content.dart';
import '../native/notification_bridge.dart';
import '../native/share_bridge.dart';
import 'content_details.dart';

class RegisteredContentScreen extends StatefulWidget {
  const RegisteredContentScreen({
    super.key,
    required this.bridge,
    required this.target,
    this.openEditor = false,
  });

  final NotificationBridge bridge;
  final NoticeTarget target;
  final bool openEditor;

  @override
  State<RegisteredContentScreen> createState() =>
      _RegisteredContentScreenState();
}

class _RegisteredContentScreenState extends State<RegisteredContentScreen> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  late final StreamSubscription<void> _changes;
  late final AppLifecycleListener _lifecycle;
  late bool _editing = widget.openEditor;
  RegisteredContent? _item;
  NoticeStatus? _notice;
  bool _busy = false;
  bool _locked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _changes = widget.bridge.changes.listen(
      (_) => unawaited(_checkStatus()),
      onError: (Object _) {},
    );
    _lifecycle = AppLifecycleListener(onResume: _checkStatus);
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    _lifecycle.dispose();
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    if (_locked) return;
    try {
      final status = await widget.bridge.status(widget.target);
      if (mounted && !_locked) setState(() => _notice = status);
    } on PlatformException catch (error) {
      if (mounted && error.code == 'authentication_required') _lock();
    }
  }

  void _lock() {
    setState(() {
      _locked = true;
      _item = null;
      _notice = null;
      _title.clear();
      _note.clear();
    });
  }

  void _accept(RegisteredContent item, {required bool keepDraft}) {
    final content = item.content;
    if (content.id != widget.target.contentId ||
        content.userId != widget.target.ownerId) {
      _lock();
      return;
    }
    setState(() {
      _item = item;
      _notice = item.notice;
      if (!keepDraft) {
        _title.text = content.title ?? '';
        _note.text = content.userNote ?? '';
      }
    });
  }

  Future<void> _load({bool keepDraft = false}) => _run(() async {
        final item = await widget.bridge.details(widget.target);
        if (mounted && !_locked) _accept(item, keepDraft: keepDraft);
      });

  Future<void> _save(ContentItem content) => _run(() async {
        final item = await widget.bridge.edit(
          widget.target,
          ContentPatch(
            expectedVersion: content.version,
            title: _title.text.isEmpty ? null : _title.text,
            userNote: _note.text.isEmpty ? null : _note.text,
            clearTitle: _title.text.isEmpty,
            clearUserNote: _note.text.isEmpty,
          ),
        );
        if (!mounted || _locked) return;
        _accept(item, keepDraft: false);
        if (_locked) return;
        setState(() => _editing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(item.mode == UploadMode.mock
              ? 'Saved to mock server.'
              : 'Changes saved.'),
        ));
      });

  Future<void> _restore() => _run(() async {
        await widget.bridge.restore(widget.target);
        await _checkStatus();
      });

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy || _locked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on PlatformException catch (error) {
      if (!mounted || _locked) return;
      if (error.code == 'authentication_required') {
        _lock();
        return;
      }
      setState(() => _error = switch (error.code) {
            'version_conflict' =>
              'Content changed on the server. Refresh to load the latest version and keep your draft.',
            'notification_unavailable' =>
              'Restoration is unavailable for the current notification state.',
            _ => 'The server operation could not be confirmed.',
          });
      await _checkStatus();
    } on FormatException {
      if (mounted && !_locked)
        setState(() => _error = 'Content could not be read.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit content' : 'Content details'),
        actions: [
          if (!_locked)
            IconButton(
              tooltip: 'Refresh content',
              onPressed: _busy
                  ? null
                  : () => _load(keepDraft: _editing && item != null),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _locked
          ? const Center(
              child: Text('Sign in with the account that saved this content.'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (item?.mode == UploadMode.mock)
                  const Padding(
                      padding: EdgeInsets.all(16), child: Text('Mock content')),
                if (_busy) const LinearProgressIndicator(),
                if (_error case final error?)
                  Padding(
                      padding: const EdgeInsets.all(16), child: Text(error)),
                if (item != null)
                  Expanded(
                    child: _editing
                        ? _editor(item.content)
                        : ContentDetails(
                            content: item.content,
                            footer: _notificationControls(canEdit: true),
                          ),
                  )
                else if (!_editing && _notice != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child:
                        Column(children: _notificationControls(canEdit: false)),
                  ),
              ],
            ),
    );
  }

  List<Widget> _notificationControls({required bool canEdit}) {
    final notice = _notice;
    return [
      if (notice?.dismissed == true) const Text('Notification dismissed'),
      if (notice?.pending == 'dismiss')
        const Text('Dismissal saved on this device. Sync pending.'),
      if (notice?.pending == 'restore')
        const Text('Restoration awaiting server acknowledgment.'),
      if (notice?.error != null)
        const Text('The notification change could not be synchronized.'),
      if (notice?.canRestore == true)
        OutlinedButton(
            onPressed: _busy ? null : _restore,
            child: const Text('Restore notification')),
      if (canEdit)
        FilledButton(
          onPressed: _busy ? null : () => setState(() => _editing = true),
          child: const Text('Edit'),
        ),
    ];
  }

  Widget _editor(ContentItem content) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            enabled: !_busy,
            maxLength: 500,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: _note,
            enabled: !_busy,
            maxLength: 10000,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Your notes'),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _save(content),
            child: const Text('Save changes'),
          ),
        ],
      );
}

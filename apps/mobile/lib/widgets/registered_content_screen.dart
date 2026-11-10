import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../native/notification_bridge.dart';
import '../native/share_bridge.dart';
import 'content_details.dart';
import 'library_components.dart';

enum _Request { load, save, restore }

class RegisteredContentScreen extends StatefulWidget {
  const RegisteredContentScreen({
    super.key,
    required this.bridge,
    required this.target,
    this.openEditor = false,
    this.initialContent,
    this.initialMode = UploadMode.disabled,
    this.openOriginal,
    this.onChanged,
  });

  final NotificationBridge bridge;
  final NoticeTarget target;
  final bool openEditor;
  final ContentItem? initialContent;
  final UploadMode initialMode;
  final VoidCallback? openOriginal;
  final ValueChanged<ContentItem>? onChanged;

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
  int _statusRequest = 0;
  bool _busy = false;
  bool _locked = false;
  bool _verified = false;
  bool _conflict = false;
  bool _reviewDraft = false;
  String? _error;

  bool get _titleChanged => _title.text != (_item?.content.title ?? '');
  bool get _noteChanged => _note.text != (_item?.content.userNote ?? '');
  bool get _dirty => _titleChanged || _noteChanged;

  @override
  void initState() {
    super.initState();
    final preview = widget.initialContent;
    if (preview != null && _owns(preview)) {
      _item = RegisteredContent(
          preview, widget.initialMode, const NoticeStatus(known: false));
      _title.text = preview.title ?? '';
      _note.text = preview.userNote ?? '';
    }
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

  bool _owns(ContentItem content) =>
      content.id == widget.target.contentId &&
      content.userId == widget.target.ownerId;

  Future<void> _checkStatus() async {
    if (_locked || _error == 'http_404') return;
    final request = ++_statusRequest;
    try {
      final status = await widget.bridge.status(widget.target);
      if (mounted && !_locked && request == _statusRequest && status.known) {
        setState(() => _notice = status);
      }
    } on PlatformException catch (error) {
      if (mounted && !_locked && _isAuthError(error)) _lock();
    }
  }

  bool _isAuthError(PlatformException error) =>
      error.code == 'authentication_required' ||
      error.code == 'account_changed';

  void _lock() {
    setState(() {
      _locked = true;
      _editing = false;
      _item = null;
      _notice = null;
      _title.clear();
      _note.clear();
    });
  }

  void _accept(RegisteredContent item, {bool keepDraft = false}) {
    final content = item.content;
    if (!_owns(content)) {
      _lock();
      return;
    }
    final keepTitle = keepDraft && _titleChanged;
    final keepNote = keepDraft && _noteChanged;
    ++_statusRequest;
    setState(() {
      _item = item;
      _notice = item.notice;
      _verified = true;
      if (!keepTitle) _title.text = content.title ?? '';
      if (!keepNote) _note.text = content.userNote ?? '';
    });
    widget.onChanged?.call(content);
  }

  Future<void> _load() => _run(_Request.load, () async {
        final item = await widget.bridge.details(widget.target);
        if (!mounted || _locked) return;
        _accept(item, keepDraft: _editing && _item != null);
        if (_locked) return;
        setState(() {
          _reviewDraft = _conflict && _editing && _dirty;
          _conflict = false;
        });
        await _checkStatus();
      });

  Future<void> _save(ContentItem content) => _run(_Request.save, () async {
        final copy = AppLocalizations.of(context);
        FocusScope.of(context).unfocus();
        final title = _title.text;
        final note = _note.text;
        final item = await widget.bridge.edit(
          widget.target,
          ContentPatch(
            expectedVersion: content.version,
            title: _titleChanged && title.isNotEmpty ? title : null,
            userNote: _noteChanged && note.isNotEmpty ? note : null,
            clearTitle: _titleChanged && title.isEmpty,
            clearUserNote: _noteChanged && note.isEmpty,
          ),
        );
        if (!mounted || _locked) return;
        _accept(item);
        if (_locked) return;
        setState(() {
          _editing = false;
          _reviewDraft = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(switch (item.mode) {
            UploadMode.mock => copy.mockSaveConfirmed,
            UploadMode.staging => copy.stagingSaveConfirmed,
            _ => copy.saveConfirmed,
          }),
        ));
      });

  Future<void> _closeEditor() async {
    if (_busy) return;
    final copy = AppLocalizations.of(context);
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(copy.discardTitle),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(copy.keepEditing)),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(copy.discardDraft)),
          ],
        ),
      );
      if (discard != true || !mounted || _locked) return;
    }
    setState(() {
      _editing = false;
      _reviewDraft = false;
      _conflict = false;
      _title.text = _item?.content.title ?? '';
      _note.text = _item?.content.userNote ?? '';
    });
  }

  Future<void> _restore() => _run(_Request.restore, () async {
        await widget.bridge.restore(widget.target);
        await _checkStatus();
      });

  Future<void> _run(_Request request, Future<void> Function() operation) async {
    if (_busy || _locked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on PlatformException catch (error) {
      if (!mounted || _locked) return;
      if (_isAuthError(error)) {
        _lock();
        return;
      }
      setState(() {
        if (request != _Request.restore) _verified = false;
        if (request == _Request.save && error.code == 'version_conflict') {
          _conflict = true;
          _reviewDraft = false;
        } else {
          _error = error.code;
          if (request == _Request.load &&
              error.code == 'http_404' &&
              !_editing) {
            _item = null;
            _notice = null;
          }
        }
      });
      await _checkStatus();
    } on FormatException {
      if (mounted && !_locked) {
        setState(() {
          _verified = false;
          _error = 'invalid_server_response';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) unawaited(_closeEditor());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing ? copy.editTitle : copy.detailsTitle),
          actions: [
            if (!_locked && !_editing)
              IconButton(
                tooltip: copy.refreshContent,
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            if (!_locked && !_editing && _verified)
              IconButton(
                tooltip: copy.edit,
                onPressed: _busy ? null : () => setState(() => _editing = true),
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ),
        body: Column(
          children: [
            if (_busy)
              LinearProgressIndicator(semanticsLabel: copy.loadingContent),
            Expanded(child: _body(copy)),
          ],
        ),
      ),
    );
  }

  Widget _body(AppLocalizations copy) {
    if (_locked) {
      return PageList(children: [
        StatePanel(icon: Icons.lock_outline, title: copy.accountLocked),
      ]);
    }
    final item = _item;
    final banner = _problem(copy);
    if (item == null) {
      return PageList(children: [
        if (banner != null) banner,
        if (widget.openOriginal != null)
          TextButton(
              onPressed: widget.openOriginal, child: Text(copy.readOriginal)),
        if (!_editing) ..._notificationControls(copy),
      ]);
    }
    if (_editing) return _editor(copy, item, banner);
    return ContentDetails(
      content: item.content,
      badge: _environmentBadge(copy, item.mode),
      openOriginal: widget.openOriginal,
      header: [
        if (!_verified && banner == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: StatusPill(copy.savedCopies),
            ),
          ),
        if (banner != null)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: banner)
      ],
      footer: _notificationControls(copy),
    );
  }

  String? _environmentBadge(AppLocalizations copy, UploadMode mode) =>
      mode == UploadMode.mock
          ? copy.mockContent
          : uploadEnvironmentLabel(copy, mode);

  Widget? _problem(AppLocalizations copy) {
    if (_conflict) {
      return StatePanel(
        icon: Icons.history_rounded,
        title: copy.conflictTitle,
        message: _error == null ? copy.conflictBody : copy.latestUnavailable,
        action: _busy ? null : _load,
        actionLabel: copy.loadLatest,
      );
    }
    final error = _error;
    if (error != null || (_item != null && !_verified && !_busy)) {
      return StatePanel(
        icon: error == 'network_unavailable'
            ? Icons.cloud_off_outlined
            : Icons.info_outline_rounded,
        title: switch (error) {
          'network_unavailable' => copy.offlineTitle,
          'notification_unavailable' => copy.restoreUnavailable,
          _ =>
            _item == null ? copy.contentUnavailable : copy.operationUnconfirmed,
        },
        message: _item != null && !_verified ? copy.cachedContent : null,
        action: _busy ? null : _load,
        actionLabel: copy.retry,
      );
    }
    return null;
  }

  List<Widget> _notificationControls(AppLocalizations copy) {
    if (_error == 'http_404') return [];
    final notice = _notice;
    if (notice == null ||
        (!notice.dismissed && notice.pending == null && notice.error == null))
      return [];
    return [
      SectionCard(
        title: copy.notificationPermission,
        children: [
          if (notice.dismissed) Text(copy.dismissed),
          if (notice.pending == 'dismiss') Text(copy.dismissalQueued),
          if (notice.pending == 'restore') Text(copy.restoreQueued),
          if (notice.error != null) Text(copy.notificationChangeFailed),
          if (notice.canRestore)
            OutlinedButton(
                onPressed: _busy ? null : _restore, child: Text(copy.restore)),
        ],
      ),
    ];
  }

  Widget _editor(
          AppLocalizations copy, RegisteredContent item, Widget? banner) =>
      PageList(
        children: [
          if (_environmentBadge(copy, item.mode) case final label?)
            Align(
                alignment: AlignmentDirectional.centerStart,
                child: StatusPill(label)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(copy.editFieldsHelp,
                style: Theme.of(context).textTheme.bodyLarge),
          ),
          if (banner != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: banner),
          if (_reviewDraft && _dirty)
            SectionCard(
              title: copy.latestSavedValues,
              children: [
                Text(copy.reviewDraft),
                if (_titleChanged) ...[
                  const SizedBox(height: 8),
                  Text(copy.titleField,
                      style: Theme.of(context).textTheme.labelLarge),
                  Text(item.content.title ?? copy.noTitle),
                ],
                if (_noteChanged) ...[
                  const SizedBox(height: 8),
                  Text(copy.notes,
                      style: Theme.of(context).textTheme.labelLarge),
                  Text(item.content.userNote ?? copy.noNotes),
                ],
              ],
            ),
          TextField(
            controller: _title,
            enabled: !_busy,
            maxLength: 500,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: copy.titleField),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            enabled: !_busy,
            maxLength: 10000,
            minLines: 4,
            maxLines: 8,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: copy.notes, alignLabelWithHint: true),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                FilledButton(
                  onPressed: !_busy && _verified && !_conflict && _dirty
                      ? () => _save(item.content)
                      : null,
                  child: Text(copy.saveChanges),
                ),
                TextButton(
                    onPressed: _busy ? null : _closeEditor,
                    child: Text(copy.cancel)),
              ],
            ),
          ),
          RecommendationSection(
              title: copy.reviewSuggestions,
              items: item.content.recommendations),
        ],
      );
}

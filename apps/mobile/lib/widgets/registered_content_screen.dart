import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../library/workflow_edit.dart';
import '../models/content.dart';
import '../native/notification_bridge.dart';
import '../native/saved_document.dart';
import '../native/share_bridge.dart';
import 'content_details.dart';
import 'itda_theme.dart';
import 'library_components.dart';
import 'original_image.dart';

enum _Request { load, save, restore, workflow }

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
  final _titleFocus = FocusNode();
  final _noteFocus = FocusNode();
  late final StreamSubscription<void> _changes;
  late final AppLifecycleListener _lifecycle;
  late bool _editing = widget.openEditor;
  RegisteredContent? _item;
  LocalSource? _original;
  NoticeStatus? _notice;
  int _statusRequest = 0;
  int _originalRequest = 0;
  bool _busy = false;
  bool _locked = false;
  bool _verified = false;
  bool _conflict = false;
  bool _reviewDraft = false;
  bool _readingOriginal = true;
  bool _viewingImage = false;
  String? _error;

  bool get _titleChanged => _title.text != (_item?.content.title ?? '');
  bool get _noteChanged => _note.text != (_item?.content.userNote ?? '');
  bool get _dirty => _titleChanged || _noteChanged;
  bool get _canEdit => !_locked && _verified && !_busy;

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
    _titleFocus.dispose();
    _noteFocus.dispose();
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
      _original = null;
      _viewingImage = false;
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
        unawaited(_loadOriginal());
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

  Future<void> _loadOriginal() async {
    final request = ++_originalRequest;
    if (!_readingOriginal) setState(() => _readingOriginal = true);
    try {
      final original = await widget.bridge.original(widget.target);
      if (mounted && !_locked && request == _originalRequest) {
        setState(() {
          _original = original;
          if (original?.imagePath == null) _viewingImage = false;
        });
      }
    } on PlatformException catch (error) {
      if (!mounted || _locked || request != _originalRequest) return;
      if (_isAuthError(error)) {
        _lock();
      } else {
        setState(() {
          _original = null;
          _viewingImage = false;
        });
      }
    } finally {
      if (mounted && !_locked && request == _originalRequest) {
        setState(() => _readingOriginal = false);
      }
    }
  }

  void _expandImage() => setState(() => _viewingImage = true);

  void _closeImage() => setState(() => _viewingImage = false);

  VoidCallback? get _openDocument => _original?.inputType == InputType.document
      ? () => openSavedDocument(context, widget.target.toMessage())
      : null;

  void _beginEdit([FocusNode? focus]) {
    if (!_canEdit || _editing || _viewingImage) return;
    setState(() => _editing = true);
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _editing && _canEdit) focus.requestFocus();
      });
    }
  }

  Future<void> _save(ContentItem content) => _run(_Request.save, () async {
        if (!_dirty) return;
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

  Future<void> _move(ContentItem content, WorkflowStatus destination) async {
    if (!_canEdit) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).workflowUnavailable),
        ),
      );
      return;
    }
    await _run(_Request.workflow, () async {
      final updated = await changeWorkflow(
        widget.bridge,
        widget.target,
        content,
        destination,
      );
      if (mounted && !_locked) _accept(updated);
    });
  }

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
    final image = _original?.imagePath;
    final viewingImage = _viewingImage && image != null;
    final content = _item?.content;
    return PopScope(
      canPop: !_editing && !viewingImage,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (viewingImage) {
          _closeImage();
        } else if (_editing) {
          unawaited(_closeEditor());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: viewingImage ? BackButton(onPressed: _closeImage) : null,
          title: Text(
            viewingImage
                ? copy.imageViewer
                : (_editing ? copy.editTitle : copy.detailsTitle),
            style: _editing || viewingImage
                ? null
                : Theme.of(context).textTheme.labelLarge,
          ),
          actions: [
            if (!_locked && !_editing && !viewingImage)
              IconButton(
                tooltip: copy.refreshContent,
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            if (!_locked && !_editing && _verified && !viewingImage)
              IconButton(
                tooltip: copy.edit,
                onPressed: _canEdit ? _beginEdit : null,
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ),
        body: OriginalImageOverlay(
          path: viewingImage ? image : null,
          child: Column(
            children: [
              if (_busy)
                LinearProgressIndicator(semanticsLabel: copy.loadingContent),
              Expanded(child: _body(copy)),
            ],
          ),
        ),
        bottomNavigationBar: !_editing && !viewingImage && content != null
            ? _workflowAction(copy, content)
            : null,
      ),
    );
  }

  Widget _body(AppLocalizations copy) {
    if (_locked) {
      return PageList(
        children: [
          StatePanel(icon: Icons.lock_outline, title: copy.accountLocked),
        ],
      );
    }
    final item = _item;
    final banner = _problem(copy);
    if (item == null) {
      return PageList(
        children: [
          if (banner != null) banner,
          if (_original != null)
            OriginalSource(
              original: _original,
              openSavedCopy: _openDocument == null ? widget.openOriginal : null,
              openImage: _expandImage,
              openDocument: _openDocument,
            )
          else if (widget.openOriginal != null)
            TextButton(
              onPressed: widget.openOriginal,
              child: Text(copy.readOriginal),
            ),
          if (!_editing) ..._notificationControls(copy),
        ],
      );
    }
    if (_editing) return _editor(copy, item, banner);
    return ContentDetails(
      content: item.content,
      contextLabel: _environmentBadge(copy, item.mode),
      original: _original,
      loadingOriginal: _readingOriginal,
      openImage: _expandImage,
      openDocument: _openDocument,
      onEditTitle: _canEdit ? () => _beginEdit(_titleFocus) : null,
      onEditNotes: _canEdit ? () => _beginEdit(_noteFocus) : null,
      header: [
        if (!_verified && banner == null)
          Padding(
            padding: const EdgeInsets.only(bottom: ItdaSpace.medium),
            child: Text(
              copy.savedCopies,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (banner != null)
          Padding(
            padding: const EdgeInsets.only(bottom: ItdaSpace.medium),
            child: banner,
          ),
      ],
      footer: _notificationControls(copy),
    );
  }

  String? _environmentBadge(AppLocalizations copy, UploadMode mode) =>
      mode == UploadMode.mock
          ? copy.mockContent
          : uploadEnvironmentLabel(copy, mode);

  Widget _workflowAction(AppLocalizations copy, ContentItem content) {
    final destination = nextWorkflow(content.workflowStatus);
    final restoring = destination == WorkflowStatus.pending;
    return PageWidth(
      shrinkWrap: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ItdaSpace.page,
          ItdaSpace.small,
          ItdaSpace.page,
          ItdaSpace.medium,
        ),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _canEdit ? () => _move(content, destination) : null,
            icon: Icon(
              restoring ? Icons.unarchive_outlined : Icons.archive_outlined,
              size: 19,
            ),
            label: Text(restoring ? copy.returnToTray : copy.archiveAction),
          ),
        ),
      ),
    );
  }

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
          'version_conflict' => copy.workflowConflict,
          'notification_unavailable' => copy.restoreUnavailable,
          _ =>
            _item == null ? copy.contentUnavailable : copy.operationUnconfirmed,
        },
        message: _item != null && !_verified ? copy.cachedContent : null,
        action: _busy ? null : _load,
        actionLabel: error == 'version_conflict' ? copy.loadLatest : copy.retry,
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
      ContentSection(
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
    AppLocalizations copy,
    RegisteredContent item,
    Widget? banner,
  ) => PageList(
    children: [
      if (_environmentBadge(copy, item.mode) case final label?)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      const SizedBox(height: ItdaSpace.medium),
      if (banner != null)
        Padding(padding: const EdgeInsets.only(bottom: 12), child: banner),
      if (_reviewDraft && _dirty)
        ContentSection(
          title: copy.latestSavedValues,
          children: [
            Text(copy.reviewDraft),
            if (_titleChanged) ...[
              const SizedBox(height: 8),
              Text(
                copy.titleField,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(item.content.title ?? copy.noTitle),
            ],
            if (_noteChanged) ...[
              const SizedBox(height: 8),
              Text(copy.notes, style: Theme.of(context).textTheme.labelLarge),
              Text(item.content.userNote ?? copy.noNotes),
            ],
          ],
        ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            focusNode: _titleFocus,
            enabled: !_busy,
            maxLength: 500,
            buildCounter: _fieldCounter,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: copy.titleField,
              floatingLabelBehavior: FloatingLabelBehavior.always,
              hintText: suggestedTitle(copy, item.content, original: _original),
              hintMaxLines: 2,
            ),
          ),
          const SizedBox(height: ItdaSpace.large),
          TextField(
            controller: _note,
            focusNode: _noteFocus,
            enabled: !_busy,
            maxLength: 10000,
            buildCounter: _fieldCounter,
            minLines: 4,
            maxLines: 8,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: copy.notes,
              alignLabelWithHint: true,
            ),
          ),
        ],
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
              child: Text(copy.cancel),
            ),
          ],
        ),
      ),
      OriginalSource.fromContent(
        item.content,
        original: _original,
        loadingOriginal: _readingOriginal,
        openImage: _expandImage,
        openDocument: _openDocument,
      ),
      RecommendationSection(
        title: copy.reviewSuggestions,
        items: item.content.recommendations,
      ),
    ],
  );

  Widget? _fieldCounter(
    BuildContext context, {
    required int currentLength,
    required bool isFocused,
    required int? maxLength,
  }) => maxLength != null && currentLength >= maxLength - 20
      ? Text('$currentLength / $maxLength')
      : null;
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../native/share_bridge.dart';
import '../widgets/content_details.dart';
import '../widgets/library_components.dart';
import 'library_controller.dart';

class LocalContentScreen extends StatefulWidget {
  const LocalContentScreen(
      {super.key, required this.controller, required this.localId});

  final LibraryController controller;
  final String localId;

  @override
  State<LocalContentScreen> createState() => _LocalContentScreenState();
}

class _LocalContentScreenState extends State<LocalContentScreen> {
  late Future<LocalSource> _source = _read();
  bool _assigning = false;

  Future<LocalSource> _read() =>
      widget.controller.shares!.readLocalSource(widget.localId);

  Future<void> _assign(UploadAccount account) async {
    final copy = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(copy.assignTitle),
        content: Text(copy.assignBody(account.email)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(copy.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(copy.assignConfirm)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _assigning = true);
    try {
      await widget.controller.shares!.assignShare(widget.localId, account.id);
      await widget.controller.reload();
    } on PlatformException {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(copy.assignProblem)));
    } finally {
      if (mounted) setState(() => _assigning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(copy.detailsTitle)),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final inbox = widget.controller.inbox;
          final share = inbox?.shares
              .where((entry) => entry.localId == widget.localId)
              .firstOrNull;
          if (share == null || share.inputType == null) {
            return PageList(children: [
              StatePanel(
                  icon: Icons.lock_outline,
                  title: copy.privateShare,
                  message: copy.privateShareHelp),
            ]);
          }
          final account = inbox!.account;
          final mode = inbox.mode;
          final failed = share.uploadState == LocalUploadState.permanentFailure;
          return PageList(
            children: [
              ContentHeading(
                title: localTitle(copy, share),
                inputType: share.inputType,
                savedAt: share.receivedAt,
                badges: [
                  StatusPill(uploadName(copy, mode, share), error: failed),
                  if (mode == UploadMode.mock) StatusPill(copy.mockBadge),
                ],
              ),
              FutureBuilder<LocalSource>(
                future: _source,
                builder: (context, snapshot) {
                  final source = snapshot.data;
                  if (source != null) {
                    return OriginalSource(
                        text: source.text,
                        url: source.url,
                        filename: source.filename);
                  }
                  if (!snapshot.hasError) {
                    return LinearProgressIndicator(
                        semanticsLabel: copy.loadingContent);
                  }
                  return StatePanel(
                    icon: Icons.info_outline_rounded,
                    title: copy.sourceUnavailable,
                    action: () => setState(() => _source = _read()),
                    actionLabel: copy.retry,
                  );
                },
              ),
              if (mode != UploadMode.disabled &&
                  share.uploadState != LocalUploadState.synchronized)
                SectionCard(
                  title: copy.uploadActivity,
                  children: [
                    Text(failed ? copy.uploadFailureInfo : copy.pendingDetail),
                    if (!failed &&
                        share.uploadState !=
                            LocalUploadState.authenticationRequired) ...[
                      const SizedBox(height: 5),
                      Text(copy.uploadRetryInfo),
                    ],
                    if (share.canAssign && account != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _assigning ? null : () => _assign(account),
                        child: Text(copy.assignAction),
                      ),
                    ],
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

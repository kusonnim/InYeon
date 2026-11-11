import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../native/saved_document.dart';
import '../native/share_bridge.dart';
import '../widgets/content_details.dart';
import '../widgets/detail_card.dart';
import '../widgets/itda_theme.dart';
import '../widgets/library_components.dart';
import '../widgets/original_image.dart';
import 'library_controller.dart';

class LocalContentScreen extends StatefulWidget {
  const LocalContentScreen({
    super.key,
    required this.controller,
    required this.localId,
  });

  final LibraryController controller;
  final String localId;

  @override
  State<LocalContentScreen> createState() => _LocalContentScreenState();
}

class _LocalContentScreenState extends State<LocalContentScreen> {
  late Future<LocalSource> _source = _read();
  bool _assigning = false;
  bool _viewingImage = false;

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
            child: Text(copy.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(copy.assignConfirm),
          ),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(copy.assignProblem)));
    } finally {
      if (mounted) setState(() => _assigning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final inbox = widget.controller.inbox;
        final share = inbox?.shares
            .where((entry) => entry.localId == widget.localId)
            .firstOrNull;
        if (share == null || share.inputType == null) {
          return Scaffold(
            appBar: AppBar(title: Text(copy.detailsTitle)),
            body: PageList(
              children: [
                StatePanel(
                  icon: Icons.lock_outline,
                  title: copy.privateShare,
                  message: copy.privateShareHelp,
                ),
              ],
            ),
          );
        }
        return FutureBuilder<LocalSource>(
          future: _source,
          builder: (context, snapshot) {
            final image = snapshot.data?.imagePath;
            final viewingImage = _viewingImage && image != null;
            void closeImage() => setState(() => _viewingImage = false);
            return PopScope(
              canPop: !viewingImage,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && viewingImage) closeImage();
              },
              child: Scaffold(
                appBar: AppBar(
                  title: Text(
                    viewingImage ? copy.imageViewer : copy.detailsTitle,
                    style: viewingImage
                        ? null
                        : Theme.of(context).textTheme.labelLarge,
                  ),
                  leading: viewingImage
                      ? BackButton(onPressed: closeImage)
                      : null,
                ),
                body: OriginalImageOverlay(
                  path: viewingImage ? image : null,
                  child: _details(copy, inbox!, share, snapshot),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _details(
    AppLocalizations copy,
    LocalInbox inbox,
    LocalShare share,
    AsyncSnapshot<LocalSource> snapshot,
  ) {
    final account = inbox.account;
    final mode = inbox.mode;
    final failed = share.uploadState == LocalUploadState.permanentFailure;
    final original = snapshot.data;
    final image = share.inputType == InputType.image;
    final title = localTitle(copy, share);
    final url = original?.url ?? share.sourceUrl;
    final text = readableSourceText(original?.text, url);
    final theme = Theme.of(context);
    return PageList(
      children: [
        DetailCard(
          children: (expanded) => [
            ContentHeading(title: title),
            if (snapshot.hasError)
              StatePanel(
                icon: Icons.info_outline_rounded,
                title: copy.sourceUnavailable,
                action: () => setState(() => _source = _read()),
                actionLabel: copy.retry,
              )
            else if (image)
              OriginalImagePreview(
                original: original,
                loading: !snapshot.hasData,
                onExpand: () => setState(() => _viewingImage = true),
              )
            else if (!snapshot.hasData)
              LinearProgressIndicator(semanticsLabel: copy.loadingContent)
            else if (text != null && text.trim() != title.trim())
              Padding(
                padding: const EdgeInsets.only(bottom: ItdaSpace.large),
                child: DetailText(text: text, expanded: expanded),
              ),
            if (mode != UploadMode.disabled &&
                share.uploadState != LocalUploadState.synchronized)
              ContentSection(
                title: uploadName(copy, mode, share),
                children: [
                  if (failed)
                    Text(
                      copy.uploadFailureInfo,
                      style: theme.textTheme.bodySmall,
                    )
                  else if (share.uploadState == LocalUploadState.retryWaiting)
                    Text(
                      copy.uploadRetryInfo,
                      style: theme.textTheme.bodySmall,
                    ),
                  if (share.canAssign && account != null)
                    OutlinedButton(
                      onPressed: _assigning ? null : () => _assign(account),
                      child: Text(copy.assignAction),
                    ),
                ],
              ),
            if (share.serverContentId == null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(copy.workflowNeedsSync)),
                  ),
                  child: Text(copy.archiveAction),
                ),
              ),
            if (expanded) ...[
              const Divider(height: ItdaSpace.bottom),
              DetailMetadata(
                type: share.inputType,
                savedAt: share.receivedAt,
                sourceUrl: url,
                contextLabel: uploadEnvironmentLabel(copy, mode),
              ),
              if (original != null)
                OriginalSource(
                  inputType: share.inputType,
                  original: original,
                  displayedTitle: title,
                  showImage: false,
                  showText: image,
                  openDocument: share.inputType == InputType.document
                      ? () => openSavedDocument(context, {
                          'local_id': share.localId,
                        })
                      : null,
                ),
            ],
          ],
        ),
      ],
    );
  }
}

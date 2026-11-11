import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../library/library_controller.dart';
import '../models/content.dart';
import '../native/share_bridge.dart';
import 'itda_theme.dart';

class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: child,
      ),
    ),
  );
}
class PageList extends StatelessWidget {
  const PageList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => PageWidth(
    child: ListView(
      padding: const EdgeInsets.fromLTRB(
        ItdaSpace.page,
        ItdaSpace.medium,
        ItdaSpace.page,
        ItdaSpace.bottom,
      ),
      children: children,
    ),
  );
}
class ContentSection extends StatelessWidget {
  const ContentSection({
    super.key,
    required this.title,
    required this.children,
    this.action,
  });

  final String title;
  final List<Widget> children;
  final ({VoidCallback onTap, String label})? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tap = action;
    final heading = Semantics(
      container: true,
      header: true,
      child: Text(title, style: theme.textTheme.titleMedium),
    );
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: ItdaSpace.tiny),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tap == null)
            heading
          else
            Row(
              children: [
                Expanded(child: heading),
                Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          const SizedBox(height: ItdaSpace.small),
          ...children,
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: ItdaSpace.large),
      child: tap == null
          ? content
          : Semantics(
              container: true,
              button: true,
              label: tap.label,
              child: Tooltip(
                message: tap.label,
                excludeFromSemantics: true,
                child: InkWell(
                  onTap: tap.onTap,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: ItdaSpace.touchTarget,
                    ),
                    child: content,
                  ),
                ),
              ),
            ),
    );
  }
}
class StatePanel extends StatelessWidget {
  const StatePanel({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.actionLabel,
  });

  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: theme.colorScheme.onSurfaceVariant, size: 19),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: 4),
            Text(message!, style: theme.textTheme.bodyMedium),
          ],
          if (action != null && actionLabel != null)
            TextButton(onPressed: action, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
IconData sourceIcon(InputType? type) => switch (type) {
      InputType.text => Icons.notes_rounded,
      InputType.url => Icons.link_rounded,
      InputType.image => Icons.image_outlined,
      InputType.document => Icons.description_outlined,
      null => Icons.lock_outline_rounded,
    };

String sourceName(AppLocalizations copy, InputType? type) => switch (type) {
      InputType.text => copy.textType,
      InputType.url => copy.linkType,
      InputType.image => copy.imageType,
      InputType.document => copy.pdfType,
      null => copy.genericType,
    };

String analysisName(AppLocalizations copy, AnalysisStatus status) =>
    switch (status) {
      AnalysisStatus.pending => copy.analysisPending,
      AnalysisStatus.processing => copy.analysisProcessing,
      AnalysisStatus.completed => copy.analysisCompleted,
      AnalysisStatus.partial => copy.analysisPartial,
      AnalysisStatus.failed => copy.analysisFailed,
    };

String recommendationName(AppLocalizations copy, RecommendationKind kind) =>
    switch (kind) {
      RecommendationKind.action => copy.actionKind,
      RecommendationKind.information => copy.informationKind,
      RecommendationKind.resource => copy.resourceKind,
    };

String? uploadEnvironmentLabel(AppLocalizations copy, UploadMode mode) =>
    switch (mode) {
      UploadMode.mock => copy.mockBadge,
      UploadMode.staging => copy.stagingBadge,
      _ => null,
    };

String uploadName(AppLocalizations copy, UploadMode mode, LocalShare share) {
  if (mode == UploadMode.disabled) return copy.localSaved;
  return switch (share.uploadState) {
    LocalUploadState.pending => copy.pendingUpload,
    LocalUploadState.uploading => copy.uploading,
    LocalUploadState.retryWaiting => copy.retryUpload,
    LocalUploadState.authenticationRequired =>
      share.canAssign ? copy.unassignedUpload : copy.authUpload,
    LocalUploadState.synchronized => copy.synced,
    LocalUploadState.permanentFailure =>
      share.lastError == 'backend_not_implemented'
          ? copy.uploadUnavailable
          : copy.failedUpload,
  };
}

String entryTitle(AppLocalizations copy, LibraryEntry entry) {
  final content = entry.remote;
  return content == null
      ? localTitle(copy, entry.local!)
      : contentTitle(copy, content, local: entry.local);
}

String sourceCue(AppLocalizations copy, InputType? type, String? url) =>
    _webUri(url)?.host ?? sourceName(copy, type);

String contentTitle(
  AppLocalizations copy,
  ContentItem item, {
  LocalShare? local,
  LocalSource? original,
}) =>
    _nonBlank(item.title) ??
    suggestedTitle(copy, item, local: local, original: original);

String suggestedTitle(
  AppLocalizations copy,
  ContentItem item, {
  LocalShare? local,
  LocalSource? original,
}) => _sourceTitle(
  copy,
  item.inputType,
  subject: original?.subject ?? local?.subject,
  url: original?.url ?? local?.sourceUrl ?? item.sourceUrl,
  text: original?.text ?? local?.linkText ?? item.sourceText,
  filename: original?.filename ?? local?.label,
);

String localTitle(AppLocalizations copy, LocalShare share) {
  final type = share.inputType;
  if (type == null) return copy.privateShare;
  return _sourceTitle(
    copy,
    type,
    subject: share.subject,
    url: share.sourceUrl ?? (type == InputType.url ? share.label : null),
    text: type == InputType.url ? share.linkText : share.label,
    filename: share.label,
  );
}

String _sourceTitle(AppLocalizations copy, InputType type,
    {String? subject, String? url, String? text, String? filename}) {
  final sharedTitle = _nonBlank(subject);
  if (type == InputType.url) {
    if (sharedTitle != null && _webUri(sharedTitle) == null) {
      return sharedTitle;
    }
    final uri = _webUri(url);
    if (uri == null) return copy.linkType;
    final lines = text
        ?.split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(3)
        .toList();
    if (lines != null && lines.length == 2 && lines.contains(url)) {
      final title = lines.firstWhere((line) => line != url, orElse: () => '');
      if (title.isNotEmpty &&
          title.length <= 200 &&
          !title.contains(RegExp(r'https?://', caseSensitive: false))) {
        return title;
      }
    }
    return copy.linkFromHost(uri.host);
  }
  final fileTitle = _nonBlank(filename);
  if (type == InputType.document && fileTitle != null) return fileTitle;
  if (sharedTitle != null) return sharedTitle;
  if (type != InputType.text) {
    return fileTitle ?? sourceName(copy, type);
  }
  final firstLine = _nonBlank(text)?.split('\n').first.trim();
  return firstLine == null ? copy.noTitle : compactText(firstLine, 140);
}

Uri? _webUri(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  return uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty
      ? uri
      : null;
}

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String compactText(String value, int maxLength) {
  final prefix = value.runes.take(maxLength + 1).toList();
  return prefix.length > maxLength
      ? '${String.fromCharCodes(prefix.take(maxLength - 1))}…'
      : value;
}

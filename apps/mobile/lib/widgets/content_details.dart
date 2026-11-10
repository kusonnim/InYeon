import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../native/share_bridge.dart';
import 'library_components.dart';
import 'original_image.dart';

class ContentHeading extends StatelessWidget {
  const ContentHeading({
    super.key,
    required this.title,
    required this.inputType,
    required this.savedAt,
    this.badges = const [],
  });

  final String title;
  final InputType? inputType;
  final DateTime savedAt;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(sourceIcon(inputType),
                  color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  sourceName(copy, inputType),
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
              header: true,
              child: Text(title, style: theme.textTheme.headlineMedium)),
          const SizedBox(height: 6),
          Text(
            MaterialLocalizations.of(context)
                .formatMediumDate(savedAt.toLocal()),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 7, runSpacing: 6, children: badges),
          ],
        ],
      ),
    );
  }
}

class ContentDetails extends StatelessWidget {
  const ContentDetails({
    super.key,
    required this.content,
    this.title,
    this.badge,
    this.header = const [],
    this.footer = const [],
    this.openOriginal,
    this.original,
    this.loadingOriginal = false,
    this.openImage,
  });

  final ContentItem content;
  final String? title;
  final String? badge;
  final List<Widget> header;
  final List<Widget> footer;
  final VoidCallback? openOriginal;
  final LocalSource? original;
  final bool loadingOriginal;
  final VoidCallback? openImage;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final information = content.recommendations
        .where((item) => item.kind == RecommendationKind.information);
    final suggestions = content.recommendations
        .where((item) => item.kind != RecommendationKind.information);
    final workflow = switch (content.workflowStatus) {
      WorkflowStatus.pending => null,
      WorkflowStatus.completed => copy.completedItem,
      WorkflowStatus.archived => copy.archivedItem,
    };
    return PageList(
      children: [
        ContentHeading(
          title: title ?? contentTitle(copy, content, original: original),
          inputType: content.inputType,
          savedAt: content.createdAt,
          badges: [
            if (badge != null) StatusPill(badge!),
            if (workflow != null) StatusPill(workflow),
          ],
        ),
        ...header,
        OriginalSource.fromContent(
          content,
          original: original,
          loadingOriginal: loadingOriginal,
          openOriginal: openOriginal,
          openImage: openImage,
        ),
        _AnalysisSection(content: content),
        if (information.isNotEmpty)
          RecommendationSection(
              title: copy.importantInformation, items: information),
        if (suggestions.isNotEmpty || content.recommendations.isEmpty)
          RecommendationSection(
              title: copy.recommendations, items: suggestions),
        SectionCard(
            title: copy.notes,
            children: [Text(content.userNote ?? copy.noNotes)]),
        ...footer,
      ],
    );
  }
}

class OriginalSource extends StatelessWidget {
  const OriginalSource({
    super.key,
    this.text,
    this.url,
    this.inputType,
    this.original,
    this.loadingOriginal = false,
    this.hasAttachment = false,
    this.openOriginal,
    this.openImage,
  });

  OriginalSource.fromContent(
    ContentItem content, {
    LocalSource? original,
    bool loadingOriginal = false,
    VoidCallback? openOriginal,
    VoidCallback? openImage,
  }) : this(
          text: content.sourceText,
          url: content.sourceUrl,
          inputType: content.inputType,
          original: original,
          loadingOriginal: loadingOriginal,
          hasAttachment: content.assetIds.isNotEmpty,
          openOriginal: openOriginal,
          openImage: openImage,
        );

  final String? text;
  final String? url;
  final InputType? inputType;
  final LocalSource? original;
  final bool loadingOriginal;
  final bool hasAttachment;
  final VoidCallback? openOriginal;
  final VoidCallback? openImage;

  Future<void> _copy(BuildContext context, String value) async {
    final copy = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(copy.copiedSource)));
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final url = original?.url ?? this.url;
    final text = original?.text ?? this.text;
    final filename = original?.filename;
    final trimmed = text?.trim();
    final sourceText =
        trimmed != null && trimmed.isNotEmpty && trimmed != url ? text : null;
    final copyable = url ?? sourceText;
    final isImage = (inputType ?? original?.inputType) == InputType.image;
    final imagePath = original?.imagePath;
    final viewOriginal = isImage ? null : openOriginal;
    return SectionCard(
      title: copy.originalSource,
      children: [
        if (url != null)
          SelectableText(url,
              style: TextStyle(color: Theme.of(context).colorScheme.primary)),
        if (sourceText != null) ...[
          if (url != null) const SizedBox(height: 8),
          SelectableText(sourceText),
        ],
        if (hasAttachment || filename != null) ...[
          if (url != null || sourceText != null) const SizedBox(height: 8),
          Text(filename ?? copy.originalAttachment),
        ],
        if (isImage) ...[
          const SizedBox(height: 8),
          if (imagePath != null && openImage != null)
            OriginalImage(path: imagePath, onExpand: openImage)
          else if (loadingOriginal)
            LinearProgressIndicator(semanticsLabel: copy.loadingImage)
          else
            Text(original != null || openOriginal != null
                ? copy.imageUnavailable
                : copy.remoteImageUnavailable),
        ],
        if (!isImage && copyable == null && !hasAttachment && filename == null)
          Text(copy.sourceUnavailable),
        if (copyable != null || viewOriginal != null)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (copyable != null)
                TextButton.icon(
                  onPressed: () => _copy(context, copyable),
                  icon: const Icon(Icons.copy_outlined, size: 17),
                  label: Text(copy.copySource),
                ),
              if (viewOriginal != null)
                TextButton(
                    onPressed: viewOriginal, child: Text(copy.readOriginal)),
            ],
          ),
      ],
    );
  }
}

class _AnalysisSection extends StatelessWidget {
  const _AnalysisSection({required this.content});

  final ContentItem content;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final analysis = content.analysis;
    final coverage = switch (analysis?.coverage) {
      AnalysisCoverage.fullText => copy.coverageFull,
      AnalysisCoverage.partialText => copy.coveragePartial,
      AnalysisCoverage.metadataOnly => copy.coverageMetadata,
      AnalysisCoverage.unsupported => copy.coverageUnsupported,
      null => null,
    };
    final waiting = content.analysisStatus == AnalysisStatus.pending ||
        content.analysisStatus == AnalysisStatus.processing;
    final summary = analysis?.summary?.trim();
    return SectionCard(
      title: copy.aiSummary,
      children: [
        Wrap(
          spacing: 7,
          runSpacing: 6,
          children: [
            StatusPill(analysisName(copy, content.analysisStatus),
                highlight: !waiting),
            if (analysis != null) StatusPill(copy.generated),
          ],
        ),
        const SizedBox(height: 10),
        Text(summary == null || summary.isEmpty
            ? (waiting ? copy.noSummaryPending : copy.noSummary)
            : summary),
        if (coverage != null) ...[
          const SizedBox(height: 10),
          Text(coverage, style: theme.textTheme.labelLarge),
        ],
        for (final limitation in analysis?.limitations ?? const <String>[])
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(limitation,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          ),
      ],
    );
  }
}

class RecommendationSection extends StatelessWidget {
  const RecommendationSection(
      {super.key, required this.title, required this.items});

  final String title;
  final Iterable<Recommendation> items;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return SectionCard(
      title: title,
      children: [
        if (items.isEmpty) Text(copy.noRecommendations),
        for (final (index, item) in items.indexed) ...[
          if (index > 0) const Divider(height: 24),
          Wrap(
            spacing: 7,
            runSpacing: 6,
            children: [
              StatusPill(recommendationName(copy, item.kind), highlight: true),
              StatusPill(copy.generated),
              if (item.accepted) StatusPill(copy.accepted),
            ],
          ),
          const SizedBox(height: 7),
          Text(item.text),
          if (item.sourceUrl != null) ...[
            const SizedBox(height: 8),
            Text(copy.recommendationLink, style: theme.textTheme.labelLarge),
            SelectableText(item.sourceUrl!),
          ],
          if (item.userText != null) ...[
            const SizedBox(height: 10),
            Text(copy.yourEdit, style: theme.textTheme.labelLarge),
            Text(item.userText!),
          ],
        ],
      ],
    );
  }
}

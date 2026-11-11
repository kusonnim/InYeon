import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../native/external_link.dart';
import '../native/share_bridge.dart';
import 'detail_card.dart';
import 'itda_theme.dart';
import 'library_components.dart';
import 'original_image.dart';

class ContentHeading extends StatelessWidget {
  const ContentHeading({super.key, required this.title, this.onEditTitle});

  final String title;
  final VoidCallback? onEditTitle;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final titleText = Text(title, style: theme.textTheme.headlineSmall);
    return Padding(
      padding: const EdgeInsets.only(bottom: ItdaSpace.large),
      child: Semantics(
        container: onEditTitle != null,
        header: true,
        button: onEditTitle != null,
        label: onEditTitle == null ? null : copy.editContentTitle,
        child: onEditTitle == null
            ? titleText
            : Tooltip(
                message: copy.editContentTitle,
                excludeFromSemantics: true,
                child: InkWell(
                  onTap: onEditTitle,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: ItdaSpace.touchTarget,
                    ),
                    child: Row(
                      children: [
                        Expanded(child: titleText),
                        const SizedBox(width: ItdaSpace.small),
                        Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class ContentDetails extends StatelessWidget {
  const ContentDetails({
    super.key,
    required this.content,
    this.contextLabel,
    this.header = const [],
    this.footer = const [],
    this.original,
    this.loadingOriginal = false,
    this.openImage,
    this.openDocument,
    this.onEditTitle,
    this.onEditNotes,
    this.primaryAction,
  });

  final ContentItem content;
  final String? contextLabel;
  final List<Widget> header;
  final List<Widget> footer;
  final LocalSource? original;
  final bool loadingOriginal;
  final VoidCallback? openImage;
  final VoidCallback? openDocument;
  final VoidCallback? onEditTitle;
  final VoidCallback? onEditNotes;
  final Widget? primaryAction;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final type = content.inputType;
    final image = type == InputType.image;
    final title = contentTitle(copy, content, original: original);
    final sourceUrl = original?.url ?? content.sourceUrl;
    final originalText = readableSourceText(
      original?.text ?? content.sourceText,
      sourceUrl,
    );
    final summary = content.analysis?.summary?.trim();
    final generated = summary?.isNotEmpty == true ? summary : null;
    final primary = image
        ? null
        : type == InputType.text
        ? originalText ?? generated
        : generated ?? originalText;
    final status = content.analysisStatus;
    final statusText = status != AnalysisStatus.completed
        ? analysisName(copy, status)
        : primary == null && !image
        ? copy.noSummary
        : null;
    final recommendations = content.recommendations;
    final notes = content.userNote;
    final editNotes = onEditNotes;
    final meta = Theme.of(context).textTheme.bodySmall;
    return PageList(
      children: [
        ...header,
        DetailCard(
          children: (expanded) => [
            ContentHeading(title: title, onEditTitle: onEditTitle),
            if (image)
              OriginalImagePreview(
                original: original,
                loading: loadingOriginal,
                onExpand: openImage,
              )
            else if (primary != null && primary.trim() != title.trim())
              Padding(
                padding: const EdgeInsets.only(bottom: ItdaSpace.large),
                child: DetailText(text: primary, expanded: expanded),
              ),
            if (statusText != null)
              Padding(
                padding: const EdgeInsets.only(bottom: ItdaSpace.large),
                child: Text(statusText, style: meta),
              ),
            if (recommendations.isNotEmpty)
              RecommendationSection(
                title: copy.recommendations,
                items: recommendations.take(1),
                expanded: expanded,
              ),
            if (primaryAction != null) primaryAction!,
            if (expanded) ...[
              const Divider(height: ItdaSpace.bottom),
              DetailMetadata(
                type: type,
                savedAt: content.createdAt,
                sourceUrl: sourceUrl,
                contextLabel: contextLabel,
              ),
              OriginalSource.fromContent(
                content,
                original: original,
                loadingOriginal: loadingOriginal,
                openDocument: openDocument,
                displayedTitle: title,
                showText:
                    originalText?.trim() != primary?.trim() &&
                    originalText?.trim() != title.trim(),
                showImage: false,
              ),
              _AnalysisDetails(
                analysis: content.analysis,
                showSummary:
                    generated != null &&
                    generated != primary &&
                    generated != title.trim() &&
                    generated != originalText?.trim(),
              ),
              if (recommendations.length > 1)
                RecommendationSection(
                  title: copy.moreRecommendations,
                  items: recommendations.skip(1),
                ),
              if (notes?.trim().isNotEmpty == true)
                ContentSection(
                  title: copy.notes,
                  action: editNotes == null
                      ? null
                      : (onTap: editNotes, label: copy.editNotes),
                  children: [Text(notes!)],
                )
              else if (editNotes != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: editNotes,
                    child: Text(copy.editNotes),
                  ),
                ),
              ...footer,
            ],
          ],
        ),
      ],
    );
  }
}

String? readableSourceText(String? original, String? url) {
  final text = url != null && ExternalLink(url).isProtected
      ? original?.replaceAll(url, '')
      : original;
  final trimmed = text?.trim();
  return trimmed != null && trimmed.isNotEmpty && trimmed != url ? text : null;
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
    this.openSavedCopy,
    this.openImage,
    this.openDocument,
    this.displayedTitle,
    this.showText = true,
    this.showImage = true,
  });

  OriginalSource.fromContent(
    ContentItem content, {
    LocalSource? original,
    bool loadingOriginal = false,
    VoidCallback? openImage,
    VoidCallback? openDocument,
    String? displayedTitle,
    bool showText = true,
    bool showImage = true,
  }) : this(
         text: content.sourceText,
         url: content.sourceUrl,
         inputType: content.inputType,
         original: original,
         loadingOriginal: loadingOriginal,
         hasAttachment: content.assetIds.isNotEmpty,
         openImage: openImage,
         openDocument: openDocument,
         displayedTitle: displayedTitle,
         showText: showText,
         showImage: showImage,
       );

  final String? text;
  final String? url;
  final InputType? inputType;
  final LocalSource? original;
  final bool loadingOriginal;
  final bool hasAttachment;
  final VoidCallback? openSavedCopy;
  final VoidCallback? openImage;
  final VoidCallback? openDocument;
  final String? displayedTitle;
  final bool showText;
  final bool showImage;

  String? get _url => original?.url ?? url;

  ExternalLink? get _link {
    final url = _url;
    if (url == null) return null;
    final link = ExternalLink(url);
    return link.isProtected ? null : link;
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final meta = Theme.of(context).textTheme.bodySmall;
    final url = _url;
    final link = _link;
    final sourceText = readableSourceText(original?.text ?? text, url);
    final filename = original?.filename;
    final type = inputType ?? original?.inputType;
    final image = type == InputType.image;
    final document = type == InputType.document;
    final children = <Widget>[
      if (image && showImage && openImage != null)
        OriginalImagePreview(
          original: original,
          loading: loadingOriginal,
          onExpand: openImage,
        ),
      if (link != null) _linkText(context, link),
      if (sourceText != null && showText) ...[
        if (link != null) const SizedBox(height: ItdaSpace.small),
        DetailText(text: sourceText, expanded: true),
      ],
      if (filename != null && filename != displayedTitle)
        Text(filename, style: meta)
      else if (hasAttachment && filename == null && !image && !document)
        Text(copy.originalAttachment, style: meta),
      if (document)
        if (openDocument != null)
          TextButton.icon(
            onPressed: openDocument,
            icon: const Icon(Icons.open_in_new, size: 17),
            label: Text(copy.openOriginal),
          )
        else if (!loadingOriginal && openSavedCopy == null)
          Text(copy.documentUnavailable, style: meta),
      if (link != null || sourceText != null || openSavedCopy != null)
        Wrap(
          spacing: ItdaSpace.small,
          children: [
            if (link != null) ...[
              if (link.canOpen) _openButton(context, link, copy.openOriginal),
              _copyButton(context, link.value, isLink: true),
            ] else if (sourceText != null)
              _copyButton(context, sourceText, isLink: false),
            if (openSavedCopy != null && !image)
              TextButton(
                onPressed: openSavedCopy,
                child: Text(copy.readOriginal),
              ),
          ],
        ),
    ];
    if (children.isEmpty) {
      if (image || (document && loadingOriginal))
        return const SizedBox.shrink();
      children.add(Text(copy.sourceUnavailable, style: meta));
    }
    return ContentSection(title: copy.originalSource, children: children);
  }
}

Widget _linkText(BuildContext context, ExternalLink link) {
  if (!link.canOpen) return SelectableText(link.value);
  return Semantics(
    link: true,
    child: InkWell(
      onTap: () => _openLink(context, link),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: ItdaSpace.touchTarget),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          heightFactor: 1,
          child: Text(
            link.value,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _openButton(BuildContext context, ExternalLink link, String label) =>
    TextButton.icon(
      onPressed: () => _openLink(context, link),
      icon: const Icon(Icons.open_in_new, size: 17),
      label: Text(label),
    );

Future<void> _openLink(BuildContext context, ExternalLink link) async {
  if (await link.open() || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context).linkOpenFailed)),
  );
}

Widget _copyButton(BuildContext context, String value, {required bool isLink}) {
  final copy = AppLocalizations.of(context);
  return TextButton(
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: value));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isLink ? copy.copiedLink : copy.copiedSource)),
        );
      }
    },
    child: Text(isLink ? copy.copyLink : copy.copySource),
  );
}

class _AnalysisDetails extends StatelessWidget {
  const _AnalysisDetails({required this.analysis, required this.showSummary});

  final Analysis? analysis;
  final bool showSummary;

  @override
  Widget build(BuildContext context) {
    final analysis = this.analysis;
    if (analysis == null) return const SizedBox.shrink();
    final copy = AppLocalizations.of(context);
    final meta = Theme.of(context).textTheme.bodySmall;
    final coverage = switch (analysis.coverage) {
      AnalysisCoverage.fullText => copy.coverageFull,
      AnalysisCoverage.partialText => copy.coveragePartial,
      AnalysisCoverage.metadataOnly => copy.coverageMetadata,
      AnalysisCoverage.unsupported => copy.coverageUnsupported,
    };
    final summary = analysis.summary?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showSummary && summary != null)
          ContentSection(
            title: copy.summary,
            children: [DetailText(text: summary, expanded: true)],
          ),
        ContentSection(
          title: copy.analysisDetails,
          children: [
            if (summary?.isNotEmpty == true)
              Text(copy.summaryProvenance, style: meta),
            Text(coverage, style: meta),
            for (final limitation in analysis.limitations)
              Padding(
                padding: const EdgeInsets.only(top: ItdaSpace.tiny),
                child: Text(limitation, style: meta),
              ),
          ],
        ),
      ],
    );
  }
}

class RecommendationSection extends StatelessWidget {
  const RecommendationSection({
    super.key,
    required this.title,
    required this.items,
    this.expanded = true,
  });

  final String title;
  final Iterable<Recommendation> items;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return ContentSection(
      title: title,
      children: [
        for (final (index, item) in items.indexed) ...[
          if (index > 0) const SizedBox(height: ItdaSpace.large),
          _RecommendationBody(item: item, expanded: expanded),
        ],
      ],
    );
  }
}

class _RecommendationBody extends StatelessWidget {
  const _RecommendationBody({required this.item, required this.expanded});

  final Recommendation item;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final url = item.sourceUrl;
    final link = url == null ? null : ExternalLink(url);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            recommendationName(copy, item.kind),
            if (item.accepted) copy.accepted,
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: ItdaSpace.tiny),
        DetailText(text: item.text, expanded: expanded),
        if (link != null && !link.isProtected)
          Wrap(
            spacing: ItdaSpace.small,
            children: [
              if (link.canOpen)
                _openButton(context, link, copy.openResource)
              else if (expanded)
                SelectableText(link.value),
              if (expanded) _copyButton(context, link.value, isLink: true),
            ],
          ),
        if (expanded && item.userText?.trim().isNotEmpty == true) ...[
          const SizedBox(height: ItdaSpace.small),
          Text(copy.yourEdit, style: theme.textTheme.labelLarge),
          Text(item.userText!),
        ],
      ],
    );
  }
}

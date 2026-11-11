import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import '../native/external_link.dart';
import '../native/share_bridge.dart';
import 'itda_theme.dart';
import 'library_components.dart';
import 'original_image.dart';

class ContentHeading extends StatelessWidget {
  const ContentHeading({
    super.key,
    required this.title,
    required this.source,
    this.contextLabel,
    this.onEditTitle,
  });

  final String title;
  final String source;
  final String? contextLabel;
  final VoidCallback? onEditTitle;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final titleText = Text(title, style: theme.textTheme.headlineSmall);
    return Padding(
      padding: const EdgeInsets.only(bottom: ItdaSpace.large),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
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
          const SizedBox(height: ItdaSpace.tiny),
          Wrap(
            spacing: ItdaSpace.medium,
            runSpacing: ItdaSpace.tiny,
            children: [
              Text(source, style: theme.textTheme.bodySmall),
              if (contextLabel != null)
                Text(contextLabel!, style: theme.textTheme.bodySmall),
            ],
          ),
        ],
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

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final type = content.inputType;
    final image = type == InputType.image;
    final web = type == InputType.url;
    final title = contentTitle(copy, content, original: original);
    final source = OriginalSource.fromContent(
      content,
      original: original,
      loadingOriginal: loadingOriginal,
      openDocument: openDocument,
      displayedTitle: title,
      disclose: web || image,
    );
    final link = source._link;
    final recommendations = content.recommendations;
    final notes = content.userNote;
    final editNotes = onEditNotes;
    return PageList(
      children: [
        ...header,
        if (image)
          OriginalImagePreview(
            original: original,
            loading: loadingOriginal,
            onExpand: openImage,
          ),
        ContentHeading(
          title: title,
          source: sourceCue(copy, type, source._url),
          contextLabel: contextLabel,
          onEditTitle: onEditTitle,
        ),
        if (web && link?.canOpen == true)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _openButton(context, link!, copy.openOriginal),
          ),
        if (!web && !image) source,
        _AnalysisSection(content: content, discloseSummary: !web),
        if (recommendations.isNotEmpty)
          RecommendationSection(
            title: copy.recommendations,
            items: recommendations,
          ),
        if (web || image) source,
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
        Padding(
          padding: const EdgeInsets.only(top: ItdaSpace.medium),
          child: Text(
            copy.savedOn(
              MaterialLocalizations.of(
                context,
              ).formatMediumDate(content.createdAt.toLocal()),
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
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
    this.openSavedCopy,
    this.openImage,
    this.openDocument,
    this.displayedTitle,
    this.disclose = false,
  });

  OriginalSource.fromContent(
    ContentItem content, {
    LocalSource? original,
    bool loadingOriginal = false,
    VoidCallback? openImage,
    VoidCallback? openDocument,
    String? displayedTitle,
    bool disclose = false,
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
         disclose: disclose,
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
  final bool disclose;

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
    final originalText = original?.text ?? text;
    final visibleText = url != null && link == null
        ? originalText?.replaceAll(url, '')
        : originalText;
    final trimmed = visibleText?.trim();
    final sourceText = trimmed != null && trimmed.isNotEmpty && trimmed != url
        ? visibleText
        : null;
    final filename = original?.filename;
    final type = inputType ?? original?.inputType;
    final image = type == InputType.image;
    final document = type == InputType.document;
    final children = <Widget>[
      if (image && !disclose && openImage != null)
        OriginalImagePreview(
          original: original,
          loading: loadingOriginal,
          onExpand: openImage,
        ),
      if (link != null) _linkText(context, link),
      if (sourceText != null) ...[
        if (link != null) const SizedBox(height: ItdaSpace.small),
        _ReadingExcerpt(text: sourceText),
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
              if (!disclose && link.canOpen)
                _openButton(context, link, copy.openOriginal),
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
    return disclose
        ? ContentDisclosure(title: copy.originalSource, children: children)
        : ContentSection(title: copy.originalSource, children: children);
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
class _ReadingExcerpt extends StatefulWidget {
  const _ReadingExcerpt({required this.text});

  final String text;

  @override
  State<_ReadingExcerpt> createState() => _ReadingExcerptState();
}
class _ReadingExcerptState extends State<_ReadingExcerpt> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.bodyLarge!;
    const previewLines = 6;
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.localeOf(context),
          maxLines: previewLines,
          ellipsis: '…',
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        if (!overflows || _expanded) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(widget.text, style: style),
              if (overflows)
                TextButton(
                  onPressed: () => setState(() => _expanded = false),
                  child: Text(copy.showLess),
                ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: previewLines,
              overflow: TextOverflow.ellipsis,
            ),
            TextButton(
              onPressed: () => setState(() => _expanded = true),
              child: Text(copy.readMore),
            ),
          ],
        );
      },
    );
  }
}
class _AnalysisSection extends StatelessWidget {
  const _AnalysisSection({
    required this.content,
    required this.discloseSummary,
  });

  final ContentItem content;

  final bool discloseSummary;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final meta = Theme.of(context).textTheme.bodySmall;
    final analysis = content.analysis;
    final status = content.analysisStatus;
    final coverage = switch (analysis?.coverage) {
      AnalysisCoverage.fullText => copy.coverageFull,
      AnalysisCoverage.partialText => copy.coveragePartial,
      AnalysisCoverage.metadataOnly => copy.coverageMetadata,
      AnalysisCoverage.unsupported => copy.coverageUnsupported,
      null => null,
    };
    final limitations = analysis?.limitations ?? const <String>[];
    final summary = analysis?.summary?.trim();
    final hasSummary = summary != null && summary.isNotEmpty;
    final incomplete =
        coverage != null && analysis?.coverage != AnalysisCoverage.fullText;
    final coverageDetails = <Widget>[
      if (coverage != null && !incomplete) Text(coverage, style: meta),
      for (final limitation in limitations)
        Padding(
          padding: const EdgeInsets.only(bottom: ItdaSpace.tiny),
          child: Text(limitation, style: meta),
        ),
    ];
    final statusLines = <Widget>[
      if (status != AnalysisStatus.completed)
        Text(analysisName(copy, status), style: meta),
      if (incomplete) Text(coverage, style: meta),
    ];
    final body = <Widget>[
      if (!discloseSummary) ...statusLines,
      if (hasSummary) ...[
        if (!discloseSummary && statusLines.isNotEmpty)
          const SizedBox(height: ItdaSpace.small),
        _ReadingExcerpt(text: summary),
      ],
      if (coverageDetails.isNotEmpty)
        ContentDisclosure(
          title: copy.analysisDetails,
          children: coverageDetails,
        ),
    ];
    if (hasSummary && !discloseSummary) {
      return ContentSection(title: copy.aiSummary, children: body);
    }
    if (statusLines.isEmpty && body.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: ItdaSpace.large),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (discloseSummary) ...statusLines,
          if (hasSummary)
            ContentDisclosure(title: copy.aiSummary, children: body)
          else
            ...body,
        ],
      ),
    );
  }
}
class RecommendationSection extends StatelessWidget {
  const RecommendationSection(
      {super.key, required this.title, required this.items});

  final String title;
  final List<Recommendation> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final copy = AppLocalizations.of(context);
    return ContentSection(
      title: title,
      children: [
        _RecommendationBody(item: items.first),
        if (items.length > 1)
          ContentDisclosure(
            title: copy.moreRecommendations,
            children: [
              for (final item in items.skip(1))
                Padding(
                  padding: const EdgeInsets.only(bottom: ItdaSpace.large),
                  child: _RecommendationBody(item: item),
                ),
            ],
          ),
      ],
    );
  }
}
class _RecommendationBody extends StatelessWidget {
  const _RecommendationBody({required this.item});

  final Recommendation item;

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
        _ReadingExcerpt(text: item.text),
        if (link != null && !link.isProtected)
          Wrap(
            spacing: ItdaSpace.small,
            children: [
              if (link.canOpen)
                _openButton(context, link, copy.openResource)
              else
                SelectableText(link.value),
              _copyButton(context, link.value, isLink: true),
            ],
          ),
        if (item.userText?.trim().isNotEmpty == true) ...[
          const SizedBox(height: ItdaSpace.small),
          Text(copy.yourEdit, style: theme.textTheme.labelLarge),
          Text(item.userText!),
        ],
      ],
    );
  }
}

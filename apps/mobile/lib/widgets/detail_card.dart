import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/content.dart';
import 'itda_theme.dart';
import 'library_components.dart';

class DetailCard extends StatefulWidget {
  const DetailCard({super.key, required this.children, this.primaryAction});

  final List<Widget> Function(bool expanded) children;
  final Widget? primaryAction;

  @override
  State<DetailCard> createState() => _DetailCardState();
}

class _DetailCardState extends State<DetailCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widget.children(_expanded),
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return PageWidth(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ItdaSpace.page,
          ItdaSpace.medium,
          ItdaSpace.page,
          ItdaSpace.tiny,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(ItdaSpace.large),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.all(ItdaSpace.large),
                  child: reduceMotion
                      ? content
                      : AnimatedSize(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeInOut,
                          alignment: Alignment.topCenter,
                          child: content,
                        ),
                ),
              ),
            ),
            const SizedBox(height: ItdaSpace.tiny),
            Semantics(
              expanded: _expanded,
              child: TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                iconAlignment: IconAlignment.end,
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: Text(
                  _expanded ? copy.hideDetails : copy.showDetails,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (widget.primaryAction case final action?) action,
          ],
        ),
      ),
    );
  }
}

class DetailText extends StatelessWidget {
  const DetailText({super.key, required this.text, required this.expanded});

  final String text;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge;
    return expanded
        ? SelectableText(text, style: style)
        : Text(
            text,
            style: style,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
          );
  }
}

class DetailMetadata extends StatelessWidget {
  const DetailMetadata({
    super.key,
    required this.type,
    required this.savedAt,
    this.sourceUrl,
    this.contextLabel,
  });

  final InputType? type;
  final DateTime savedAt;
  final String? sourceUrl;
  final String? contextLabel;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final typeLabel = sourceName(copy, type);
    final source = sourceCue(copy, type, sourceUrl);
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(savedAt.toLocal());
    final meta = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: ItdaSpace.large),
      child: Wrap(
        spacing: ItdaSpace.medium,
        runSpacing: ItdaSpace.tiny,
        children: [
          Text(typeLabel, style: meta),
          if (source != typeLabel) Text(source, style: meta),
          Text(copy.savedOn(date), style: meta),
          if (contextLabel != null) Text(contextLabel!, style: meta),
        ],
      ),
    );
  }
}

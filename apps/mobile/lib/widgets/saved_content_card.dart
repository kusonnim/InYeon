import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../library/library_controller.dart';
import '../models/content.dart';
import '../native/share_bridge.dart';
import 'library_components.dart';

class SavedContentCard extends StatelessWidget {
  const SavedContentCard({
    super.key,
    required this.entry,
    required this.mode,
    required this.onOpen,
    this.sample = false,
  });

  final LibraryEntry entry;
  final UploadMode mode;
  final VoidCallback? onOpen;
  final bool sample;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final content = entry.remote;
    final local = entry.local;
    final title = content == null
        ? localTitle(copy, local!)
        : contentTitle(copy, content, local);
    final summary = content?.analysis?.summary?.trim();
    final recommendations = content?.recommendations;
    final suggestion = recommendations == null || recommendations.isEmpty
        ? null
        : recommendations.first;

    return Card(
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.secondaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(sourceIcon(entry.type),
                          size: 19, color: colors.onSecondaryContainer),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      sourceName(copy, entry.type),
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                  if (onOpen != null)
                    Icon(Icons.chevron_right_rounded,
                        color: colors.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 11),
              Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge),
              if (summary != null && summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium),
              ],
              if (suggestion != null) ...[
                const SizedBox(height: 10),
                _SuggestionPreview(suggestion: suggestion),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 6,
                children: [
                  if (!sample)
                    if (local != null)
                      StatusPill(
                        uploadName(copy, mode, local),
                        error: local.uploadState ==
                            LocalUploadState.permanentFailure,
                      )
                    else
                      StatusPill(copy.synced),
                  if (content != null)
                    StatusPill(
                      analysisName(copy, content.analysisStatus),
                      highlight:
                          content.analysisStatus == AnalysisStatus.completed,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionPreview extends StatelessWidget {
  const _SuggestionPreview({required this.suggestion});

  final Recommendation suggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final copy = AppLocalizations.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.tips_and_updates_outlined,
            size: 17, color: theme.colorScheme.primary),
        const SizedBox(width: 7),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${recommendationName(copy, suggestion.kind)} · ',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: suggestion.text),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

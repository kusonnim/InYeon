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
    this.showSavedAt = false,
  });

  final LibraryEntry entry;
  final UploadMode mode;
  final VoidCallback? onOpen;
  final bool sample;
  final bool showSavedAt;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final content = entry.remote;
    final local = entry.local;
    final summary =
        content?.analysis?.summary?.trim().replaceAll(RegExp(r'\s+'), ' ');
    final savedAt = (local?.receivedAt ?? entry.savedAt).toLocal();
    final dates = MaterialLocalizations.of(context);

    return Card(
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                      padding: const EdgeInsets.all(5),
                      child: Icon(sourceIcon(entry.type),
                          size: 16, color: colors.onSecondaryContainer),
                    ),
                  ),
                  const SizedBox(width: 8),
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
              const SizedBox(height: 6),
              Text(entryTitle(copy, entry),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium),
              if (showSavedAt) ...[
                const SizedBox(height: 4),
                Text(
                  [
                    dates.formatMediumDate(savedAt),
                    dates.formatTimeOfDay(TimeOfDay.fromDateTime(savedAt),
                        alwaysUse24HourFormat:
                            MediaQuery.alwaysUse24HourFormatOf(context)),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (summary != null && summary.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: copy.aiSummary + ' · ',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: compactText(summary, 160)),
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 7),
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

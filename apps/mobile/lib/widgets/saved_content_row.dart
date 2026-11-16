import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../library/library_controller.dart';
import 'itda_theme.dart';
import 'library_components.dart';

class SavedContentRow extends StatelessWidget {
  const SavedContentRow({
    super.key,
    required this.entry,
    this.onOpen,
    this.status,
    this.showSavedAt = false,
  });

  final LibraryEntry entry;
  final VoidCallback? onOpen;
  final String? status;
  final bool showSavedAt;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final dates = MaterialLocalizations.of(context);
    final savedAt = entry.savedAt.toLocal();
    final source = sourceCue(copy, entry.type, entry.linkUrl);
    return ListTile(
      onTap: onOpen,
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: ItdaSpace.section,
      horizontalTitleGap: ItdaSpace.medium,
      minVerticalPadding: ItdaSpace.medium,
      leading: Icon(
        sourceIcon(entry.type),
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        entryTitle(copy, entry),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      ),
      subtitle: Text(
        [
          source,
          if (showSavedAt) ...[
            dates.formatMediumDate(savedAt),
            dates.formatTimeOfDay(
              TimeOfDay.fromDateTime(savedAt),
              alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(
                context,
              ),
            ),
          ],
          if (status != null) status!,
        ].join(' · '),
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

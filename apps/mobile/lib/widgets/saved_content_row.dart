import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../library/library_controller.dart';
import '../models/content.dart';
import '../native/share_bridge.dart';
import 'itda_theme.dart';
import 'library_components.dart';

class SavedContentRow extends StatelessWidget {
  const SavedContentRow({
    super.key,
    required this.entry,
    this.mode = UploadMode.disabled,
    this.onOpen,
    this.showSavedAt = false,
  });

  final LibraryEntry entry;
  final UploadMode mode;
  final VoidCallback? onOpen;
  final bool showSavedAt;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final dates = MaterialLocalizations.of(context);
    final savedAt = entry.savedAt.toLocal();
    final source = sourceCue(copy, entry.type, entry.linkUrl);
    final colors = theme.colorScheme;
    final metaStyle = theme.textTheme.bodySmall!;
    final status = _status(copy, colors);
    final metadata = [
      source,
      if (showSavedAt) ...[
        dates.formatMediumDate(savedAt),
        dates.formatTimeOfDay(
          TimeOfDay.fromDateTime(savedAt),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        ),
      ],
    ].join(' · ');
    return ListTile(
      onTap: onOpen,
      contentPadding: EdgeInsets.zero,
      horizontalTitleGap: ItdaSpace.medium,
      minVerticalPadding: ItdaSpace.small,
      minTileHeight: 68,
      leading: SavedSourceIcon(entry.type),
      title: SavedContentTitle(entryTitle(copy, entry)),
      subtitle: Wrap(
        spacing: ItdaSpace.tiny,
        children: [
          Text(metadata, style: metaStyle),
          if (status != null)
            Text(
              '· ${status.label}',
              style: metaStyle.copyWith(color: status.color),
            ),
        ],
      ),
      trailing: onOpen == null
          ? null
          : Icon(
              Icons.chevron_right_rounded,
              color: colors.onSurfaceVariant,
              size: 18,
              textDirection: Directionality.of(context),
            ),
    );
  }

  ({String label, Color? color})? _status(
    AppLocalizations copy,
    ColorScheme colors,
  ) {
    final local = entry.local;
    final analysis = entry.remote?.analysisStatus;
    if (local != null &&
        local.inputType != null &&
        (analysis == null ||
            local.uploadState != LocalUploadState.synchronized)) {
      return (
        label: uploadName(copy, mode, local),
        color:
            mode != UploadMode.disabled &&
                local.uploadState == LocalUploadState.permanentFailure
            ? colors.error
            : null,
      );
    }
    if (analysis == null) return null;
    return (
      label: analysisName(copy, analysis),
      color: switch (analysis) {
        AnalysisStatus.completed => colors.tertiary,
        AnalysisStatus.failed => colors.error,
        _ => null,
      },
    );
  }
}

class SavedContentTitle extends StatelessWidget {
  const SavedContentTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall!;
    final size = style.fontSize!;
    final scaled = MediaQuery.textScalerOf(context).scale(size);
    final compact = scaled <= size * 1.25;
    return Text(
      title,
      maxLines: compact ? 2 : null,
      overflow: compact ? TextOverflow.ellipsis : TextOverflow.clip,
      style: style,
    );
  }
}

class SavedSourceIcon extends StatelessWidget {
  const SavedSourceIcon(this.type, {super.key});

  final InputType? type;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(ItdaSpace.small),
      ),
      child: Icon(sourceIcon(type), size: 19, color: colors.onPrimaryContainer),
    );
  }
}

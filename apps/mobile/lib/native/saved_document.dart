import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';

Future<void> openSavedDocument(
  BuildContext context,
  Map<String, String> reference,
) async {
  const channel = MethodChannel('com.itda.itda_mobile/local_shares');
  String? errorCode;
  try {
    await channel.invokeMethod<void>('openSavedDocument', reference);
    return;
  } on PlatformException catch (error) {
    errorCode = error.code;
  } on MissingPluginException {
    // The saved original is only available on Android.
  }
  if (!context.mounted) return;
  final copy = AppLocalizations.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(errorCode == 'document_viewer_unavailable'
        ? copy.documentViewerUnavailable : copy.documentOpenFailed)),
  );
}

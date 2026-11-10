import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/content_api.dart';
import 'api/fixture_content_api.dart';
import 'l10n/generated/app_localizations.dart';
import 'library/library_controller.dart';
import 'library/library_screen.dart';
import 'library/local_content_screen.dart';
import 'native/catalog_bridge.dart';
import 'native/language_preference.dart';
import 'native/notification_bridge.dart';
import 'native/share_bridge.dart';
import 'widgets/itda_theme.dart';
import 'widgets/registered_content_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final language = android ? const AndroidLanguagePreference() : null;
  runApp(ItdaApp(
    api: await FixtureContentApi.load(),
    initialLocale: await language?.read() ?? const Locale('ko'),
    languagePreference: language,
    shareBridge: android ? const AndroidShareBridge() : null,
    catalogBridge: android ? const AndroidCatalogBridge() : null,
    notificationBridge: android ? const AndroidNotificationBridge() : null,
  ));
}

class ItdaApp extends StatefulWidget {
  const ItdaApp({
    super.key,
    required this.api,
    this.initialLocale = const Locale('ko'),
    this.languagePreference,
    this.shareBridge,
    this.catalogBridge,
    this.notificationBridge,
  });

  final ContentApi api;
  final Locale initialLocale;
  final LanguagePreference? languagePreference;
  final ShareBridge? shareBridge;
  final CatalogBridge? catalogBridge;
  final NotificationBridge? notificationBridge;

  @override
  State<ItdaApp> createState() => _ItdaAppState();
}

class _ItdaAppState extends State<ItdaApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _library =
      LibraryController(widget.shareBridge, widget.catalogBridge);
  late final AppLifecycleListener _lifecycle;
  late Locale _locale = widget.initialLocale;
  StreamSubscription<void>? _noticeChanges;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _library.reload);
    unawaited(_library.reload());
    final bridge = widget.notificationBridge;
    if (bridge == null) return;
    _noticeChanges = bridge.changes.listen(
      (_) => unawaited(_openNotification(bridge)),
      onError: (Object _) {},
    );
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(_openNotification(bridge)));
  }

  @override
  void dispose() {
    unawaited(_noticeChanges?.cancel());
    _lifecycle.dispose();
    _library.dispose();
    super.dispose();
  }

  Future<void> _openNotification(NotificationBridge bridge) async {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    try {
      final navigation = await bridge.takeNavigation();
      if (navigation == null || !mounted || !navigator.mounted) return;
      final target = navigation.target;
      final owner = (ownerId: target.ownerId, realm: target.realm);
      final entry = _library.scope == owner
          ? _library.entries
              .where((item) => item.serverId == target.contentId)
              .firstOrNull
          : null;
      final local = entry?.local;
      unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => RegisteredContentScreen(
          bridge: bridge,
          target: target,
          openEditor: navigation.destination == NoticeDestination.edit,
          initialContent: entry?.remote,
          initialMode: _library.inbox?.mode ?? UploadMode.disabled,
          openOriginal: local == null
              ? null
              : () => navigator.push<void>(MaterialPageRoute(
                    builder: (_) => LocalContentScreen(
                        controller: _library, localId: local.localId),
                  )),
          onChanged: (item) => _library.updateItem(owner, item),
        ),
      )));
    } on PlatformException {
      // Keep the library available when a native route is no longer authorized.
    }
  }

  Future<void> _changeLanguage(Locale locale) async {
    if (locale == _locale) return;
    await widget.languagePreference?.write(locale);
    if (mounted) setState(() => _locale = locale);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        onGenerateTitle: (context) => AppLocalizations.of(context).appName,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: _locale,
        theme: itdaTheme(Brightness.light),
        darkTheme: itdaTheme(Brightness.dark),
        home: LibraryScreen(
          controller: _library,
          samples: widget.api,
          notifications: widget.notificationBridge,
          changeLanguage: _changeLanguage,
        ),
      );
}

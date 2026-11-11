import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../native/notification_bridge.dart';
import '../native/share_bridge.dart';
import '../widgets/itda_theme.dart';
import '../widgets/library_components.dart';
import 'library_controller.dart';
import 'sign_in_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.controller,
    required this.openSamples,
    required this.changeLanguage,
    this.notifications,
  });

  final LibraryController controller;
  final VoidCallback openSamples;
  final Future<void> Function(Locale) changeLanguage;
  final NotificationBridge? notifications;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}
class _AccountScreenState extends State<AccountScreen> {
  bool _busy = false;
  bool _changingLanguage = false;
  String? _error;

  void _openSignIn() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => SignInScreen(controller: widget.controller)),
    );
  }

  Future<void> _signOut() async {
    final bridge = widget.controller.shares;
    if (bridge == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.controller.hideAccountData();
      await bridge.signOut();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.code);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        unawaited(widget.controller.reload());
      }
    }
  }

  Future<void> _enable() async {
    final copy = AppLocalizations.of(context);
    try {
      await widget.notifications?.enable();
      if (mounted) await widget.controller.reload();
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(copy.notificationSettingsProblem)));
      }
    }
  }

  Future<void> _selectLanguage(Locale? locale) async {
    if (locale == null) return;
    setState(() => _changingLanguage = true);
    try {
      await widget.changeLanguage(locale);
    } on PlatformException {
      if (mounted) {
        final copy = AppLocalizations.of(context);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(copy.languageChangeProblem)));
      }
    } finally {
      if (mounted) setState(() => _changingLanguage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(copy.account)),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final inbox = widget.controller.inbox;
          if (inbox == null) {
            return widget.controller.localError
                ? PageList(
                    children: [
                      StatePanel(
                        icon: Icons.info_outline_rounded,
                        title: copy.localLoadError,
                        action: widget.controller.reload,
                        actionLabel: copy.retry,
                      ),
                    ],
                  )
                : Center(
                    child: CircularProgressIndicator(
                      semanticsLabel: copy.loadingLibrary,
                    ),
                  );
          }
          return PageList(
            children: [
              _identity(copy, inbox),
              ContentSection(
                title: copy.language,
                children: [
                  DropdownButton<Locale>(
                    isExpanded: true,
                    value: Localizations.localeOf(context),
                    items: const [
                      DropdownMenuItem(value: Locale('ko'), child: Text('한국어')),
                      DropdownMenuItem(
                        value: Locale('en'),
                        child: Text('English'),
                      ),
                    ],
                    onChanged: _changingLanguage ? null : _selectLanguage,
                  ),
                ],
              ),
              if (widget.notifications != null &&
                  inbox.mode != UploadMode.disabled &&
                  inbox.account != null)
                _notifications(copy, inbox),
              if (inbox.mode != UploadMode.disabled) _uploads(copy, inbox),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: widget.openSamples,
                  icon: const Icon(Icons.auto_stories_outlined),
                  label: Text(copy.sampleLibrary),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: copy.appName,
                  ),
                  child: Text(copy.openSourceLicenses),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _identity(AppLocalizations copy, LocalInbox inbox) {
    final account = inbox.account;
    final disabled = inbox.mode == UploadMode.disabled;
    final theme = Theme.of(context);
    return ContentSection(
      title: disabled
          ? copy.deviceOnly
          : (account == null ? copy.signedOut : copy.signedIn),
      children: [
        if (uploadEnvironmentLabel(copy, inbox.mode) case final label?) ...[
          Text(label, style: theme.textTheme.bodySmall),
          if (inbox.stagingApiHost case final host?)
            Text(copy.stagingApiHost(host), style: theme.textTheme.bodySmall),
          Text(
            inbox.mode == UploadMode.staging
                ? copy.stagingAccountBody
                : copy.mockAccountBody,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: ItdaSpace.medium),
        ],
        if (disabled)
          Text(copy.localOnlyBody)
        else if (account != null) ...[
          SelectableText(account.email),
          TextButton(
            onPressed: _busy ? null : _signOut,
            child: Text(copy.signOut),
          ),
        ] else
          TextButton(onPressed: _busy ? null : _openSignIn, child: Text(copy.signIn)),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: ItdaSpace.small),
            child: Semantics(
              liveRegion: true,
              child: Text(
                copy.accountProblem,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
      ],
    );
  }

  Widget _uploads(AppLocalizations copy, LocalInbox inbox) {
    final visible = inbox.shares.where((item) => item.inputType != null);
    final failed = visible
        .where((item) => item.uploadState == LocalUploadState.permanentFailure)
        .length;
    final unassigned = visible
        .where(
          (item) =>
              item.canAssign ||
              (inbox.account == null &&
                  item.uploadState == LocalUploadState.authenticationRequired),
        )
        .length;
    final waiting =
        visible
            .where(
              (item) => switch (item.uploadState) {
                LocalUploadState.synchronized ||
                LocalUploadState.permanentFailure => false,
                _ => true,
              },
            )
            .length -
        unassigned;
    if (waiting == 0 && failed == 0 && unassigned == 0) {
      return const SizedBox.shrink();
    }
    return ContentSection(
      title: copy.uploadActivity,
      children: [
        if (waiting > 0) ...[
          Text(copy.queuedUploads(waiting)),
          Text(copy.uploadRetryInfo),
        ],
        if (failed > 0) ...[
          if (waiting > 0) const SizedBox(height: ItdaSpace.medium),
          Text(
            copy.failedUploads(failed),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          Text(copy.uploadFailureInfo),
        ],
        if (unassigned > 0) ...[
          if (waiting > 0 || failed > 0)
            const SizedBox(height: ItdaSpace.medium),
          Text(copy.unassignedCount(unassigned)),
          Text(inbox.account == null ? copy.signInBody : copy.unassignedHelp),
        ],
      ],
    );
  }

  Widget _notifications(AppLocalizations copy, LocalInbox inbox) =>
      ContentSection(
        title: copy.notificationPermission,
        children: [
          Text(
            inbox.notificationsEnabled
                ? copy.notificationsOn
                : copy.notificationsOff,
          ),
          if (!inbox.notificationsEnabled)
            TextButton(
              onPressed: _enable,
              child: Text(copy.enableNotifications),
            ),
        ],
      );
}

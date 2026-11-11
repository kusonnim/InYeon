import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../native/notification_bridge.dart';
import '../native/share_bridge.dart';
import '../widgets/itda_theme.dart';
import '../widgets/library_components.dart';
import 'library_controller.dart';

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
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _changingLanguage = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool signOut}) async {
    final bridge = widget.controller.shares;
    if (bridge == null ||
        _busy ||
        (!signOut && _form.currentState?.validate() != true)) return;
    final mode = widget.controller.inbox?.mode;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (signOut) {
        widget.controller.hideAccountData();
        await bridge.signOut();
      } else {
        await bridge.signIn(_email.text.trim(), _password.text);
        if (mounted)
          TextInput.finishAutofillContext(shouldSave: mode == UploadMode.live);
      }
      if (mounted) _email.clear();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.code);
    } finally {
      if (mounted) {
        _password.clear();
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
    final issue = switch (_error) {
      'authentication_required' || 'invalid_sign_in' => copy.signInProblem,
      'auth_unavailable' || 'network_unavailable' => copy.signInUnavailable,
      null => null,
      _ => copy.accountProblem,
    };
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
            onPressed: _busy ? null : () => _submit(signOut: true),
            child: Text(copy.signOut),
          ),
        ] else
          _signInForm(copy),
        if (_busy) const LinearProgressIndicator(),
        if (issue != null)
          Padding(
            padding: const EdgeInsets.only(top: ItdaSpace.small),
            child: Semantics(
              liveRegion: true,
              child: Text(
                issue,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
      ],
    );
  }

  Widget _signInForm(AppLocalizations copy) => AutofillGroup(
    onDisposeAction: AutofillContextAction.cancel,
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _email,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            validator: (value) =>
                value?.trim().isNotEmpty == true ? null : copy.signInProblem,
            decoration: InputDecoration(labelText: copy.email),
          ),
          const SizedBox(height: ItdaSpace.medium),
          TextFormField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            validator: (value) =>
                value?.isNotEmpty == true ? null : copy.signInProblem,
            onFieldSubmitted: (_) => _submit(signOut: false),
            decoration: InputDecoration(labelText: copy.password),
          ),
          const SizedBox(height: ItdaSpace.medium),
          FilledButton(
            onPressed: _busy ? null : () => _submit(signOut: false),
            child: Text(copy.signIn),
          ),
        ],
      ),
    ),
  );

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

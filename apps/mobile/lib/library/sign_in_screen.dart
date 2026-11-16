import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/generated/app_localizations.dart';
import '../native/share_bridge.dart';
import '../widgets/itda_theme.dart';
import '../widgets/library_components.dart';
import 'library_controller.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.controller,
    this.openAccountSettings,
  });

  final LibraryController controller;
  final VoidCallback? openAccountSettings;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final controller = widget.controller;
    final bridge = controller.shares;
    if (_busy || bridge == null || _form.currentState?.validate() != true) {
      return;
    }
    final mode = controller.inbox?.mode;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await bridge.signIn(_email.text.trim(), _password.text);
      unawaited(controller.reload());
      if (mounted && ModalRoute.isCurrentOf(context) == true) {
        TextInput.finishAutofillContext(shouldSave: mode == UploadMode.live);
        Navigator.of(context).pop();
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.code);
    } finally {
      if (mounted) {
        _password.clear();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final issue = switch (_error) {
      'authentication_required' || 'invalid_sign_in' => copy.signInProblem,
      'auth_unavailable' || 'network_unavailable' => copy.signInUnavailable,
      null => null,
      _ => copy.accountProblem,
    };
    return Scaffold(
      appBar: AppBar(title: Text(copy.signIn)),
      body: PageList(
        children: [
          if (uploadEnvironmentLabel(
                copy,
                widget.controller.inbox?.mode ?? UploadMode.disabled,
              )
              case final label?)
            Padding(
              padding: const EdgeInsets.only(bottom: ItdaSpace.medium),
              child: Text(label, style: theme.textTheme.bodySmall),
            ),
          AutofillGroup(
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
                    validator: (value) => value?.trim().isNotEmpty == true
                        ? null
                        : copy.signInProblem,
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
                    onFieldSubmitted: (_) => _signIn(),
                    decoration: InputDecoration(labelText: copy.password),
                  ),
                  const SizedBox(height: ItdaSpace.medium),
                  if (issue != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: ItdaSpace.medium),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          issue,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: _busy ? null : _signIn,
                    child: Text(copy.signIn),
                  ),
                  if (_busy)
                    Padding(
                      padding: const EdgeInsets.only(top: ItdaSpace.small),
                      child: LinearProgressIndicator(
                        semanticsLabel: copy.signingIn,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (widget.openAccountSettings case final open?)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: _busy ? null : open,
                child: Text(copy.accountSettings),
              ),
            ),
        ],
      ),
    );
  }
}

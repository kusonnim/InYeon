import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'share_bridge.dart';

class UploadAccountDialog extends StatefulWidget {
  const UploadAccountDialog({
    super.key,
    required this.bridge,
    required this.inbox,
  });

  final ShareBridge bridge;
  final LocalInbox inbox;

  @override
  State<UploadAccountDialog> createState() => _UploadAccountDialogState();
}

class _UploadAccountDialogState extends State<UploadAccountDialog> {
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

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.inbox.account == null) {
        await widget.bridge.signIn(_email.text.trim(), _password.text);
      } else {
        await widget.bridge.signOut();
      }
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (error.code) {
          'invalid_sign_in' => 'Enter your email and password.',
          'authentication_required' =>
            'The sign-in details could not be verified.',
          'auth_unavailable' ||
          'network_unavailable' =>
            'Sign-in is unavailable. Check your connection.',
          _ => 'Unable to update the upload account.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.inbox.account;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(account == null ? 'Sign in for uploads' : 'Upload account'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.inbox.mode == UploadMode.mock)
                const Text('Mock upload server. Use a synthetic test account.'),
              if (account == null) ...[
                TextField(
                  controller: _email,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ] else
                Text(
                    'Signed in as ${account.email}. Signing out pauses uploads for this account.'),
              if (_error != null) Text(_error!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(_busy
                ? 'Please wait…'
                : (account == null ? 'Sign in' : 'Sign out')),
          ),
        ],
      ),
    );
  }
}

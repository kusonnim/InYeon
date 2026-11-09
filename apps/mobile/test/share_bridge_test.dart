import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/native/share_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android bridge decodes upload states and the mock destination',
      () async {
    const channel = MethodChannel('com.itda.itda_mobile/local_shares');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listLocalInbox');
      return {
        'mode': 'mock',
        'account': {
          'id': 'account-a',
          'email': 'a@example.org',
        },
        'shares': [
          for (final state in LocalUploadState.values)
            {
              'local_id': 'local-${state.name}',
              'input_type': 'document',
              'label': 'notice.pdf',
              'received_at_ms': 1760000000000,
              'upload_state': state.wire,
              'can_assign': state == LocalUploadState.authenticationRequired,
            },
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final inbox = await const AndroidShareBridge().listInbox();
    expect(inbox.mode, UploadMode.mock);
    expect(inbox.account?.id, 'account-a');
    expect(inbox.shares.map((share) => share.uploadState),
        LocalUploadState.values);
    final share = inbox.shares.first;
    expect(share.localId, 'local-pending');
    expect(share.inputType, InputType.document);
    expect(share.label, 'notice.pdf');
    expect(share.receivedAt.isUtc, isTrue);
  });
}

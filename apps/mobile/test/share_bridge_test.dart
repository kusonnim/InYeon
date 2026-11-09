import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itda_mobile/models/content.dart';
import 'package:itda_mobile/native/share_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android bridge reads committed pending shares', () async {
    const channel = MethodChannel('com.itda.itda_mobile/local_shares');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listPendingShares');
      return [
        {
          'local_id': 'local-receipt',
          'input_type': 'document',
          'label': 'notice.pdf',
          'received_at_ms': 1760000000000,
          'upload_state': 'pending_upload',
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final share = (await const AndroidShareBridge().listPendingShares()).single;
    expect(share.localId, 'local-receipt');
    expect(share.inputType, InputType.document);
    expect(share.label, 'notice.pdf');
    expect(share.receivedAt.isUtc, isTrue);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/mls_core.dart';

class _FakeTransport implements MlsCommandTransport {
  String? method;
  Map<String, dynamic>? arguments;

  @override
  Future<bool> ensureLoaded() async => true;

  @override
  Map<String, dynamic> call(String method, Map<String, dynamic> arguments) {
    this.method = method;
    this.arguments = arguments;
    return {
      'ok': true,
      'result': {'device_state_b64': 'state'}
    };
  }
}

void main() {
  test('device generation uses the shared MLS command boundary', () async {
    final transport = _FakeTransport();
    final core = MlsCore(transport: transport);

    final result = await core.generateDevice(identity: [1, 2, 3]);

    expect(transport.method, 'mls_device_generate');
    expect(transport.arguments, {'identity_b64': 'AQID'});
    expect(result['device_state_b64'], 'state');
  });

  test('multi-device admission is one shared-core command', () async {
    final transport = _FakeTransport();
    final core = MlsCore(transport: transport);

    await core.addMembers(groupState: 'group', keyPackages: ['one', 'two']);

    expect(transport.method, 'mls_group_add_many');
    expect(transport.arguments, {
      'group_state_b64': 'group',
      'key_packages_b64': ['one', 'two']
    });
  });

  test('member identities are read from authenticated MLS state', () async {
    final transport = _FakeTransport();
    final core = MlsCore(transport: transport);

    await core.memberIdentities('group');

    expect(transport.method, 'mls_group_members');
    expect(transport.arguments, {'group_state_b64': 'group'});
  });

  test('member removal is delegated to the shared MLS core', () async {
    final transport = _FakeTransport();
    final core = MlsCore(transport: transport);

    await core.removeMembers(groupState: 'group', identities: ['peer']);

    expect(transport.method, 'mls_group_remove');
    expect(transport.arguments, {
      'group_state_b64': 'group',
      'identities_b64': ['peer'],
    });
  });
}

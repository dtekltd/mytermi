import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/models/host.dart';

void main() {
  test('Host JSON roundtrip', () {
    final h = Host(id: 'a1', label: 'prod', hostname: '10.0.0.5', port: 2222, username: 'ubuntu', auth: AuthMethod.key);
    final r = Host.fromJson(h.toJson());
    expect(r.hostname, '10.0.0.5');
    expect(r.port, 2222);
    expect(r.auth, AuthMethod.key);
    expect(r.address, 'ubuntu@10.0.0.5:2222');
  });

  test('displayName falls back to hostname', () {
    final h = Host(id: 'b', label: ' ', hostname: 'srv', username: 'u');
    expect(h.displayName, 'srv');
    expect(h.address, 'u@srv');
  });
}

// Live SSH test. Runs only when SSH_TEST_DIR points to a dir with `client`
// (ed25519 key, passphrase "secret") and an sshd listening on 127.0.0.1:2222.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/services/echo_check.dart';
import 'package:mytermi/services/input_tracker.dart';
import 'package:xterm/xterm.dart';

void main() {
  final dir = Platform.environment['SSH_TEST_DIR'];
  test('connect, verify host key, run shell with pty', () async {
    final pem = File('$dir/client').readAsStringSync();
    expect(SSHKeyPair.isEncryptedPem(pem), isTrue);
    final ids = SSHKeyPair.fromPem(pem, 'secret');

    String? fp;
    final client = SSHClient(
      await SSHSocket.connect('127.0.0.1', 2222, timeout: const Duration(seconds: 5)),
      username: Platform.environment['USER']!,
      identities: ids,
      onVerifyHostKey: (type, f) {
        fp = utf8.decode(f);
        return true;
      },
    );
    await client.authenticated;
    expect(fp, startsWith('SHA256:'));

    final session = await client.shell(
      pty: const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24),
    );
    final out = StringBuffer();
    session.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(out.write);
    session.resizeTerminal(120, 40);
    session.write(Uint8List.fromList(utf8.encode('echo "TERM=\$TERM COLS=\$(tput cols)"; echo grüße señor\n')));
    for (var i = 0; i < 50 && !out.toString().contains('COLS=120'); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    session.write(Uint8List.fromList(utf8.encode('exit\n')));
    await session.done.timeout(const Duration(seconds: 5));
    client.close();
    expect(out.toString(), contains('TERM=xterm-256color COLS=120'));
    expect(out.toString(), contains('grüße señor'));
  }, skip: dir == null ? 'set SSH_TEST_DIR to run' : false);

  test('wrong passphrase is rejected', () {
    if (dir == null) return;
    final pem = File('$dir/client').readAsStringSync();
    expect(() => SSHKeyPair.fromPem(pem, 'wrong'), throwsA(anything));
  });

  test('history capture against a real shell: saves commands, never hidden input', () async {
    final client = SSHClient(
      await SSHSocket.connect('127.0.0.1', 2222),
      username: Platform.environment['USER']!,
      identities: SSHKeyPair.fromPem(File('$dir/client').readAsStringSync(), 'secret'),
      onVerifyHostKey: (_, _) => true,
    );
    final term = Terminal()..resize(80, 24);
    final session = await client.shell(pty: const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24));
    session.stdout.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(term.write);
    final tracker = InputLineTracker();
    final saved = <String>[];
    Future<void> settle() => Future.delayed(const Duration(milliseconds: 400));

    // Same flow as TerminalScreen._send
    Future<void> type(String s) async {
      for (final cmd in tracker.feed(s)) {
        if (echoedAtCursor(term, cmd)) saved.add(cmd);
      }
      session.write(Uint8List.fromList(utf8.encode(s)));
      await settle();
    }

    await Future.delayed(const Duration(seconds: 1)); // prompt
    await type('echo hello-mytermi');
    await type('\r');
    await type("read -s -p 'Password: ' pw");
    await type('\r');
    await type('hunter2');
    await type('\r');
    await type(r'echo "got ${#pw} chars"');
    await type('\r');
    await type('tput smcup');
    await type('\r');
    final altOn = term.isUsingAltBuffer;
    await type('tput rmcup');
    await type('\r');

    session.write(Uint8List.fromList(utf8.encode('exit\n')));
    await session.done.timeout(const Duration(seconds: 5));
    client.close();

    expect(altOn, isTrue, reason: 'alt screen detection');
    expect(saved, contains('echo hello-mytermi'));
    expect(saved, contains("read -s -p 'Password: ' pw"));
    expect(saved, contains(r'echo "got ${#pw} chars"'));
    expect(saved, isNot(contains('hunter2')));
  }, skip: dir == null ? 'set SSH_TEST_DIR to run' : false);
}

import 'dart:convert';

import 'package:aves/services/common/services.dart';
import 'package:aves/services/security_service.dart';
import 'package:aves/sftp/model/sftp_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // `securityService` resolves the registered service once, so the fake is registered once and reset between tests
  final security = FakeSecurityService();

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    getIt.registerSingleton<SecurityService>(security);
  });

  tearDownAll(() async {
    await getIt.reset();
  });

  setUp(() async {
    security.values.clear();
    SharedPreferences.setMockInitialValues({});
    await sftpHosts.init();
  });

  Future<SftpHost> addHost({String name = 'nas', String secret = 'hunter2'}) => sftpHosts.add(
    name: name,
    host: '192.168.1.10',
    port: 22,
    username: 'user',
    authType: SftpAuthType.password,
    directory: '/data/photos',
    secret: secret,
  );

  Future<List<Map<String, dynamic>>> storedHosts() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString('sftp_hosts');
    return jsonString == null ? [] : (jsonDecode(jsonString) as List).cast<Map<String, dynamic>>();
  }

  group('SftpHost', () {
    test('round trips through a map', () {
      const host = SftpHost(
        id: 'abc',
        name: 'nas',
        host: 'example.org',
        port: 2222,
        username: 'user',
        authType: SftpAuthType.privateKey,
        directory: '/srv/pics',
        hostKeyFingerprint: 'SHA256:AAAA',
      );
      final clone = SftpHost.fromMap(host.toMap());

      expect(clone.id, host.id);
      expect(clone.name, host.name);
      expect(clone.host, host.host);
      expect(clone.port, host.port);
      expect(clone.username, host.username);
      expect(clone.authType, host.authType);
      expect(clone.directory, host.directory);
      expect(clone.hostKeyFingerprint, host.hostKeyFingerprint);
    });

    test('copies with changes, keeping the id', () {
      const host = SftpHost(
        id: 'abc',
        name: 'nas',
        host: 'example.org',
        port: 22,
        username: 'user',
        authType: SftpAuthType.password,
        directory: '/srv/pics',
      );
      final copy = host.copyWith(port: 2222, hostKeyFingerprint: 'SHA256:BBBB');

      expect(copy.id, 'abc');
      expect(copy.port, 2222);
      expect(copy.name, 'nas');
      expect(copy.hostKeyFingerprint, 'SHA256:BBBB');
      expect(host.hostKeyFingerprint, isNull);
    });

    test('falls back to password auth for an unknown auth type', () {
      final host = SftpHost.fromMap({
        'id': 'abc',
        'name': 'nas',
        'host': 'example.org',
        'port': 22,
        'username': 'user',
        'authType': 'smartcard',
        'directory': '/srv/pics',
      });

      expect(host.authType, SftpAuthType.password);
    });
  });

  group('SftpHosts', () {
    test('starts empty', () {
      expect(sftpHosts.all, isEmpty);
      expect(sftpHosts.byId('whatever'), isNull);
    });

    test('adds a host with a generated id', () async {
      final host = await addHost();

      expect(host.id, isNotEmpty);
      expect(host.hostKeyFingerprint, isNull);
      expect(sftpHosts.all, [host]);
      expect(sftpHosts.byId(host.id)?.name, 'nas');
    });

    test('generates distinct ids', () async {
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        ids.add((await addHost(name: 'host $i')).id);
      }

      expect(ids, hasLength(20));
    });

    test('persists host definitions without secrets', () async {
      final host = await addHost(secret: 'super-secret');
      final rows = await storedHosts();

      expect(rows, hasLength(1));
      expect(rows.first['id'], host.id);
      expect(rows.first['name'], 'nas');
      expect(rows.first['port'], 22);
      expect(rows.first['authType'], 'password');
      expect(jsonEncode(rows), isNot(contains('super-secret')));
    });

    test('stores the secret via the security service', () async {
      final host = await addHost(secret: 'super-secret');

      expect(security.values['sftp_secret_${host.id}'], 'super-secret');
      expect(await sftpHosts.getSecret(host.id), 'super-secret');
      expect(await sftpHosts.getSecret('unknown'), isNull);
    });

    test('reloads persisted hosts', () async {
      final host = await addHost();
      await sftpHosts.setFingerprint(host.id, 'SHA256:CCCC');

      await sftpHosts.init();

      expect(sftpHosts.all, hasLength(1));
      final reloaded = sftpHosts.byId(host.id)!;
      expect(reloaded.name, 'nas');
      expect(reloaded.directory, '/data/photos');
      expect(reloaded.hostKeyFingerprint, 'SHA256:CCCC');
    });

    test('updates a host, keeping the secret when none is given', () async {
      final host = await addHost(secret: 'old-pass');

      await sftpHosts.update(host.copyWith(name: 'renamed', port: 2222));

      expect(sftpHosts.byId(host.id)?.name, 'renamed');
      expect(sftpHosts.byId(host.id)?.port, 2222);
      expect(await sftpHosts.getSecret(host.id), 'old-pass');
      expect((await storedHosts()).first['name'], 'renamed');
    });

    test('updates the secret when given', () async {
      final host = await addHost(secret: 'old-pass');

      await sftpHosts.update(host, secret: 'new-pass');

      expect(await sftpHosts.getSecret(host.id), 'new-pass');
    });

    test('ignores updates of unknown hosts', () async {
      await addHost();
      const unknown = SftpHost(
        id: 'nope',
        name: 'ghost',
        host: 'example.org',
        port: 22,
        username: 'user',
        authType: SftpAuthType.password,
        directory: '/',
      );

      await sftpHosts.update(unknown);

      expect(sftpHosts.all, hasLength(1));
      expect(sftpHosts.byId('nope'), isNull);
    });

    test('pins a fingerprint', () async {
      final host = await addHost();

      await sftpHosts.setFingerprint(host.id, 'SHA256:DDDD');

      expect(sftpHosts.byId(host.id)?.hostKeyFingerprint, 'SHA256:DDDD');
      expect((await storedHosts()).first['hostKeyFingerprint'], 'SHA256:DDDD');
    });

    test('removes a host and its secret', () async {
      final host = await addHost();
      final other = await addHost(name: 'other');

      await sftpHosts.remove(host.id);

      expect(sftpHosts.all.map((v) => v.id), [other.id]);
      expect(await sftpHosts.getSecret(host.id), isNull);
      expect(security.values.containsKey('sftp_secret_${host.id}'), isFalse);
      expect(await storedHosts(), hasLength(1));
    });

    test('notifies listeners on add, update, fingerprint and remove', () async {
      var notified = 0;
      void listener() => notified++;
      sftpHosts.addListener(listener);
      addTearDown(() => sftpHosts.removeListener(listener));

      final host = await addHost();
      expect(notified, 1);

      await sftpHosts.update(host.copyWith(name: 'renamed'));
      expect(notified, 2);

      await sftpHosts.setFingerprint(host.id, 'SHA256:EEEE');
      expect(notified, 3);

      await sftpHosts.remove(host.id);
      expect(notified, 4);

      await sftpHosts.remove('unknown');
      expect(notified, 4);
    });

    test('exposes an unmodifiable list', () async {
      await addHost();

      expect(() => sftpHosts.all.clear(), throwsUnsupportedError);
    });
  });
}

class FakeSecurityService implements SecurityService {
  final Map<String, Object?> values = {};

  @override
  Future<bool> writeValue<T>(String key, T? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<T?> readValue<T>(String key) async => values[key] as T?;
}

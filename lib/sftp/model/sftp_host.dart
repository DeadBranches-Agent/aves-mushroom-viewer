import 'dart:convert';
import 'dart:math';

import 'package:aves/services/common/services.dart';
import 'package:aves_utils/aves_utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final SftpHosts sftpHosts = SftpHosts._private();

enum SftpAuthType { password, privateKey }

// immutable configuration of one remote SFTP host + directory to browse
class SftpHost {
  final String id; // stable unique id, generated once on creation
  final String name; // unique display name; also names the synthetic album directory
  final String host;
  final int port;
  final String username;
  final SftpAuthType authType;
  final String directory; // absolute remote directory to browse
  final String? hostKeyFingerprint; // pinned SHA-256 fingerprint (base64), null until first successful connection

  const SftpHost({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    required this.directory,
    this.hostKeyFingerprint,
  });

  SftpHost copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    SftpAuthType? authType,
    String? directory,
    String? hostKeyFingerprint,
  }) => SftpHost(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    authType: authType ?? this.authType,
    directory: directory ?? this.directory,
    hostKeyFingerprint: hostKeyFingerprint ?? this.hostKeyFingerprint,
  );

  factory SftpHost.fromMap(Map<String, dynamic> map) => SftpHost(
    id: map['id'] as String,
    name: map['name'] as String,
    host: map['host'] as String,
    port: map['port'] as int,
    username: map['username'] as String,
    authType: SftpAuthType.values.safeByName(map['authType'] as String?) ?? .password,
    directory: map['directory'] as String,
    hostKeyFingerprint: map['hostKeyFingerprint'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'authType': authType.name,
    'directory': directory,
    'hostKeyFingerprint': hostKeyFingerprint,
  };
}

// registry of configured hosts.
// host definitions (no secrets) are stored as a JSON list in shared preferences.
// secrets (password or private key PEM) are stored via `securityService`
// (keystore-backed encrypted preferences), keyed by `_secretKey(id)`.
class SftpHosts with ChangeNotifier {
  static const _prefKey = 'sftp_hosts';

  List<SftpHost> _rows = [];

  static final _random = Random();

  SftpHosts._private();

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_prefKey);
    _rows = jsonString == null ? [] : (jsonDecode(jsonString) as List).map((v) => SftpHost.fromMap(v as Map<String, dynamic>)).toList();
  }

  List<SftpHost> get all => List.unmodifiable(_rows);

  SftpHost? byId(String id) => _rows.firstWhereOrNull((v) => v.id == id);

  // generates the id; returns the created host
  Future<SftpHost> add({
    required String name,
    required String host,
    required int port,
    required String username,
    required SftpAuthType authType,
    required String directory,
    required String secret,
  }) async {
    final row = SftpHost(
      id: _newId(),
      name: name,
      host: host,
      port: port,
      username: username,
      authType: authType,
      directory: directory,
    );

    _rows = [..._rows, row];
    await _store();
    await securityService.writeValue(_secretKey(row.id), secret);

    notifyListeners();
    return row;
  }

  // replaces the host with the same id; updates the secret when `secret` is non-null
  Future<void> update(SftpHost host, {String? secret}) async {
    final index = _rows.indexWhere((v) => v.id == host.id);
    if (index == -1) return;

    _rows = List.of(_rows)..[index] = host;
    await _store();
    if (secret != null) {
      await securityService.writeValue(_secretKey(host.id), secret);
    }

    notifyListeners();
  }

  // removes the host definition and its secret
  Future<void> remove(String id) async {
    if (byId(id) == null) return;

    _rows = _rows.where((v) => v.id != id).toList();
    await _store();
    await securityService.writeValue<String>(_secretKey(id), null);

    notifyListeners();
  }

  // password or private key PEM
  Future<String?> getSecret(String id) => securityService.readValue<String>(_secretKey(id));

  Future<void> setFingerprint(String id, String fingerprint) async {
    final host = byId(id);
    if (host == null) return;

    await update(host.copyWith(hostKeyFingerprint: fingerprint));
  }

  Future<void> _store() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(_rows.map((v) => v.toMap()).toList()));
  }

  static String _secretKey(String id) => 'sftp_secret_$id';

  static String _newId() {
    final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final suffix = _random.nextInt(1 << 32).toRadixString(36).padLeft(7, '0');
    return '$micros$suffix';
  }
}

import 'package:aves/sftp/prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('delete-to-remote-trash defaults on, persists when toggled', () async {
    SharedPreferences.setMockInitialValues({});
    await sftpPrefs.init();
    expect(sftpPrefs.deleteToRemoteTrash, true);

    sftpPrefs.deleteToRemoteTrash = false;
    expect(sftpPrefs.deleteToRemoteTrash, false);

    await sftpPrefs.init();
    expect(sftpPrefs.deleteToRemoteTrash, false);
  });

  test('stored value is read back on init', () async {
    SharedPreferences.setMockInitialValues({'sftp_delete_to_trash': false});
    await sftpPrefs.init();
    expect(sftpPrefs.deleteToRemoteTrash, false);
  });
}

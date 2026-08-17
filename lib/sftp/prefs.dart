import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final SftpPrefs sftpPrefs = SftpPrefs._private();

// user-tunable settings of the sftp module: viewer prefetch window (how many
// full-size images are kept resident around the current one) and delete behavior
class SftpPrefs with ChangeNotifier {
  static const _aheadKey = 'sftp_prefetch_ahead';
  static const _behindKey = 'sftp_prefetch_behind';
  static const _deleteToTrashKey = 'sftp_delete_to_trash';
  static const defaultPrefetchAhead = 3;
  static const defaultPrefetchBehind = 1;
  // moving to a remote `.trash` is recoverable server-side, so it is the safe
  // default, mirroring the app's own recycle bin being on by default
  static const defaultDeleteToRemoteTrash = true;

  late SharedPreferences _prefs;
  int _prefetchAhead = defaultPrefetchAhead;
  int _prefetchBehind = defaultPrefetchBehind;
  bool _deleteToRemoteTrash = defaultDeleteToRemoteTrash;

  SftpPrefs._private();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _prefetchAhead = _prefs.getInt(_aheadKey) ?? defaultPrefetchAhead;
    _prefetchBehind = _prefs.getInt(_behindKey) ?? defaultPrefetchBehind;
    _deleteToRemoteTrash = _prefs.getBool(_deleteToTrashKey) ?? defaultDeleteToRemoteTrash;
  }

  int get prefetchAhead => _prefetchAhead;

  set prefetchAhead(int value) {
    _prefetchAhead = value;
    _prefs.setInt(_aheadKey, value);
    notifyListeners();
  }

  int get prefetchBehind => _prefetchBehind;

  set prefetchBehind(int value) {
    _prefetchBehind = value;
    _prefs.setInt(_behindKey, value);
    notifyListeners();
  }

  bool get deleteToRemoteTrash => _deleteToRemoteTrash;

  set deleteToRemoteTrash(bool value) {
    _deleteToRemoteTrash = value;
    _prefs.setBool(_deleteToTrashKey, value);
    notifyListeners();
  }
}

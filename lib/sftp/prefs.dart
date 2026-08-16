import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final SftpPrefs sftpPrefs = SftpPrefs._private();

// user-tunable prefetch window for the viewer: how many full-size images
// are kept resident ahead of and behind the current one
class SftpPrefs with ChangeNotifier {
  static const _aheadKey = 'sftp_prefetch_ahead';
  static const _behindKey = 'sftp_prefetch_behind';
  static const defaultPrefetchAhead = 3;
  static const defaultPrefetchBehind = 1;

  late SharedPreferences _prefs;
  int _prefetchAhead = defaultPrefetchAhead;
  int _prefetchBehind = defaultPrefetchBehind;

  SftpPrefs._private();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _prefetchAhead = _prefs.getInt(_aheadKey) ?? defaultPrefetchAhead;
    _prefetchBehind = _prefs.getInt(_behindKey) ?? defaultPrefetchBehind;
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
}

import 'dart:async';
import 'dart:io';

import 'package:aves/l10n/l10n.dart';
import 'package:aves/sftp/connection.dart';

// user-facing message for an error raised while connecting to or listing an SFTP host
String sftpErrorMessage(AppLocalizations l10n, Object error) {
  switch (error) {
    case SftpHostKeyMismatchException e:
      return l10n.settingsSftpHostKeyChangedFeedback(e.actualFingerprint);
    case SftpHostKeyUnknownException _:
      return l10n.settingsSftpHostKeyUnknownFeedback;
    case TimeoutException _:
      return l10n.settingsSftpConnectionTimeoutFeedback;
    case SocketException _:
      return l10n.settingsSftpConnectionRefusedFeedback;
    default:
      // authentication failures are raised by the SSH client library,
      // matched by type name to keep widget code independent from it
      return error.runtimeType.toString().startsWith('SSHAuth') ? l10n.settingsSftpAuthenticationFailedFeedback : l10n.genericFailureFeedback;
  }
}

import 'package:aves/services/common/channel.dart';

// at targetSdk 37 (Android 17), reaching devices on the local network requires
// the `ACCESS_LOCAL_NETWORK` runtime permission
const _platform = AvesMethodChannel('deckers.thibault/aves/sftp_permission');

// asks for the platform permission required to reach hosts on the local network,
// and returns whether it is granted. asking again when it is already granted is a no-op.
Future<bool> requestLocalNetworkPermission() async {
  final granted = await _platform.invokeMethod('requestLocalNetworkPermission');
  return granted == true;
}

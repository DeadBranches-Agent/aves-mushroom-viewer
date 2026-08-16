package deckers.thibault.aves.channel.calls

import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// requests the `ACCESS_LOCAL_NETWORK` runtime permission, mandatory at targetSdk 37
// (Android 17) for reaching SFTP hosts on the local network
class SftpPermissionHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestLocalNetworkPermission" -> requestLocalNetworkPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun requestLocalNetworkPermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(activity, PERMISSION) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        pendingResult?.success(false)
        pendingResult = result
        ActivityCompat.requestPermissions(activity, arrayOf(PERMISSION), REQUEST_CODE)
    }

    companion object {
        const val CHANNEL = "deckers.thibault/aves/sftp_permission"
        const val PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
        private const val REQUEST_CODE = 927

        private var pendingResult: MethodChannel.Result? = null

        fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
            if (requestCode != REQUEST_CODE) return false
            pendingResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingResult = null
            return true
        }
    }
}

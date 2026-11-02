package com.aseman.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.tasks.Task
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A FragmentActivity: the embedded Godot engine behind Scene3D
// (packages/elpian_godot_native) runs in a fragment.
//
// Push: MethodChannel "aseman/push_notifications". Adding
// android/app/google-services.json (and applying the Google Services Gradle
// plugin) initializes Firebase so FCM tokens become available; without it
// requestToken / currentToken return null gracefully.
class MainActivity : FlutterFragmentActivity() {
    private val pushChannel = "aseman/push_notifications"
    private var pendingTokenResult: MethodChannel.Result? = null
    private var cachedToken: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pushChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestToken" -> requestFcmToken(result)
                    "currentToken" -> result.success(cachedToken)
                    "unregister" -> {
                        cachedToken = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestFcmToken(result: MethodChannel.Result) {
        if (pendingTokenResult != null) {
            result.error(
                "request_in_progress",
                "A push-token request is already active",
                null,
            )
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingTokenResult = result
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_POST_NOTIFICATIONS,
            )
            return
        }
        fetchFcmToken(result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_POST_NOTIFICATIONS) return
        val result = pendingTokenResult
        pendingTokenResult = null
        // Still attempt a token when notification permission was denied.
        if (result != null) fetchFcmToken(result)
    }

    /// Tries FirebaseMessaging via reflection so the app builds and runs when
    /// Firebase / google-services.json is not configured.
    @Suppress("UNCHECKED_CAST")
    private fun fetchFcmToken(result: MethodChannel.Result) {
        try {
            val appClass = Class.forName("com.google.firebase.FirebaseApp")
            val getApps =
                appClass.getMethod("getApps", android.content.Context::class.java)
            val apps = getApps.invoke(null, applicationContext) as? List<*>
            if (apps == null || apps.isEmpty()) {
                result.success(null)
                return
            }
            val messagingClass =
                Class.forName("com.google.firebase.messaging.FirebaseMessaging")
            val instance = messagingClass.getMethod("getInstance").invoke(null)
            val task =
                messagingClass.getMethod("getToken").invoke(instance) as Task<String>
            task.addOnCompleteListener { t ->
                if (!t.isSuccessful) {
                    result.success(null)
                    return@addOnCompleteListener
                }
                val token = t.result
                cachedToken = token
                result.success(token)
            }
        } catch (_: ClassNotFoundException) {
            result.success(null)
        } catch (_: Throwable) {
            result.success(null)
        }
    }

    companion object {
        private const val REQ_POST_NOTIFICATIONS = 0x4153 // "AS"
    }
}

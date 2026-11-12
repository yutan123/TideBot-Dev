package com.yutan123.tideplugin

import android.app.Service
import android.content.Intent
import android.os.*
import android.os.Process
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** One bound owner and one QuickJS worker per OS process. Never runs application main(). */
open class PluginProcessService : Service() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var owner: Messenger? = null
    private val reader = Wire.Reader()
    private val handler = Handler(Looper.getMainLooper())
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        try {
            val reply = message.replyTo ?: error("Missing owner")
            check(owner == null || owner!!.binder == reply.binder)
            if (owner == null) {
                owner = reply
                reply.binder.linkToDeath({ handler.post { terminate() } }, 0)
            }
            reader.read(message, { text ->
                try { receive(text) } catch (_: Exception) { terminate() }
            }, { terminate() })
        } catch (_: Exception) { terminate() }
        true
    })
    override fun onBind(intent: Intent): IBinder = messenger.binder
    private fun receive(text: String) {
        val json = JSONObject(text)
        when (json.getString("op")) {
            "start" -> {
                check(engine == null)
                Wire.send(owner!!, JSONObject().put("type", "process").put("pid", Process.myPid()).toString())
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)
                // Do not register application plugins in an untrusted execution process.
                val flutter = FlutterEngine(applicationContext, null, false)
                engine = flutter
                val bridge = MethodChannel(flutter.dartExecutor.binaryMessenger, "tidebot.plugin.worker")
                channel = bridge
                bridge.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "boot" -> result.success(text)
                        "event" -> {
                            try { Wire.send(owner!!, call.arguments as String); result.success(null) }
                            catch (_: Exception) { result.error("ipc", "Owner unavailable", null); terminate() }
                        }
                        else -> result.notImplemented()
                    }
                }
                flutter.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(), "package:tide_bot/main.dart", "tidePluginProcessMain"))
            }
            "close" -> terminate()
            else -> channel?.invokeMethod("command", text)
        }
    }
    private fun terminate() {
        // Do not wait for a hung FFI thread or native destructor.
        Process.killProcess(Process.myPid())
    }
    override fun onUnbind(intent: Intent): Boolean { terminate(); return false }
}
class PluginSlot0 : PluginProcessService()
class PluginSlot1 : PluginProcessService()
class PluginSlot2 : PluginProcessService()
class PluginSlot3 : PluginProcessService()
class PluginSlot4 : PluginProcessService()
class PluginSlot5 : PluginProcessService()
class PluginSlot6 : PluginProcessService()
class PluginSlot7 : PluginProcessService()

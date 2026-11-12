package com.yutan123.tideplugin

import android.content.*
import android.os.*
import android.os.Process
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Auto-registered for UI and headless Flutter engines. Slots are shared by all engines. */
class TidePluginProcessPlugin : FlutterPlugin {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var coordination: MethodChannel
    private val sessions = mutableMapOf<String, Session>()
    private val handler = Handler(Looper.getMainLooper())
    companion object { private val slots = arrayOfNulls<String>(8) }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "tidebot.plugin.process")
        coordination = MethodChannel(binding.binaryMessenger, "tidebot.plugin.coordination")
        PluginCoordination.attach(this) { id, epoch ->
            sessions.values.toList().filter { it.pluginId == id }.forEach { it.finish(false) }
            coordination.invokeMethod("invalidated", mapOf("id" to id, "epoch" to epoch))
        }
        coordination.setMethodCallHandler { call, result ->
            try {
                val args = call.arguments as Map<*, *>
                when (call.method) {
                    "acquire" -> PluginCoordination.acquire(this, args["key"] as String, args["ticket"] as String, result)
                    "release" -> { PluginCoordination.release(this, args["key"] as String, args["ticket"] as String); result.success(null) }
                    "epoch" -> result.success(PluginCoordination.epoch(args["id"] as String))
                    "invalidate" -> { PluginCoordination.invalidate(args["id"] as String); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("plugin_coordination", e.message, null) }
        }
        channel.setMethodCallHandler { call, result ->
            try {
                val text = call.arguments as String
                val json = JSONObject(text)
                val token = json.getString("token")
                when (call.method) {
                    "open" -> {
                        check(!sessions.containsKey(token))
                        val slot = synchronized(slots) {
                            val free = slots.indexOfFirst { it == null }
                            check(free >= 0) { "插件独立进程已达上限（8 个）" }
                            slots[free] = token; free
                        }
                        val session = Session(token, slot, text)
                        sessions[token] = session
                        try { session.bind(); result.success(null) }
                        catch (e: Exception) { session.finish(false); throw e }
                    }
                    "send" -> {
                        val session = sessions[token] ?: error("Plugin stopped")
                        Wire.send(session.remote ?: error("Plugin not connected"), text, session.inbox)
                        result.success(null)
                    }
                    "close" -> { sessions[token]?.finish(false); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("plugin_process", e.message, null) }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        sessions.values.toList().forEach { it.finish(false) }
        channel.setMethodCallHandler(null)
        coordination.setMethodCallHandler(null)
        PluginCoordination.detach(this)
    }
    private inner class Session(val token: String, val slot: Int, val start: String) : ServiceConnection {
        val pluginId: String = JSONObject(start).optString("pluginId")
        var remote: Messenger? = null
        private var pid: Int? = null
        private var bound = false
        private var done = false
        private val reader = Wire.Reader()
        private val deadline = Runnable { finish(true) }
        val inbox = Messenger(Handler(Looper.getMainLooper()) { message ->
            try {
                reader.read(message, { text ->
                    if (done) return@read
                    val event = JSONObject(text)
                    if (event.optString("type") == "process") {
                        pid = event.getInt("pid")
                        return@read
                    }
                    if (event.optString("type") == "ready") {
                        handler.removeCallbacks(deadline)
                    }
                    event.put("token", token)
                    channel.invokeMethod("event", event.toString())
                }, { finish(true) })
            } catch (_: Exception) { finish(true) }
            true
        })
        fun bind() {
            val intent = Intent().setClassName(context, "com.yutan123.tideplugin.PluginSlot$slot")
            bound = context.bindService(intent, this, Context.BIND_AUTO_CREATE)
            check(bound) { "Cannot bind plugin process" }
            handler.postDelayed(deadline, 15000)
        }
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            try {
                remote = Messenger(binder)
                binder.linkToDeath({ handler.post {
                    finish(true)
                    synchronized(slots) { if (slots[slot] == token) slots[slot] = null }
                } }, 0)
                if (done) retire() else Wire.send(remote!!, start, inbox)
            } catch (_: Exception) {
                finish(true)
                synchronized(slots) { if (slots[slot] == token) slots[slot] = null }
            }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            finish(true)
            if (bound) runCatching { context.unbindService(this) }
            bound = false
            synchronized(slots) { if (slots[slot] == token) slots[slot] = null }
        }
        override fun onBindingDied(name: ComponentName) = onServiceDisconnected(name)
        override fun onNullBinding(name: ComponentName) = onServiceDisconnected(name)
        private fun retire() {
            // SIGKILL does not depend on Dart, an FFI interrupt, or destructor progress.
            pid?.let { if (it != Process.myPid()) Process.killProcess(it) }
            runCatching { remote?.let { Wire.send(it, JSONObject().put("op", "close").toString(), inbox) } }
            if (bound) runCatching { context.unbindService(this) }
            bound = false
            // Slot is released only on Binder death, never while an old engine still lives.
        }
        fun finish(failed: Boolean) {
            if (done) return
            done = true
            handler.removeCallbacks(deadline)
            reader.close()
            if (remote != null) retire()
            else if (!bound) synchronized(slots) { if (slots[slot] == token) slots[slot] = null }
            // If binding is still pending, onServiceConnected retires the late process.
            sessions.remove(token)
            if (failed) channel.invokeMethod("event", JSONObject()
                .put("token", token).put("type", "fatal")
                .put("error", "插件独立进程退出或启动超时").toString())
        }
    }
}

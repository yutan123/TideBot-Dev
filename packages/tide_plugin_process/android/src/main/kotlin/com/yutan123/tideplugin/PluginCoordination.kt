package com.yutan123.tideplugin

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/** Main-looper ownership: shared by every Flutter engine in the application process. */
internal object PluginCoordination {
    private data class Waiter(val owner: Any, val ticket: String, val result: MethodChannel.Result, var active: Boolean = true)
    private class Lock {
        var holder: Waiter? = null
        val waiting = ArrayDeque<Waiter>()
    }

    private val handler = Handler(Looper.getMainLooper())
    private val locks = mutableMapOf<String, Lock>()
    private val generations = mutableMapOf<String, Long>()
    private val listeners = mutableMapOf<Any, (String, Long) -> Unit>()

    fun attach(owner: Any, listener: (String, Long) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        listeners[owner] = listener
    }

    fun acquire(owner: Any, key: String, ticket: String, result: MethodChannel.Result) {
        check(Looper.myLooper() == Looper.getMainLooper())
        require(key == "lifecycle" || key.startsWith("storage:") || key.startsWith("chat:"))
        val lock = locks.getOrPut(key) { Lock() }
        val waiter = Waiter(owner, ticket, result)
        if (lock.holder == null) {
            lock.holder = waiter
            result.success(null)
        } else {
            lock.waiting.addLast(waiter)
        }
    }

    fun release(owner: Any, key: String, ticket: String) {
        check(Looper.myLooper() == Looper.getMainLooper())
        val lock = locks[key] ?: return
        check(lock.holder?.owner === owner && lock.holder?.ticket == ticket)
        advance(key, lock)
    }

    private fun advance(key: String, lock: Lock) {
        val next = lock.waiting.pollFirst()
        if (next == null) {
            lock.holder = null
            locks.remove(key)
            return
        }
        if (!next.active) {
            advance(key, lock)
            return
        }
        lock.holder = next
        try {
            next.result.success(null)
        } catch (_: Exception) {
            next.active = false
            advance(key, lock)
        }
    }

    fun epoch(id: String): Long = generations[id] ?: 0L

    fun invalidate(id: String) {
        check(Looper.myLooper() == Looper.getMainLooper())
        generations[id] = epoch(id) + 1L
        val generation = epoch(id)
        listeners.values.toList().forEach { listener ->
            try {
                listener(id, generation)
            } catch (_: Exception) {
                // One detached Flutter engine must not prevent other observers.
            }
        }
    }

    fun detach(owner: Any) {
        check(Looper.myLooper() == Looper.getMainLooper())
        listeners.remove(owner)
        locks.toMap().forEach { (key, lock) ->
            val iterator = lock.waiting.iterator()
            while (iterator.hasNext()) {
                val waiter = iterator.next()
                if (waiter.owner === owner) {
                    waiter.active = false
                    iterator.remove()
                                        handler.post { runCatching { waiter.result.error("engine_detached", "Flutter engine detached", null) } }
                }
            }
            if (lock.holder?.owner === owner) advance(key, lock)
        }
    }
}

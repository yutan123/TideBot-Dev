package com.yutan123.tideplugin

import android.os.*
import java.util.concurrent.Executors

/** Anonymous pipes keep scripts and results out of Binder's shared 1 MB buffer. */
internal object Wire {
    const val MAX = 8 * 1024 * 1024
    private val writers = Executors.newFixedThreadPool(2)
    fun send(target: Messenger, value: String, reply: Messenger? = null) {
        require(value.length <= MAX) { "Plugin message too large" }
        val pipe = ParcelFileDescriptor.createPipe()
        try {
            target.send(Message.obtain(null, 1).apply {
                replyTo = reply
                data = Bundle().apply { putParcelable("pipe", pipe[0]) }
            })
            writers.execute {
                runCatching { ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use {
                    it.write(value.toByteArray(Charsets.UTF_8))
                } }
                runCatching { pipe[1].close() }
            }
        } catch (e: Exception) {
            pipe[1].close()
            throw e
        } finally { pipe[0].close() }
    }
    class Reader {
        private val worker = Executors.newSingleThreadExecutor()
        private val main = Handler(Looper.getMainLooper())
        private val pipes = mutableSetOf<ParcelFileDescriptor>()
        private var closed = false
        @Suppress("DEPRECATION")
        fun read(message: Message, receive: (String) -> Unit, failure: () -> Unit) {
            val pipe = message.data.getParcelable<ParcelFileDescriptor>("pipe")
                ?: error("Missing plugin pipe")
            synchronized(pipes) {
                if (closed) { pipe.close(); return }
                pipes.add(pipe)
            }
            worker.execute {
                try {
                    val bytes = ParcelFileDescriptor.AutoCloseInputStream(pipe).use { stream ->
                        val out = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(16384)
                        while (true) {
                            val count = stream.read(buffer)
                            if (count < 0) break
                            require(out.size() + count <= MAX * 4) { "Plugin frame too large" }
                            out.write(buffer, 0, count)
                        }
                        out.toByteArray()
                    }
                    val value = String(bytes, Charsets.UTF_8)
                    require(value.length <= MAX)
                    main.post {
                        try { receive(value) } catch (_: Exception) { failure() }
                    }
                } catch (_: Exception) { main.post { failure() } }
                finally { synchronized(pipes) { pipes.remove(pipe) }; runCatching { pipe.close() } }
            }
        }
        fun close() {
            synchronized(pipes) {
                closed = true
                pipes.forEach { runCatching { it.close() } }
                pipes.clear()
            }
            worker.shutdownNow()
        }
    }
}

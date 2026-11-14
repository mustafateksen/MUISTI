package com.muisti.engine

import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/** A minimal local HTTP/1.1 server for tests: counts requests and answers each with [reply] (JSON, 200). */
class CountingServer(@Volatile var reply: (path: String, body: String) -> String = { _, _ -> "{}" }) : AutoCloseable {
    private val socket = ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))
    val hits = AtomicInteger()
    val bodies = java.util.concurrent.CopyOnWriteArrayList<String>()
    val port get() = socket.localPort
    val url get() = "http://127.0.0.1:$port"

    init {
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val c = runCatching { socket.accept() }.getOrNull() ?: break
                thread(isDaemon = true) {
                    c.use { s ->
                        val inp = s.getInputStream().buffered()
                        while (true) {
                            val head = StringBuilder()
                            while (!head.endsWith("\r\n\r\n")) { val b = inp.read(); if (b < 0) return@use; head.append(b.toChar()) }
                            val lines = head.lines()
                            val path = lines[0].split(" ").getOrElse(1) { "/" }
                            val len = lines.firstOrNull { it.lowercase().startsWith("content-length:") }?.substringAfter(':')?.trim()?.toInt() ?: 0
                            val body = ByteArray(len).also { var o = 0; while (o < len) { val n = inp.read(it, o, len - o); if (n < 0) break; o += n } }
                            hits.incrementAndGet(); bodies.add(String(body))
                            val out = reply(path, String(body)).toByteArray()
                            s.getOutputStream().apply {
                                write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${out.size}\r\n\r\n".toByteArray()); write(out); flush()
                            }
                        }
                    }
                }
            }
        }
    }

    override fun close() = socket.close()
}

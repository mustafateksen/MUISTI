package com.muisti.engine

import com.muisti.privacy.KeyValueStore
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Release builds carry no API key: the phone pairs once with MUISTI's token proxy (nemotron/token_proxy.py on
 * omer/nemotron-scene) using a code shown by the server, keeps the per-device secret, and fetches short-lived
 * tokens that the proxy swaps for the real key. Blocking calls: use off the main thread.
 */
class TokenClient(private val store: KeyValueStore, private val now: () -> Long = System::currentTimeMillis) {
    private val http = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).build()
    private val json = "application/json".toMediaType()
    @Volatile private var token: String? = null
    @Volatile private var expiresAt = 0L

    val proxyUrl: String get() = store.get(URL) ?: ""
    val paired: Boolean get() = !store.get(SECRET).isNullOrEmpty() && proxyUrl.isNotEmpty()

    fun deviceId(): String = store.get(DEVICE) ?: java.util.UUID.randomUUID().toString().also { store.put(DEVICE, it) }

    /** Pairs this phone with the proxy at [url] using the server's pairing code. Throws with a readable message. */
    fun pair(url: String, code: String) {
        val base = url.trim().trimEnd('/')
        val body = JSONObject().put("device_id", deviceId()).put("code", code.trim())
        val r = post("$base/proxy/pair", body)
        store.put(URL, base); store.put(SECRET, r.getString("device_secret"))
        token = null; expiresAt = 0
    }

    /** A valid token (refreshed a minute before it expires), or "" when not paired / unreachable. */
    @Synchronized
    fun token(): String {
        val t = token
        if (t != null && now() < expiresAt - 60_000) return t
        if (!paired) return ""
        return runCatching {
            val r = post("$proxyUrl/proxy/token", JSONObject().put("device_id", deviceId()).put("device_secret", store.get(SECRET)))
            token = r.getString("token"); expiresAt = now() + r.optLong("expires_in", 3600) * 1000
            token!!
        }.getOrDefault("")
    }

    private fun post(url: String, body: JSONObject): JSONObject {
        val req = Request.Builder().url(url).post(body.toString().toRequestBody(json)).build()
        http.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw RuntimeException(runCatching { JSONObject(text).optString("detail") }.getOrNull()?.ifEmpty { null } ?: "HTTP ${resp.code}")
            return JSONObject(text)
        }
    }

    companion object {
        private const val URL = "proxy_url"; private const val SECRET = "proxy_device_secret"; private const val DEVICE = "proxy_device_id"
    }
}

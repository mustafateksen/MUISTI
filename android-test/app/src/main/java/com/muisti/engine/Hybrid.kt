package com.muisti.engine

import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Reciprocal rank fusion (k = 60, as on iOS): each list adds weight / (k + rank). */
object Hybrid {
    const val K = 60.0

    fun rrf(lists: List<Pair<List<Doc>, Double>>): List<Pair<Doc, Double>> {
        val score = LinkedHashMap<Doc, Double>()
        for ((list, w) in lists) list.forEachIndexed { r, d -> score[d] = (score[d] ?: 0.0) + w / (K + r + 1) }
        return score.entries.sortedByDescending { it.value }.map { it.key to it.value }   // stable: ties keep first-seen order
    }

    /** "Close" = the two best fused scores differ by less than one rank step at the top of a single list. */
    fun close(fused: List<Pair<Doc, Double>>): Boolean =
        fused.size >= 2 && fused[0].second - fused[1].second < (1 / (K + 1) - 1 / (K + 2))
}

/**
 * nemotron-3.5-rerank through MUISTI's retrieval deployment (/classify, one pair per request, fired in parallel).
 * Scores are raw logits: only compared within one query. Null on any failure (search then keeps the fused order).
 */
class Reranker(private val keyOf: () -> String, private val urlOf: () -> String = { Embedder.DEFAULT_RETRIEVAL_URL }) {
    private val http = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(5, TimeUnit.SECONDS).build()
    var calls = 0; private set

    fun scores(query: String, docs: List<String>, timeoutMs: Long = 3000): List<Double>? {
        val key = keyOf(); if (key.isEmpty() || docs.isEmpty()) return null
        val out = arrayOfNulls<Double>(docs.size)
        val latch = CountDownLatch(docs.size)
        calls++
        for ((i, d) in docs.withIndex()) {
            val body = JSONObject().put("model", "nemotron-3.5-rerank").put("add_special_tokens", false).put("use_activation", false)
                .put("messages", JSONArray()
                    .put(JSONObject().put("role", "query").put("content", JSONArray().put(JSONObject().put("type", "text").put("text", query))))
                    .put(JSONObject().put("role", "document").put("content", JSONArray().put(JSONObject().put("type", "text").put("text", d.take(1500))))))
            val req = Request.Builder().url(urlOf().trimEnd('/') + "/classify").header("Authorization", "Bearer $key")
                .post(body.toString().toRequestBody("application/json".toMediaType())).build()
            http.newCall(req).enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) = latch.countDown()
                override fun onResponse(call: Call, response: Response) {
                    response.use { r -> if (r.isSuccessful) runCatching {
                        out[i] = JSONObject(r.body!!.string()).getJSONArray("data").getJSONObject(0).getJSONArray("probs").getDouble(0) } }
                    latch.countDown()
                }
            })
        }
        if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) return null
        return if (out.any { it == null }) null else out.map { it!! }
    }
}

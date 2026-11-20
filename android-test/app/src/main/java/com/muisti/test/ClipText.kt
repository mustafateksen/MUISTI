package com.muisti.test

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import com.muisti.engine.ClipTokenizer

/**
 * MobileCLIP-S0 text encoder on the phone (quantized ONNX + ClipTokenizer): turns "a red sofa" into a vector in the
 * same space as the image vectors the privacy gate computes. Loaded on first use (off the main thread).
 */
class ClipText(private val ctx: Context) {
    private val env = OrtEnvironment.getEnvironment()
    private val session: OrtSession? by lazy {
        runCatching { env.createSession(ctx.assets.open(MODEL).use { it.readBytes() }, OrtSession.SessionOptions().apply { setIntraOpNumThreads(2) }) }
            .onFailure { android.util.Log.w("MuistiTiming", "clip text model missing: ${it.message}") }.getOrNull()
    }
    private val tok: ClipTokenizer? by lazy { runCatching { ClipTokenizer(ctx.assets.open(TOKENIZER).bufferedReader().use { it.readText() }) }.getOrNull() }

    fun embed(text: String): FloatArray? {
        val s = session ?: return null
        val t = tok ?: return null
        val t0 = System.currentTimeMillis()
        val ids = t.inputIds(text)
        val out = OnnxTensor.createTensor(env, java.nio.LongBuffer.wrap(ids), longArrayOf(1, ClipTokenizer.CONTEXT.toLong())).use { x ->
            s.run(mapOf(s.inputNames.first() to x)).use { r -> @Suppress("UNCHECKED_CAST") (r[0].value as Array<FloatArray>)[0] }
        }
        android.util.Log.i("MuistiTiming", "clip text embed ${System.currentTimeMillis() - t0} ms")
        return out
    }

    companion object { const val MODEL = "mobileclip_s0_text_q.onnx"; const val TOKENIZER = "clip_tokenizer.json" }
}

package com.muisti.engine

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.concurrent.TimeUnit

/**
 * JSON kept as the exact text it was written as. Schemas MUST keep their key order: with
 * json_schema output the model fills fields in schema order ("answer" before "support"), and
 * org.json on the JVM reorders keys - which made the model decide "inferred" before answering.
 */
class RawJson(val text: String) {
    companion object {
        val TEXT = RawJson("{\"type\": \"text\"}")
        val JSON_OBJECT = RawJson("{\"type\": \"json_object\"}")

        /** The value of top-level [key] in [src], copied verbatim (brace matching, strings respected). */
        fun extract(src: String, key: String): RawJson {
            val k = src.indexOf("\"$key\"")
            require(k >= 0) { "missing $key" }
            var i = src.indexOf(':', k) + 1
            while (src[i].isWhitespace()) i++
            var depth = 0; var inStr = false; var esc = false
            val start = i
            while (true) {
                val c = src[i]
                if (inStr) { if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') inStr = false }
                else when (c) { '"' -> inStr = true; '{', '[' -> depth++; '}', ']' -> { depth--; if (depth == 0) return RawJson(src.substring(start, i + 1)) } }
                i++
            }
        }
    }
}

/** Image work differs on Android (Bitmap) and the JVM tests (ImageIO). */
interface Images {
    /** JPEG with the long side at most [longSide] px, quality 85 (extract.downscale). */
    fun downscale(jpeg: ByteArray, longSide: Int = 1536): ByteArray
}

class LlmConfig(val baseUrl: String, val model: String, val key: String, val embedKey: String)

/** All prompt text comes from docs/prompts.json (exported from the Python code), never copied by hand. */
class Prompts(private val json: String) {
    private val p = JSONObject(json)
    val extractionSystem: String = p.getString("EXTRACTION_SYSTEM")
    val recordSchema = RawJson.extract(json, "RECORD_SCHEMA")
    val parsePrompt: String = p.getString("PARSE_PROMPT")
    val parseSchema = RawJson.extract(json, "PARSE_SCHEMA")
    val answerPrompt: String = p.getString("ANSWER_PROMPT")
    val answerSchema = RawJson.extract(json, "ANSWER_SCHEMA")
    val lookSchema = RawJson.extract(json, "LOOK_SCHEMA")
    val lookReal: String = p.getString("LOOK_REAL")
    val lookPrinted: String = p.getString("LOOK_PRINTED")
    val lookPicture: String = p.getString("LOOK_PICTURE")
    val summaryPrompt: String = p.getString("SUMMARY_PROMPT")
    val summarySchema = RawJson.extract(json, "SUMMARY_SCHEMA")

    /** Python str.format for our templates: {name} etc., with {{ }} as literal braces. */
    fun fill(template: String, vararg kv: Pair<String, String?>): String {
        var s = template.replace("{{", "\u0001").replace("}}", "\u0002")
        for ((k, v) in kv) s = s.replace("{$k}", v ?: "None")
        return s.replace("\u0001", "{").replace("\u0002", "}")
    }
}

class BadRequest(msg: String) : Exception(msg)

/** OpenAI-compatible chat client for Nemotron (extract._call) with the same retry/backoff. */
class Llm(private val cfg: LlmConfig) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).build()
    private val jsonType = "application/json".toMediaType()

    fun imagePart(jpeg: ByteArray): JSONObject = JSONObject()
        .put("type", "image_url")
        .put("image_url", JSONObject().put("url", "data:image/jpeg;base64," + Base64.getEncoder().encodeToString(jpeg)))

    fun textPart(text: String): JSONObject = JSONObject().put("type", "text").put("text", text)

    fun schemaFormat(name: String, schema: RawJson): RawJson =
        RawJson("{\"type\": \"json_schema\", \"json_schema\": {\"name\": \"$name\", \"schema\": ${schema.text}}}")

    /** One request with backoff on 429/5xx/network errors. Reasoning stays OFF (it eats max_tokens). */
    fun call(messages: JSONArray, responseFormat: RawJson, maxTokens: Int = 800, temperature: Double = 0.2): String {
        val body = JSONObject()
            .put("model", cfg.model)
            .put("messages", messages)
            .put("temperature", temperature)
            .put("top_p", 0.95)
            .put("max_tokens", maxTokens)
            .put("chat_template_kwargs", JSONObject().put("enable_thinking", false))
        // response_format is spliced in as text so the schema's key order survives
        val bodyText = body.toString().let { it.substring(0, it.length - 1) + ", \"response_format\": " + responseFormat.text + "}" }
        var lastErr: Exception? = null
        for (attempt in 0 until 5) {
            try {
                val req = Request.Builder().url(cfg.baseUrl.trimEnd('/') + "/chat/completions")
                    .header("Authorization", "Bearer " + cfg.key)
                    .post(bodyText.toRequestBody(jsonType)).build()
                http.newCall(req).execute().use { resp ->
                    val text = resp.body?.string().orEmpty()
                    if (resp.code == 400) throw BadRequest(text.take(300))
                    if (resp.code == 429 || resp.code >= 500) throw RetryableHttp("HTTP ${resp.code}")
                    if (!resp.isSuccessful) throw RuntimeException("HTTP ${resp.code}: ${text.take(300)}")
                    val choice = JSONObject(text).getJSONArray("choices").getJSONObject(0)
                    val content = choice.getJSONObject("message").optString("content", "")
                    if (content.isEmpty() || content == "null") throw RuntimeException("empty content, finish_reason=${choice.optString("finish_reason")}")
                    return content
                }
            } catch (e: BadRequest) {
                throw e
            } catch (e: RetryableHttp) {
                lastErr = e
            } catch (e: java.io.IOException) {
                lastErr = e
            }
            Thread.sleep((minOf(30.0, Math.pow(2.0, attempt.toDouble())) * 1000 + Math.random() * 1000).toLong())
        }
        throw RuntimeException("Nemotron unavailable after retries: ${lastErr?.message}")
    }

    /** ask._json_call: schema output, falling back to json_object if the server rejects the schema. */
    fun jsonCall(system: String, user: String, schema: RawJson, name: String, maxTokens: Int = 400): JSONObject {
        val msgs = JSONArray()
            .put(JSONObject().put("role", "system").put("content", system))
            .put(JSONObject().put("role", "user").put("content", user))
        val out = try {
            call(msgs, schemaFormat(name, schema), maxTokens, 0.0)
        } catch (e: BadRequest) {
            call(msgs, RawJson.JSON_OBJECT, maxTokens, 0.0)
        }
        return JsonText.parse(out)
    }

    private class RetryableHttp(msg: String) : Exception(msg)
}

object JsonText {
    /** extract._parse_json: the outermost {...} in the model output. */
    fun parse(text: String): JSONObject {
        val a = text.indexOf('{')
        val b = text.lastIndexOf('}')
        if (a < 0 || b <= a) throw IllegalArgumentException("no JSON in model output: ${text.take(200)}")
        return JSONObject(text.substring(a, b + 1))
    }

    /** extract._repair_json: runaway output cut mid-JSON -> drop the unfinished tail and close brackets. */
    fun repair(text: String): JSONObject {
        val t = text.substring(text.indexOf('{'))
        for (cut in t.length downTo 1) {
            if (t[cut - 1] !in "}]\"0123456789el") continue
            val head = t.substring(0, cut)
            val stack = ArrayList<Char>()
            var inStr = false
            var esc = false
            for (ch in head) {
                if (inStr) {
                    esc = (ch == '\\') && !esc
                    if (ch == '"' && !esc) inStr = false
                    continue
                }
                when (ch) {
                    '"' -> inStr = true
                    '{' -> stack.add('}')
                    '[' -> stack.add(']')
                    '}', ']' -> if (stack.isNotEmpty()) stack.removeAt(stack.size - 1)
                }
            }
            if (inStr) continue
            try {
                return JSONObject(head.trimEnd(',', ' ') + stack.reversed().joinToString(""))
            } catch (_: Exception) {
            }
        }
        throw IllegalArgumentException("could not repair model JSON")
    }
}

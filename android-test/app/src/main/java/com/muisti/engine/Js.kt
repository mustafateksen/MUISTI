package com.muisti.engine

import org.json.JSONArray
import org.json.JSONObject

// Small helpers so JSONObject reads like the Python dicts it mirrors.
// org.json's optString() turns JSON null into "null" and missing into "": both are "no value" here.

/** Python `d.get(k)` for strings: null when missing, JSON null, or empty (Python falsy). */
fun JSONObject.str(key: String): String? {
    if (!has(key) || isNull(key)) return null
    val v = opt(key)
    val s = if (v is String) v else v.toString()
    return s.ifEmpty { null }
}

fun JSONObject.bool(key: String): Boolean {
    if (!has(key) || isNull(key)) return false
    return when (val v = opt(key)) {
        is Boolean -> v
        is Number -> v.toDouble() != 0.0
        is String -> v.isNotEmpty() && v != "false"
        is JSONArray -> v.length() > 0
        is JSONObject -> v.length() > 0
        else -> false
    }
}

fun JSONObject.num(key: String, def: Double = 0.0): Double {
    if (!has(key) || isNull(key)) return def
    return when (val v = opt(key)) {
        is Number -> v.toDouble()
        is String -> v.toDoubleOrNull() ?: def
        else -> def
    }
}

fun JSONObject.arr(key: String): JSONArray = if (!has(key) || isNull(key)) JSONArray() else (opt(key) as? JSONArray) ?: JSONArray()

fun JSONObject.obj(key: String): JSONObject = if (!has(key) || isNull(key)) JSONObject() else (opt(key) as? JSONObject) ?: JSONObject()

fun JSONArray.objects(): List<JSONObject> = (0 until length()).mapNotNull { optJSONObject(it) }

fun JSONArray.strings(): List<String> = (0 until length()).mapNotNull { i ->
    if (isNull(i)) null else opt(i)?.toString()
}

fun JSONObject.copy(): JSONObject = JSONObject(toString())

fun nullable(v: Any?): Any = v ?: JSONObject.NULL

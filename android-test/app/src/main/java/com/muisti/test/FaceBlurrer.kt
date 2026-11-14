package com.muisti.test

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.RectF
import android.graphics.Shader
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.PoseLandmark
import com.google.mlkit.vision.pose.defaults.PoseDetectorOptions
import java.util.concurrent.TimeUnit
import kotlin.math.hypot

/**
 * Android port of Ahmet's FaceBlurrer.swift: heads are masked BEFORE a frame leaves the phone
 * or is stored. Same rules:
 *  - detect heads with a face detector + body pose (nose/eyes/ears, else neck+shoulders),
 *  - small frames are scanned at 2x, as the whole frame plus 4 overlapping 60% tiles,
 *  - overlapping boxes are merged (without growing into giant blocks that would hide signs),
 *  - mask = soft ellipse, cover = pixellate THEN blur (cannot be undone),
 *  - any detection error -> null: the caller must DROP the frame (fail-safe).
 * Apple Vision -> Google ML Kit (on device). ML Kit has no upper-body detector; pose covers that.
 * Call from a background thread.
 */
class FaceBlurrer(private val padding: Float = 0.3f) {

    class Result(val image: Bitmap, val faceCount: Int)

    private val faces = FaceDetection.getClient(FaceDetectorOptions.Builder()
        .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
        .setMinFaceSize(0.05f)
        .build())
    private val pose = PoseDetection.getClient(PoseDetectorOptions.Builder()
        .setDetectorMode(PoseDetectorOptions.SINGLE_IMAGE_MODE).build())

    fun close() { faces.close(); pose.close() }

    fun process(src: Bitmap): Result? {
        val heads = findHeads(src) ?: return null
        val out = apply(heads, src) ?: return null
        return Result(out, heads.size)
    }

    /** Head boxes in [src] pixels; null if any detection failed (fail-safe). */
    fun findHeads(src: Bitmap): List<RectF>? {
        val scale = if (minOf(src.width, src.height) < 1000) 2f else 1f
        val img = if (scale != 1f) Bitmap.createScaledBitmap(src, (src.width * scale).toInt(), (src.height * scale).toInt(), true) else src
        val fw = img.width.toFloat(); val fh = img.height.toFloat()
        val regions = mutableListOf(RectF(0f, 0f, fw, fh))
        for ((fx, fy) in listOf(0f to 0f, 0.4f to 0f, 0f to 0.4f, 0.4f to 0.4f))
            regions.add(RectF(fw * fx, fh * fy, fw * fx + fw * 0.6f, fh * fy + fh * 0.6f))
        val rects = ArrayList<RectF>()
        for (r in regions) rects += detect(img, r) ?: return null
        val bounds = RectF(0f, 0f, src.width.toFloat(), src.height.toFloat())
        val mapped = rects.mapNotNull {
            val m = RectF(it.left / scale, it.top / scale, it.right / scale, it.bottom / scale)
            if (m.intersect(bounds) && m.width() > 0 && m.height() > 0) m else null
        }
        return mergeDuplicates(mapped)
    }

    private fun detect(img: Bitmap, region: RectF): List<RectF>? {
        val crop = Bitmap.createBitmap(img, region.left.toInt(), region.top.toInt(),
            region.width().toInt().coerceAtMost(img.width - region.left.toInt()),
            region.height().toInt().coerceAtMost(img.height - region.top.toInt()))
        val input = InputImage.fromBitmap(crop, 0)
        return try {
            val fs = Tasks.await(faces.process(input), 10, TimeUnit.SECONDS)
            val p = Tasks.await(pose.process(input), 10, TimeUnit.SECONDS)
            val out = ArrayList<RectF>()
            for (f in fs) {
                val b = RectF(f.boundingBox)
                b.inset(-b.width() * padding, -b.height() * padding)
                b.offset(region.left, region.top)
                out.add(b)
            }
            headFromPose(p, crop.width, crop.height)?.let { it.offset(region.left, region.top); out.add(it) }
            out
        } catch (e: Exception) {
            null
        }
    }

    /** Ahmet's headFromPose: face points if any, else neck (shoulder midpoint) + shoulders. */
    private fun headFromPose(p: com.google.mlkit.vision.pose.Pose, w: Int, h: Int): RectF? {
        fun pt(type: Int): PointF? = p.getPoseLandmark(type)?.takeIf { it.inFrameLikelihood > 0.5f }?.position
        val face = listOf(PoseLandmark.NOSE, PoseLandmark.LEFT_EYE, PoseLandmark.RIGHT_EYE,
            PoseLandmark.LEFT_EAR, PoseLandmark.RIGHT_EAR).mapNotNull { pt(it) }
        val ls = pt(PoseLandmark.LEFT_SHOULDER); val rs = pt(PoseLandmark.RIGHT_SHOULDER)
        val sw = if (ls != null && rs != null) hypot(ls.x - rs.x, ls.y - rs.y) else null
        val neck = if (ls != null && rs != null) PointF((ls.x + rs.x) / 2, (ls.y + rs.y) / 2) else null
        val cx: Float; val cy: Float; var size: Float
        if (face.isNotEmpty()) {
            cx = face.map { it.x }.average().toFloat(); cy = face.map { it.y }.average().toFloat()
            val spread = maxOf(face.maxOf { it.x } - face.minOf { it.x }, face.maxOf { it.y } - face.minOf { it.y })
            size = maxOf(spread * 2.6f, (sw ?: 0f) * 0.6f)
            if (neck != null) size = maxOf(size, hypot(cx - neck.x, cy - neck.y) * 1.4f)
            if (sw != null) size = minOf(size, sw * 0.95f)          // a head is not wider than the shoulders
        } else if (neck != null && sw != null && sw > 4) {
            size = sw * 0.65f                                         // back turned: head sits above the neck
            cx = neck.x; cy = neck.y - size * 0.6f                    // (y grows downwards on Android)
        } else return null
        size = minOf(size, minOf(w, h) * 0.3f)                        // sanity: bad poses made giant boxes
        if (size <= 4) return null
        return RectF(cx - size / 2, cy - size / 2, cx + size / 2, cy + size / 2)
    }

    /** Pixellate then blur the whole frame, and paint it through a soft ellipse per head. */
    fun apply(rects: List<RectF>, src: Bitmap): Bitmap? = try {
        val out = src.copy(Bitmap.Config.ARGB_8888, true)
        if (rects.isNotEmpty()) {
            val largest = rects.maxOf { maxOf(it.width(), it.height()) }
            val block = maxOf(10f, largest / 7f)
            // pixellate: shrink by the block size, grow back without filtering (irreversible)
            val small = Bitmap.createScaledBitmap(src, maxOf(1, (src.width / block).toInt()), maxOf(1, (src.height / block).toInt()), false)
            val pix = Bitmap.createScaledBitmap(small, src.width, src.height, false)
            // then soften (cheap blur: shrink/grow with filtering)
            val soft = maxOf(6f, largest / 9f)
            val tiny = Bitmap.createScaledBitmap(pix, maxOf(1, (src.width / soft).toInt()), maxOf(1, (src.height / soft).toInt()), true)
            val cover = Bitmap.createScaledBitmap(tiny, src.width, src.height, true)
            val canvas = Canvas(out)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { shader = BitmapShader(cover, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP) }
            for (r in rects) {
                // fully covered ellipse fits the head box; the soft edge spills ~9% outside
                val e = RectF(r).apply { inset(-r.width() * 0.09f, -r.height() * 0.09f) }
                paint.maskFilter = BlurMaskFilter(maxOf(2f, minOf(r.width(), r.height()) * 0.09f), BlurMaskFilter.Blur.NORMAL)
                canvas.drawOval(e, paint)
                paint.maskFilter = null
                canvas.drawOval(r, paint)                              // solid core, no soft gaps
            }
        }
        out
    } catch (e: Exception) {
        null
    }

    companion object {
        /** Merge boxes that are the same person, unless the union would grow too much (signs stay visible). */
        fun mergeDuplicates(input: List<RectF>): List<RectF> {
            var boxes = input.sortedByDescending { it.width() * it.height() }
            var changed = true
            while (changed) {
                changed = false
                val out = ArrayList<RectF>()
                for (b in boxes) {
                    val i = out.indexOfFirst { a ->
                        val u = RectF(a).apply { union(b) }
                        overlaps(a, b) && u.width() * u.height() <= 1.5f * maxOf(a.width() * a.height(), b.width() * b.height())
                    }
                    if (i >= 0) { out[i] = RectF(out[i]).apply { union(b) }; changed = true } else out.add(b)
                }
                boxes = out
            }
            return boxes
        }

        private fun overlaps(a: RectF, b: RectF): Boolean {
            val inter = RectF()
            if (!inter.setIntersect(a, b)) return false
            val ia = inter.width() * inter.height()
            val aa = a.width() * a.height(); val ba = b.width() * b.height()
            return ia / (aa + ba - ia) > 0.3f || ia / minOf(aa, ba) > 0.6f
        }
    }
}

package app.nianxia.nianxia

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/** Declared ONLY in the disposable isolated release manifest. No user-file access. */
class ValidationResultProvider : ContentProvider() {
    override fun onCreate() = true
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri) = "application/json"
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw SecurityException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw SecurityException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw SecurityException()
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val ctx = context ?: throw FileNotFoundException()
        val id = uri.pathSegments.singleOrNull() ?: throw FileNotFoundException()
        if (ctx.packageName != TEST_ID || uri.authority != "$TEST_ID.validation" || mode != "r" ||
            !Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}").matches(id)) throw FileNotFoundException()
        val file = File(ctx.cacheDir.canonicalFile, "validation-results/$id.json")
        if (file.canonicalFile != file.absoluteFile) throw FileNotFoundException("validation_path")
        if (!file.isFile) throw FileNotFoundException("validation_result_missing")
        if (file.length() > 65536) throw FileNotFoundException("validation_size")
        val data = try { JSONObject(file.readText()) } catch (_: Exception) { throw FileNotFoundException() }
        if (data.getString("applicationId") != TEST_ID || data.getString("runId") != id ||
            !Regex("[a-z-]{1,64}").matches(data.getString("case")) || data.get("passed") !is Boolean) throw FileNotFoundException()
        val metrics = data.getJSONObject("metrics")
        if (metrics.length() > 128) throw FileNotFoundException()
        for (key in metrics.keys()) {
            val value = metrics.get(key)
            if (!Regex("[A-Za-z0-9_]{1,64}").matches(key) || value !is Number || !value.toDouble().isFinite()) throw FileNotFoundException()
        }
        val sanitized = JSONObject().put("applicationId", TEST_ID).put("runId", id)
            .put("case", data.getString("case")).put("passed", data.getBoolean("passed")).put("metrics", metrics)
            .toString().toByteArray(Charsets.UTF_8)
        val pipe = ParcelFileDescriptor.createPipe()
        Thread { runCatching { ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { it.write(sanitized) } } }.start()
        return pipe[0]
    }
    companion object { private const val TEST_ID = "app.nianxia.nianxia.test" }
}

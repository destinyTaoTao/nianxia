package app.nianxia.nianxia.capture

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/** Small versioned native metadata, independent of the original SQLite schema. */
class CaptureJournal(private val directory: File) {
    init {
        if (!directory.isDirectory && !directory.mkdirs()) throw CaptureFailure("capture_path")
        if (directory.canonicalFile != directory.absoluteFile) throw CaptureFailure("capture_path")
    }

    private fun file(id: String): File { CaptureRequest.checkId(id); return File(directory, "$id.session") }
    fun exists(id: String) = file(id).exists()
    fun ids(): List<String> = directory.listFiles()?.asSequence()
        ?.filter { it.name.endsWith(".session") }
        ?.map { it.name.removeSuffix(".session") }
        ?.filter { runCatching { CaptureRequest.checkId(it) }.isSuccess }
        ?.sorted()?.toList() ?: emptyList()

    fun save(value: CaptureSnapshot) {
        val target = file(value.request.sessionId)
        val partial = File(directory, "${target.name}.partial")
        FileOutputStream(partial).use { stream ->
            val out = DataOutputStream(stream)
            out.writeInt(0x4e584341)
            out.writeInt(1)
            val request = value.request
            out.writeUTF(request.sessionId); out.writeUTF(request.mode.name); out.writeUTF(request.createdAt)
            out.writeUTF(request.timezone); out.writeInt(request.offsetMinutes); out.writeUTF(request.parentId ?: "")
            out.writeUTF(value.phase.name); out.writeLong(value.sequence); out.writeLong(value.elapsedMs)
            out.writeLong(value.pcmBytes); out.writeUTF(value.errorCode ?: ""); out.writeBoolean(value.claimed)
            out.flush(); stream.fd.sync()
        }
        if (!partial.renameTo(target)) throw CaptureFailure("capture_journal")
    }

    fun read(id: String): CaptureSnapshot {
        val source = file(id)
        if (source.canonicalFile != source.absoluteFile || source.length() !in 1..8192) throw CaptureFailure("capture_journal")
        try {
            DataInputStream(FileInputStream(source)).use { input ->
                if (input.readInt() != 0x4e584341 || input.readInt() != 1) throw CaptureFailure("capture_journal_version")
                val request = CaptureRequest(input.readUTF(), CaptureMode.valueOf(input.readUTF()), input.readUTF(),
                    input.readUTF(), input.readInt(), input.readUTF().ifEmpty { null })
                val snapshot = CaptureSnapshot(request, CapturePhase.valueOf(input.readUTF()), input.readLong(),
                    input.readLong(), input.readLong(), errorCode = input.readUTF().ifEmpty { null }, claimed = input.readBoolean())
                if (request.sessionId != id || input.available() != 0 || snapshot.sequence < 0 ||
                    snapshot.elapsedMs !in 0L..120000L || snapshot.pcmBytes !in 0L..3840000L || snapshot.pcmBytes % 2 != 0L ||
                    snapshot.phase == CapturePhase.finalized && snapshot.pcmBytes == 0L ||
                    snapshot.errorCode?.let { !Regex("[a-z][a-z0-9_]{0,63}").matches(it) } == true) {
                    throw CaptureFailure("capture_journal")
                }
                return snapshot
            }
        } catch (error: CaptureFailure) { throw error }
        catch (_: Exception) { throw CaptureFailure("capture_journal") }
    }

    fun delete(id: String) {
        val path = file(id)
        if (!path.delete() && path.exists()) throw CaptureFailure("capture_cleanup")
    }
}

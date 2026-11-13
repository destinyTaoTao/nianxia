package app.nianxia.nianxia.capture

import java.io.Closeable
import java.io.File
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

enum class CaptureMode { record, query }
enum class CapturePhase { starting, recording, finalizing, finalized, failed, cancelled }
enum class CaptureDisposition { importedRecord, queryCompleted }
class CaptureFailure(val code: String) : Exception(code)

data class CaptureRequest(
    val sessionId: String, val mode: CaptureMode, val createdAt: String,
    val timezone: String, val offsetMinutes: Int, val parentId: String?
) {
    init {
        checkId(sessionId)
        parentId?.let { checkId(it) }
        if (createdAt.length > 64 || timezone.isBlank() || timezone.length > 100 ||
            offsetMinutes !in -840..840 || parentId == sessionId ||
            (mode == CaptureMode.query && parentId != null)) throw CaptureFailure("capture_invalid")
        if (!Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}([0-9]{3})?Z$").matches(createdAt)) {
            throw CaptureFailure("capture_invalid")
        }
        // java.time requires API26; do not add a runtime dependency for API24.
        val normalized = createdAt.substring(0, 23) + "Z"
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT)
        format.isLenient = false
        format.timeZone = TimeZone.getTimeZone("UTC")
        val position = ParsePosition(0)
        if (format.parse(normalized, position) == null || position.index != normalized.length) {
            throw CaptureFailure("capture_invalid")
        }
    }

    fun wire(): Map<String, Any?> = mapOf(
        "wireVersion" to 1, "sessionId" to sessionId, "mode" to mode.name,
        "createdAt" to createdAt, "timezone" to timezone, "offsetMinutes" to offsetMinutes,
        "parentId" to parentId
    )

    companion object {
        private val idPattern = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        fun checkId(id: String) { if (!idPattern.matches(id)) throw CaptureFailure("capture_invalid") }
        fun fromWire(value: Map<*, *>): CaptureRequest {
            try {
                if (value["wireVersion"] != 1) throw CaptureFailure("capture_version")
                return CaptureRequest(value["sessionId"] as String,
                    CaptureMode.valueOf(value["mode"] as String), value["createdAt"] as String,
                    value["timezone"] as String, value["offsetMinutes"] as Int, value["parentId"] as String?)
            } catch (error: CaptureFailure) { throw error }
            catch (_: Exception) { throw CaptureFailure("capture_invalid") }
        }
    }
}

data class CaptureSnapshot(
    val request: CaptureRequest, val phase: CapturePhase, val sequence: Long,
    val elapsedMs: Long = 0, val pcmBytes: Long = 0, val level: Double = 0.0,
    val errorCode: String? = null, val claimed: Boolean = false
) {
    fun wire(): Map<String, Any?> = request.wire() + mapOf(
        "phase" to phase.name, "sequence" to sequence, "elapsedMs" to elapsedMs,
        "pcmBytes" to pcmBytes, "level" to level, "errorCode" to errorCode,
        "relativeAudioName" to "${request.sessionId}.wav"
    )
    val active: Boolean get() = phase in listOf(CapturePhase.starting, CapturePhase.recording, CapturePhase.finalizing)
}

interface CaptureAudioSource {
    fun start(onPcm: (ByteArray, Int) -> Unit, onError: (String) -> Unit)
    fun stop()
}

/** Process owner. Flutter channels own subscriptions, not this recorder. */
class NativeCaptureSession(
    private val directory: File,
    private val createAudio: () -> CaptureAudioSource,
    private val monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000 },
    private val observe: (CaptureSnapshot) -> Unit = {}
) : Closeable {
    private val lock = Any()
    private val journal = CaptureJournal(directory)
    private val controls = Executors.newSingleThreadScheduledExecutor()
    private var state: CaptureSnapshot? = null
    private var audio: CaptureAudioSource? = null
    private var sink: PcmWaveSink? = null
    private var started = 0L
    private var lastEvent = 0L
    private var stopRequested = false
    private var finishing: CompletableFuture<CaptureSnapshot>? = null
    private var closed = false
    var recoveryWarnings = 0
        private set
    private fun warnJournal() { recoveryWarnings = (recoveryWarnings + 1).coerceAtMost(1000000) }

    init {
        recover()
        controls.scheduleAtFixedRate({ checkDeadline() }, 100, 100, TimeUnit.MILLISECONDS)
    }

    fun current(): CaptureSnapshot? = synchronized(lock) { state }

    fun pending(after: String?, limit: Int): List<CaptureSnapshot> = synchronized(lock) {
        if (limit !in 1..32) throw CaptureFailure("capture_invalid")
        after?.let { CaptureRequest.checkId(it) }
        journal.ids().asSequence().filter { after == null || it > after }
            .mapNotNull { id -> try { journal.read(id) } catch (_: Exception) { warnJournal(); null } }
            .filter { !it.active && it.phase != CapturePhase.cancelled }
            .take(limit).toList()
    }

    fun start(request: CaptureRequest): CaptureSnapshot = synchronized(lock) {
        if (closed) throw CaptureFailure("capture_closed")
        state?.takeIf { it.active }?.let { return it }
        if (journal.exists(request.sessionId) || wave(request).exists()) throw CaptureFailure("capture_collision")
        var next = CaptureSnapshot(request, CapturePhase.starting, 1)
        journal.save(next)
        state = next
        started = monotonicMillis()
        lastEvent = started
        stopRequested = false
        finishing = null
        try {
            sink = PcmWaveSink(wave(request))
            val input = createAudio()
            audio = input
            input.start({ bytes, count -> accept(request.sessionId, bytes, count) },
                { code -> requestStop(request.sessionId, code) })
            next = next.copy(phase = CapturePhase.recording, sequence = 2)
            state = next
            journal.save(next)
            observe(next)
            return next
        } catch (_: Exception) {
            val input = audio
            val output = sink
            audio = null
            sink = null
            val releasing = next.copy(phase = CapturePhase.finalizing, sequence = 2, errorCode = "audio_start")
            val failed = releasing.copy(phase = CapturePhase.failed, sequence = 3)
            val completion = CompletableFuture<CaptureSnapshot>()
            finishing = completion
            state = releasing
            runCatching { journal.save(failed) }
            observe(releasing)
            controls.execute {
                runCatching { input?.stop() }
                runCatching { output?.close() }
                synchronized(lock) {
                    state = failed
                    runCatching { journal.save(failed) }
                    observe(failed)
                    completion.complete(failed)
                }
            }
            throw CaptureFailure("audio_start")
        }
    }

    private fun accept(id: String, bytes: ByteArray, count: Int) {
        var limit = false
        synchronized(lock) {
            val old = state ?: return
            if (old.request.sessionId != id || old.phase != CapturePhase.recording) return
            try {
                val output = sink ?: return
                output.append(bytes, count)
                val elapsed = (monotonicMillis() - started).coerceIn(0L, 120000L)
                var energy = 0.0
                var samples = 0
                var index = 0
                while (index + 1 < count) {
                    val sample = ((bytes[index].toInt() and 255) or ((bytes[index + 1].toInt() and 255) shl 8)).toShort().toInt()
                    energy += sample.toDouble() * sample
                    samples++
                    index += 2
                }
                val level = if (samples == 0) 0.0 else (sqrt(energy / samples) / 32768.0).coerceIn(0.0, 1.0)
                val next = old.copy(sequence = old.sequence + 1, elapsedMs = elapsed, pcmBytes = output.pcmBytes, level = level)
                state = next
                if (monotonicMillis() - lastEvent >= 100) { lastEvent = monotonicMillis(); observe(next) }
                limit = output.pcmBytes >= 3840000L || elapsed >= 120000L
            } catch (_: Exception) {
                requestStop(id, "audio_write")
            }
        }
        if (limit) requestStop(id, null)
    }

    private fun requestStop(id: String, code: String?) {
        synchronized(lock) {
            val current = state ?: return
            if (closed || current.request.sessionId != id || !current.active || stopRequested) return
            stopRequested = true
            controls.execute {
                val shouldFinish = synchronized(lock) {
                    state?.request?.sessionId == id && state?.phase != CapturePhase.finalizing
                }
                if (shouldFinish) runCatching { finish(id, code, false) }
            }
        }
    }

    private fun checkDeadline() {
        val id = synchronized(lock) {
            state?.takeIf { it.phase == CapturePhase.recording && monotonicMillis() - started >= 120000 }
                ?.request?.sessionId
        }
        if (id != null) requestStop(id, null)
    }

    fun stop(id: String): CaptureSnapshot = finish(id, null, false)

    private fun finish(id: String, errorCode: String?, discard: Boolean): CaptureSnapshot {
        CaptureRequest.checkId(id)
        var input: CaptureAudioSource? = null
        var output: PcmWaveSink? = null
        var ownsFinish = false
        val completion: CompletableFuture<CaptureSnapshot>
        synchronized(lock) {
            val old = state?.takeIf { it.request.sessionId == id } ?: journal.read(id)
            if (old.claimed && discard) throw CaptureFailure("capture_claimed")
            if (!old.active) {
                if (discard) discardFiles(old)
                return if (discard) old.copy(phase = CapturePhase.cancelled) else old
            }
            if (old.phase == CapturePhase.finalizing) {
                if (discard) throw CaptureFailure("capture_busy")
                completion = finishing ?: throw CaptureFailure("capture_busy")
            } else {
                completion = CompletableFuture()
                finishing = completion
                ownsFinish = true
                val next = old.copy(phase = CapturePhase.finalizing, sequence = old.sequence + 1)
                // Disk gets a tombstone first; the live owner stays busy until
                // the microphone and writer are actually released.
                journal.save(if (discard) next.copy(phase = CapturePhase.cancelled) else next)
                state = next
                observe(next)
                input = audio
                audio = null
                output = sink
                sink = null
            }
        }
        if (!ownsFinish) return completion.get()
        var failure = errorCode
        try { input?.stop() } catch (_: Exception) { failure = failure ?: "audio_stop" }
        try { output?.close() } catch (_: Exception) { failure = failure ?: "audio_write" }
        synchronized(lock) {
            val old = state ?: throw CaptureFailure("capture_missing")
            val bytes = output?.pcmBytes ?: old.pcmBytes
            val final = old.copy(
                phase = if (discard) CapturePhase.cancelled else if (bytes > 0) CapturePhase.finalized else CapturePhase.failed,
                sequence = old.sequence + 1, elapsedMs = (monotonicMillis() - started).coerceIn(0L, 120000L),
                pcmBytes = bytes, level = 0.0, errorCode = failure ?: if (bytes == 0L && !discard) "audio_empty" else null
            )
            try {
                journal.save(final)
                if (discard) discardFiles(final)
                state = final
                observe(final)
                completion.complete(final)
            } catch (error: Exception) {
                completion.completeExceptionally(CaptureFailure("capture_journal"))
                throw CaptureFailure("capture_journal")
            }
            return final
        }
    }

    fun cancel(id: String) { finish(id, null, true) }

    fun claim(id: String): CaptureSnapshot = synchronized(lock) {
        val old = journal.read(id)
        if (old.phase != CapturePhase.finalized) throw CaptureFailure("capture_unfinished")
        if (!old.claimed && !wave(old.request).isFile) throw CaptureFailure("audio_missing")
        val next = old.copy(claimed = true)
        journal.save(next)
        if (state?.request?.sessionId == id) state = next
        next
    }

    fun acknowledge(id: String, disposition: CaptureDisposition) = synchronized(lock) {
        CaptureRequest.checkId(id)
        if (!journal.exists(id)) return
        val old = journal.read(id)
        if (!old.claimed || old.phase != CapturePhase.finalized ||
            (old.request.mode == CaptureMode.record) != (disposition == CaptureDisposition.importedRecord)) {
            throw CaptureFailure("capture_ack_invalid")
        }
        if (disposition == CaptureDisposition.queryCompleted && !wave(old.request).delete() && wave(old.request).exists()) {
            throw CaptureFailure("capture_cleanup")
        }
        journal.delete(id)
        if (state?.request?.sessionId == id) state = null
    }

    private fun discardFiles(snapshot: CaptureSnapshot) {
        if (snapshot.claimed) throw CaptureFailure("capture_claimed")
        // Cleanup can fail. Keep a durable tombstone until both deletions finish.
        journal.save(snapshot.copy(phase = CapturePhase.cancelled))
        val path = wave(snapshot.request)
        if (!path.delete() && path.exists()) throw CaptureFailure("capture_cleanup")
        journal.delete(snapshot.request.sessionId)
        if (state?.request?.sessionId == snapshot.request.sessionId) state = snapshot.copy(phase = CapturePhase.cancelled)
    }

    private fun wave(request: CaptureRequest): File {
        val parent = if (request.mode == CaptureMode.query) File(directory, "queries") else directory
        if (parent.canonicalFile != parent.absoluteFile) throw CaptureFailure("capture_path")
        if (!parent.isDirectory && !parent.mkdirs()) throw CaptureFailure("capture_path")
        return File(parent, "${request.sessionId}.wav")
    }

    private fun recover() {
        for (id in journal.ids()) {
            val old = try { journal.read(id) } catch (_: Exception) { warnJournal(); continue } // Preserve unknown versions.
            if (old.request.mode == CaptureMode.query || old.phase == CapturePhase.cancelled) {
                runCatching {
                    val path = wave(old.request)
                    if (!path.delete() && path.exists()) throw CaptureFailure("capture_cleanup")
                    journal.delete(id)
                }.onFailure { warnJournal() }
            } else if (old.active) {
                val next = try {
                    val bytes = PcmWaveSink.repair(wave(old.request))
                    old.copy(phase = CapturePhase.finalized, pcmBytes = bytes, elapsedMs = bytes / 32,
                        sequence = old.sequence + 1, level = 0.0, errorCode = "audio_recovered")
                } catch (_: Exception) {
                    old.copy(phase = CapturePhase.failed, sequence = old.sequence + 1, errorCode = "audio_recovery_failed")
                }
                runCatching { journal.save(next) }
            }
        }
    }

    override fun close() {
        val current = current()
        if (current?.active == true) runCatching { stop(current.request.sessionId) }
        synchronized(lock) { closed = true }
        controls.shutdown()
        controls.awaitTermination(3, TimeUnit.SECONDS)
    }
}

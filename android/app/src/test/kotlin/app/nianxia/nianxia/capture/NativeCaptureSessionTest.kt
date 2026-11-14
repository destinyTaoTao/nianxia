package app.nianxia.nianxia.capture

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class NativeCaptureSessionTest {
    private lateinit var directory: File
    private lateinit var audio: ManualAudio
    private lateinit var owner: NativeCaptureSession
    private val clock = AtomicLong(0)
    private val id = "11111111-1111-4111-8111-111111111111"
    private fun request(session: String = id) = CaptureRequest(
        session, CaptureMode.record, "2026-11-14T00:00:00.000Z", "Asia/Shanghai", 480, null
    )

    @Before fun setUp() {
        directory = Files.createTempDirectory("nianxia-native-capture-").toFile().canonicalFile
        audio = ManualAudio()
        owner = NativeCaptureSession(directory, { audio }, { clock.get() })
    }

    @After fun tearDown() {
        if (::owner.isInitialized) owner.close()
        directory.deleteRecursively()
    }

    private fun waitForFinalized(): CaptureSnapshot {
        val deadline = System.nanoTime() + 2_000_000_000L
        while (System.nanoTime() < deadline) {
            val current = owner.current()
            if (current?.phase == CapturePhase.finalized) return current
            Thread.sleep(5)
        }
        fail("Native deadline/limit did not finalize without Flutter")
        throw AssertionError()
    }

    @Test fun duplicateStartOwnsOnlyOneAudioFile() {
        owner.start(request())
        val again = owner.start(request("22222222-2222-4222-8222-222222222222"))
        assertEquals(id, again.request.sessionId)
        assertEquals(1, directory.walk().filter { it.extension == "wav" }.count())
    }

    @Test fun monotonicDeadlineStopsWithoutFlutter() {
        owner.start(request())
        audio.push(byteArrayOf(1, 2, 3, 4))
        clock.set(120001)
        val result = waitForFinalized()
        assertEquals(120000, result.elapsedMs.toInt())
        assertEquals(4, result.pcmBytes.toInt())
        assertFalse(audio.running)
    }

    @Test fun pcmLimitClipsWholeFramesAndFinalizes() {
        owner.start(request())
        audio.push(ByteArray(3_840_003) { 1 })
        val result = waitForFinalized()
        assertEquals(3_840_000L, result.pcmBytes)
        val data = File(directory, "$id.wav").readBytes()
        assertEquals(3_840_044, data.size)
        assertEquals(3_840_000, ByteBuffer.wrap(data, 40, 4).order(ByteOrder.LITTLE_ENDIAN).int)
    }

    @Test fun oddReadBoundaryPreservesCompletePcmFrames() {
        owner.start(request())
        audio.push(byteArrayOf(1, 2, 3))
        audio.push(byteArrayOf(4, 5))
        val result = owner.stop(id)
        assertEquals(4L, result.pcmBytes)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), File(directory, "$id.wav").readBytes().drop(44).toByteArray())
        assertEquals(result, owner.stop(id))
    }

    @Test fun claimedRecordCannotBeDiscardedAndAckDoesNotDeleteItsAudio() {
        owner.start(request())
        audio.push(byteArrayOf(1, 2))
        owner.stop(id)
        owner.claim(id)
        try {
            owner.cancel(id)
            fail("Claimed recording was discarded")
        } catch (error: CaptureFailure) {
            assertEquals("capture_claimed", error.code)
        }
        assertTrue(File(directory, "$id.wav").exists())
        owner.acknowledge(id, CaptureDisposition.importedRecord)
        assertTrue(File(directory, "$id.wav").exists())
        assertFalse(File(directory, "$id.session").exists())
    }

    @Test fun queryCompletionRemovesOnlyQueryTemporaryFiles() {
        owner.start(request().copy(mode = CaptureMode.query))
        audio.push(byteArrayOf(1, 2))
        owner.stop(id)
        owner.claim(id)
        try {
            owner.acknowledge(id, CaptureDisposition.importedRecord)
            fail("Query was treated as a saved record")
        } catch (_: CaptureFailure) { }
        owner.acknowledge(id, CaptureDisposition.queryCompleted)
        assertFalse(File(directory, "queries/$id.wav").exists())
    }

    @Test fun interruptedAudioKeepsValidFragmentAndDoesNotRestart() {
        owner.start(request())
        audio.push(byteArrayOf(1, 2))
        audio.fail("audio_interrupted")
        val result = waitForFinalized()
        assertEquals("audio_interrupted", result.errorCode)
        assertEquals(46L, File(directory, "$id.wav").length())
        assertFalse(audio.running)
    }

    @Test fun newStartWaitsForDiscardToReleaseThePreviousSource() {
        owner.start(request())
        audio.push(byteArrayOf(1, 2))
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        audio.beforeStop = { entered.countDown(); release.await(2, TimeUnit.SECONDS) }
        val worker = Executors.newSingleThreadExecutor()
        val discarding = worker.submit { owner.cancel(id) }
        try {
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            val repeated = owner.start(request("22222222-2222-4222-8222-222222222222"))
            assertEquals(id, repeated.request.sessionId)
        } finally {
            release.countDown()
            discarding.get(2, TimeUnit.SECONDS)
            worker.shutdownNow()
        }
    }

    @Test fun unreadableJournalsDoNotBlockValidPendingAndArePreserved() {
        owner.start(request());audio.push(byteArrayOf(1,2));owner.stop(id)
        val unknown=File(directory,"00000000-0000-4000-8000-000000000001.session")
        val corrupt=File(directory,"00000000-0000-4000-8000-000000000002.session")
        val future=ByteBuffer.allocate(8).putInt(0x4e584341).putInt(2).array()
        unknown.writeBytes(future);corrupt.writeBytes(byteArrayOf(1,2))
        assertEquals(listOf(id),owner.pending(null,32).map { it.request.sessionId })
        assertArrayEquals(future,unknown.readBytes());assertEquals(2L,corrupt.length())
        owner.close();owner=NativeCaptureSession(directory,{audio},{clock.get()})
        assertEquals(listOf(id),owner.pending(null,32).map { it.request.sessionId })
    }

    @Test fun failedStartRemainsBusyUntilPreviousSourceReleased() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        audio.failStart=true;audio.beforeStop={entered.countDown();release.await(2,TimeUnit.SECONDS)}
        try {owner.start(request());fail("expected start failure")} catch (_:CaptureFailure) {}
        try {
            assertTrue(entered.await(1,TimeUnit.SECONDS))
            val next=owner.start(request("22222222-2222-4222-8222-222222222222"))
            assertEquals(id,next.request.sessionId)
            assertEquals(CapturePhase.finalizing,next.phase)
            assertEquals(1,audio.starts)
        } finally {release.countDown()}
    }

    @Test fun failedQueryCleanupPreservesDurableIntentForRetry() {
        owner.start(request().copy(mode=CaptureMode.query));audio.push(byteArrayOf(1,2));owner.stop(id)
        val query=File(directory,"queries/$id.wav");assertTrue(query.delete());assertTrue(query.mkdir());File(query,"blocked").writeText("fixture")
        owner.close();owner=NativeCaptureSession(directory,{audio},{clock.get()})
        assertTrue("Cleanup failure lost its journal",File(directory,"$id.session").exists())
        assertTrue(query.exists())
    }

    @Test fun failedDiscardCleanupPreservesTombstoneForRetry() {
        owner.start(request());audio.push(byteArrayOf(1,2));owner.stop(id)
        val recording=File(directory,"$id.wav");assertTrue(recording.delete());assertTrue(recording.mkdir());File(recording,"blocked").writeText("fixture")
        try {owner.cancel(id)}catch (_:CaptureFailure){}
        assertTrue("Discard failure lost durable cleanup intent",File(directory,"$id.session").exists())
        assertEquals(CapturePhase.cancelled,CaptureJournal(directory).read(id).phase)
    }

    @Test fun explicitlyDiscardedClaimedRecoveryKeepsTombstoneUntilCleanupCompletes() {
        owner.start(request());audio.push(byteArrayOf(1,2));owner.stop(id);owner.claim(id)
        val recording=File(directory,"$id.wav");assertTrue(recording.delete());assertTrue(recording.mkdir());File(recording,"blocked").writeText("fixture")
        try {owner.acknowledge(id,CaptureDisposition.discardedRecord);fail("Cleanup unexpectedly succeeded")}catch (_:CaptureFailure){}
        assertEquals(CapturePhase.cancelled,CaptureJournal(directory).read(id).phase)
        owner.close();owner=NativeCaptureSession(directory,{audio},{clock.get()})
        assertTrue(owner.pending(null,32).none{it.request.sessionId==id})
        recording.deleteRecursively()
        owner.acknowledge(id,CaptureDisposition.discardedRecord)
        assertFalse(File(directory,"$id.session").exists())
    }

    @Test fun cancellingAbsentSessionIsIdempotentAndDoesNotStopAnotherSession() {
        owner.cancel(id);owner.cancel(id)
        val other="22222222-2222-4222-8222-222222222222"
        owner.start(request(other));owner.cancel(id)
        assertEquals(other,owner.current()?.request?.sessionId)
        assertTrue(audio.running)
    }

    @Test fun failedFinalJournalCanRetryAfterIoRecoversAndStartAnotherRecording() {
        owner.start(request())
        audio.push(byteArrayOf(1, 2, 3, 4))
        clock.set(1234)
        val blocked = File(directory, "$id.session.partial")
        audio.beforeStop = { assertTrue(blocked.mkdir()) }
        try { owner.stop(id); fail("Expected journal failure") } catch (_: CaptureFailure) { }
        assertFalse(audio.running)
        assertEquals("capture_journal", owner.current()?.errorCode)
        val failedSequence = owner.current()!!.sequence
        val wav = File(directory, "$id.wav").readBytes()
        assertEquals(48, wav.size)
        assertTrue(blocked.delete())
        audio.beforeStop = null
        clock.set(9000)
        val retried = owner.stop(id)
        assertEquals(CapturePhase.finalized, retried.phase)
        assertTrue(retried.sequence > failedSequence)
        assertEquals(1234L, retried.elapsedMs)
        assertEquals(4L, retried.pcmBytes)
        assertArrayEquals(wav, File(directory, "$id.wav").readBytes())
        assertEquals(retried, CaptureJournal(directory).read(id))
        val other = "22222222-2222-4222-8222-222222222222"
        assertEquals(other, owner.start(request(other)).request.sessionId)
    }

    @Test fun failedFinalJournalCanBeExplicitlyDiscardedAfterIoRecovers() {
        owner.start(request()); audio.push(byteArrayOf(1, 2))
        val blocked = File(directory, "$id.session.partial")
        audio.beforeStop = { assertTrue(blocked.mkdir()) }
        try { owner.stop(id); fail("Expected journal failure") } catch (_: CaptureFailure) { }
        assertTrue(blocked.delete()); audio.beforeStop = null
        owner.cancel(id)
        assertFalse(File(directory, "$id.wav").exists())
        assertFalse(File(directory, "$id.session").exists())
        assertFalse(audio.running)
    }

    @Test fun unavailableJournalCannotPreventMicrophoneRelease() {
        owner.start(request()); audio.push(byteArrayOf(1, 2))
        val blocked = File(directory, "$id.session.partial")
        assertTrue(blocked.mkdir())
        try { owner.stop(id); fail("Expected journal failure") } catch (_: CaptureFailure) { }
        assertFalse("Storage failure left microphone running", audio.running)
        assertTrue(blocked.delete())
        assertEquals(CapturePhase.finalized, owner.stop(id).phase)
    }

    private class ManualAudio : CaptureAudioSource {
        private lateinit var accept: (ByteArray, Int) -> Unit
        private lateinit var failure: (String) -> Unit
        var running = false
        var failStart=false
        var starts=0
        var beforeStop: (() -> Unit)? = null
        override fun start(onPcm: (ByteArray, Int) -> Unit, onError: (String) -> Unit) {
            accept = onPcm
            failure = onError
            running = true
            starts++
            if (failStart) throw CaptureFailure("audio_start")
        }
        override fun stop() { beforeStop?.invoke(); running = false }
        fun push(bytes: ByteArray) { accept(bytes, bytes.size) }
        fun fail(code: String) { failure(code) }
    }
}

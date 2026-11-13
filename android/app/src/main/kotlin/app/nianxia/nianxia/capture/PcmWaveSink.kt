package app.nianxia.nianxia.capture

import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PcmWaveSink(file: File) : Closeable {
    private val output = RandomAccessFile(file, "rw")
    var pcmBytes: Long = 0
        private set
    private var carry: Byte? = null
    private var closed = false

    init { output.setLength(0); output.write(header(0)) }

    fun append(bytes: ByteArray, count: Int) {
        if (closed || count !in 0..bytes.size) throw CaptureFailure("audio_write")
        if (pcmBytes >= LIMIT) return
        var at = 0
        if (carry != null && count > 0) {
            output.write(byteArrayOf(carry!!, bytes[0]))
            pcmBytes += 2
            carry = null
            at = 1
        }
        val size = minOf(((count - at) / 2) * 2, (LIMIT - pcmBytes).toInt())
        if (size > 0) { output.write(bytes, at, size); pcmBytes += size; at += size }
        if (at < count && pcmBytes < LIMIT) carry = bytes[at]
    }

    override fun close() {
        if (closed) return
        closed = true
        try { output.seek(0); output.write(header(pcmBytes)); output.fd.sync() }
        finally { output.close() }
    }

    companion object {
        const val LIMIT = 3840000L
        private fun header(bytes: Long): ByteArray {
            val b = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            b.put("RIFF".toByteArray()).putInt((36 + bytes).toInt()).put("WAVEfmt ".toByteArray())
            b.putInt(16).putShort(1).putShort(1).putInt(16000).putInt(32000).putShort(2).putShort(16)
            b.put("data".toByteArray()).putInt(bytes.toInt())
            return b.array()
        }

        fun repair(file: File): Long {
            RandomAccessFile(file, "rw").use { output ->
                val size = output.length()
                if (size < 46 || size > LIMIT + 45) throw CaptureFailure("audio_invalid")
                val prefix = ByteArray(44)
                output.readFully(prefix)
                val expected = header(0)
                for (at in prefix.indices) {
                    if (at !in 4..7 && at !in 40..43 && prefix[at] != expected[at]) throw CaptureFailure("audio_invalid")
                }
                val bytes = ((size - 44) / 2) * 2
                if (bytes !in 2..LIMIT) throw CaptureFailure("audio_invalid")
                output.setLength(44 + bytes)
                output.seek(0)
                output.write(header(bytes))
                output.fd.sync()
                return bytes
            }
        }
    }
}

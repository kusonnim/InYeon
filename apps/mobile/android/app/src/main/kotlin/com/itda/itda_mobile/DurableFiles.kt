package com.itda.itda_mobile

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

internal fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count == -1) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().toHex()
}

internal fun writeSynced(file: File, bytes: ByteArray) {
    FileOutputStream(file).use { output ->
        output.write(bytes)
        output.fd.sync()
    }
}

// Callers serialize writes to a destination. An interrupted replacement leaves the old file or
// the complete new file readable. An abandoned temporary file is reused by the next write.
internal fun replaceDurably(file: File, bytes: ByteArray) {
    val directory = checkNotNull(file.parentFile)
    val staging = File(directory, ".${file.name}.next")
    try {
        writeSynced(staging, bytes)
        Os.rename(staging.path, file.path)
        syncDirectory(directory)
    } finally {
        staging.delete()
    }
}

internal fun syncDirectory(directory: File) {
    val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
    try {
        Os.fsync(fd)
    } finally {
        Os.close(fd)
    }
}

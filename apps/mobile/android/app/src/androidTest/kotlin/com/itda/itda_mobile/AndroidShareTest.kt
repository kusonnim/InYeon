package com.itda.itda_mobile

import android.app.Activity
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.provider.MediaStore
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit.SECONDS
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidShareTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val resolver = context.contentResolver
    private val testDir = File(context.cacheDir, "share-test-${UUID.randomUUID()}")
    private val inboxDir = File(testDir, "inbox")
    private val store = LocalShareStore(inboxDir)
    private val ingestion = AndroidShareIngestion(resolver, store)
    private val receivedAtMs = 1794182400000L

    @Before
    fun createTestDirectory() {
        check(testDir.mkdir())
    }

    @After
    fun removeTestDirectory() {
        testDir.deleteRecursively()
    }

    @Test
    fun preservesTextAndRetryKeyAcrossReopenAndReplay() {
        val text = "  A note from another app.\nOriginal spacing.  "
        val intent = textIntent(text)
        val id = ingest(intent)
        val original = receipt(id)
        assertEquals(text, original.getString("source_text"))
        assertEquals("text", original.getString("input_type"))
        assertEquals(receivedAtMs, original.getLong("received_at_ms"))
        assertEquals("com.example.sender", original.getString("source_package"))
        assertEquals("pending_upload", original.getString("upload_state"))
        assertTrue(original.isNull("last_error"))
        val retryKey = UUID.fromString(original.getString("client_event_id"))

        val reopened = LocalShareStore(inboxDir)
        // Replaying a committed delivery must work even after the original input disappears.
        reopened.persist(UUID.fromString(id), receivedAtMs) { error("Reopened the original share") }
        assertEquals(id, reopened.listShares().single()["local_id"])
        assertEquals(retryKey.toString(), receipt(id).getString("client_event_id"))
        val secondId = ingest(intent)
        assertNotEquals(id, secondId)
        assertNotEquals(retryKey.toString(), receipt(secondId).getString("client_event_id"))
        assertEquals(2, reopened.listShares().size)
    }

    @Test
    fun recognizesBrowserStyleUrlAndKeepsOriginalTextAndSubject() {
        val url = "https://example.org/a?x=1"
        val text = "A shared article\n$url"
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain")
            .putExtra(Intent.EXTRA_SUBJECT, "Article")
            .apply { clipData = ClipData.newPlainText("Browser", text) }
        val record = receipt(ingest(intent))
        assertEquals("url", record.getString("input_type"))
        assertEquals(url, record.getString("source_url"))
        assertEquals(text, record.getString("source_text"))
        assertEquals("Article", record.getString("subject"))
        val summary = store.listShares().single()
        assertEquals(url, summary["source_url"])
        assertEquals("Article", summary["subject"])
        assertEquals(text, summary["link_text"])
    }

    @Test
    @SdkSuppress(minSdkVersion = 29)
    @Suppress("DEPRECATION")
    fun originalImagePathsRequireValidBytesAndTheCurrentOwner() {
        val ownerA = UploadOwner(UUID.randomUUID(), "a".repeat(64))
        val ownerB = UploadOwner(UUID.randomUUID(), ownerA.realm)
        var activeOwner: UploadOwner? = ownerA
        val originals = LocalOriginals(store) { activeOwner }
        val formats = mapOf(
            "image/jpeg" to Bitmap.CompressFormat.JPEG,
            "image/png" to Bitmap.CompressFormat.PNG,
            "image/webp" to Bitmap.CompressFormat.WEBP,
        )
        for ((mime, format) in formats) {
            val bytes = ByteArrayOutputStream().also { output ->
                val bitmap = Bitmap.createBitmap(96, 48, Bitmap.Config.ARGB_8888)
                try {
                    assertTrue(bitmap.compress(format, 90, output))
                } finally {
                    bitmap.recycle()
                }
            }.toByteArray()
            val localId = UUID.randomUUID()
            store.persist(localId, receivedAtMs, ownerA) { file ->
                file.writeBytes(bytes)
                JSONObject().put("input_type", "image").put("attachment", JSONObject()
                    .put("file_ref", LocalShareStore.ATTACHMENT_NAME).put("filename", "saved-image")
                    .put("media_type", mime).put("size_bytes", bytes.size).put("sha256", sha256(bytes)))
            }
            val path = checkNotNull(originals.read(localId)["image_path"] as String?)
            val file = File(path)
            assertArrayEquals(bytes, file.readBytes())
            val ref = NoticeRef(ownerA, UUID.randomUUID())
            assertNull(originals.readRegistered(ref))
            store.updateProgress(localId) { it.copy(state = UploadState.SYNCHRONIZED, serverContentId = ref.contentId) }
            assertEquals(path, originals.readRegistered(ref)?.get("image_path"))
            activeOwner = ownerB
            assertThrows(UploadProblem::class.java) { originals.read(localId) }
            assertThrows(UploadProblem::class.java) { originals.readRegistered(ref) }
            assertNull(originals.readRegistered(NoticeRef(ownerB, ref.contentId)))
            val redacted = store.listShares(ownerB).first { it["local_id"] == localId.toString() }
            assertNull(redacted["input_type"])
            assertNull(redacted["source_url"])
            activeOwner = ownerA
            val changed = bytes.copyOf().also { it[it.lastIndex] = (it.last() + 1).toByte() }
            file.writeBytes(changed)
            assertNull(originals.read(localId)["image_path"])
            check(file.delete())
            assertNull(originals.readRegistered(ref)?.get("image_path"))
        }
    }

    @Test
    @SdkSuppress(minSdkVersion = 29)
    fun copiesImageAndPdfAndKeepsBytesAfterProviderRemoval() {
        val image = ByteArrayOutputStream().also { output ->
            val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            bitmap.recycle()
        }.toByteArray()
        val pdf = ByteArrayOutputStream().also { output ->
            val document = PdfDocument()
            try {
                val page = document.startPage(PdfDocument.PageInfo.Builder(72, 72, 1).create())
                document.finishPage(page)
                document.writeTo(output)
            } finally {
                document.close()
            }
        }.toByteArray()

        assertPrivateCopy("fixture.png", "image/png", "image", image)
        assertPrivateCopy("fixture.pdf", "application/pdf", "document", pdf)
        assertEquals(2, LocalShareStore(inboxDir).listShares().size)
    }

    @Test
    fun rejectsInaccessibleUrisAndNonContentSchemes() {
        for (uri in listOf("content://com.itda.missing/file", "file:///sdcard/share.pdf")) {
            val failure = assertThrows(ShareRejected::class.java) {
                ingest(Intent(Intent.ACTION_SEND).setType("application/pdf")
                    .putExtra(Intent.EXTRA_STREAM, Uri.parse(uri)))
            }
            assertEquals(R.string.share_unreadable, failure.messageRes)
        }
        assertTrue(store.listShares().isEmpty())
    }

    @Test
    fun storageFailureAndInterruptedCopyCannotPublishPendingReceipt() {
        val obstructedInbox = File(testDir, "not-a-directory").apply { writeText("blocked") }
        val id = UUID.randomUUID()
        assertThrows(IOException::class.java) {
            LocalShareStore(obstructedInbox).persist(id, receivedAtMs) { error("Opened blocked inbox") }
        }
        assertThrows(IOException::class.java) {
            store.persist(id, receivedAtMs) { destination ->
                destination.writeBytes(byteArrayOf(1, 2, 3))
                throw IOException("Simulated interrupted copy")
            }
        }
        assertTrue(inboxDir.listFiles()!!.isEmpty())

        val abandoned = File(inboxDir, ".incoming-$id").apply { mkdir() }
        File(abandoned, LocalShareStore.ATTACHMENT_NAME).writeBytes(byteArrayOf(1, 2, 3))
        assertTrue(LocalShareStore(inboxDir).listShares().isEmpty())
        assertFalse(abandoned.exists())
    }

    @Test
    fun receiverWaitsForCommitAndRecreationDoesNotDuplicateDelivery() {
        val marker = "Receiver recreation ${UUID.randomUUID()}"
        val actualStore = localShareStore(context)
        val allowWrite = CountDownLatch(1)
        shareIo.execute { allowWrite.await(30, SECONDS) }
        try {
            val intent = textIntent(marker).setClass(context, ShareReceiverActivity::class.java)
            ActivityScenario.launchActivityForResult<ShareReceiverActivity>(intent).use { scenario ->
                scenario.recreate()
                scenario.onActivity { assertFalse(it.isFinishing) }
                assertTrue(actualStore.listShares().none { it["label"] == marker })

                allowWrite.countDown()
                assertEquals(Activity.RESULT_OK, scenario.result.resultCode)
                assertEquals(1, actualStore.listShares().count { it["label"] == marker })
            }
        } finally {
            allowWrite.countDown()
            shareIo.submit {
                val inbox = File(context.noBackupFilesDir, "share-inbox-v1")
                actualStore.listShares().filter { it["label"] == marker }.forEach {
                    File(inbox, it.getValue("local_id") as String).deleteRecursively()
                }
            }.get(30, SECONDS)
        }
    }

    private fun ingest(intent: Intent) =
        ingestion.persistIncomingShare(UUID.randomUUID(), receivedAtMs, intent, "com.example.sender")

    private fun textIntent(text: String) =
        Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)

    private fun receipt(id: String) = JSONObject(File(inboxDir, "$id/receipt.json").readText())

    private fun assertPrivateCopy(name: String, mime: String, kind: String, bytes: ByteArray) {
        val uri = checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
        }))
        val id = try {
            checkNotNull(resolver.openOutputStream(uri)).use { it.write(bytes) }
            ingest(Intent(Intent.ACTION_SEND).setType(mime).apply {
                clipData = ClipData.newRawUri("Attachment", uri)
            })
        } finally {
            resolver.delete(uri, null, null)
        }
        val record = receipt(id)
        val attachment = record.getJSONObject("attachment")
        assertEquals(kind, record.getString("input_type"))
        assertEquals(mime, attachment.getString("media_type"))
        assertEquals(name, attachment.getString("filename"))
        assertEquals(bytes.size.toLong(), attachment.getLong("size_bytes"))
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertEquals(digest, attachment.getString("sha256"))
        assertArrayEquals(bytes, File(inboxDir, "$id/${attachment.getString("file_ref")}").readBytes())
    }
}

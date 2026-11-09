package com.itda.itda_mobile

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.ListenableWorker.Result
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.SECONDS
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OutboxUploadTest {
    private val server = MockWebServer()
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(context.cacheDir, "outbox-test-${UUID.randomUUID()}")
    private val inbox = File(directory, "inbox")
    private val sessionFile = File(directory, "session")
    private val store = LocalShareStore(inbox)
    private val vault = SessionVault(sessionFile)
    private lateinit var config: UploadConfig
    private lateinit var sessions: SupabaseSessions
    private lateinit var processor: UploadProcessor

    @Before
    fun start() {
        check(directory.mkdir())
        server.start()
        val url = server.url("/").toString()
        config = checkNotNull(UploadConfig.create("mock", url, url, PUBLISHABLE, debug = true))
        sessions = SupabaseSessions(config, vault)
        processor = UploadProcessor(store, config, sessions)
    }

    @After
    fun stop() {
        server.close()
        directory.deleteRecursively()
    }

    @Test
    fun keepsLegacyReceiptUnownedUntilClaimAndPersistsTextAndUrlAcknowledgments() {
        val text = share("text", text = "  Original note with spacing  ", assignedOwner = null)
        val original = receiptFile(text).readBytes()
        val key = contentKey(text)
        val token = signIn(USER_A)
        assertEquals(Result.success(), processor.run(text))
        assertEquals(UploadState.AUTH_REQUIRED, progress(text).state)
        assertEquals(1, server.requestCount)

        store.updateProgress(text) { UploadProgress(owner(USER_A)) }
        val url = share("url", text = "Shared article\nhttps://example.org/a", url = "https://example.org/a")
        for (id in listOf(text, url)) {
            val contentId = UUID.randomUUID()
            val source = checkNotNull(store.read(id)).receipt
            enqueue(201, content(contentId, USER_A, source))
            assertEquals(Result.success(), processor.run(id))
            val request = take("/v1/contents", token)
            assertEquals(contentKey(id), request.headers["Idempotency-Key"])
            val body = jsonBody(request)
            assertEquals(source.getString("input_type"), body.getString("input_type"))
            assertEquals(source.getString("source_text"), body.getString("source_text"))
            assertEquals(source.stringOrNull("source_url"), body.stringOrNull("source_url"))
            assertEquals(0, body.getJSONArray("asset_ids").length())
            val reopened = checkNotNull(LocalShareStore(inbox).read(id)).progress
            assertEquals(UploadState.SYNCHRONIZED, reopened.state)
            assertEquals(contentId, reopened.serverContentId)
        }
        assertArrayEquals(original, receiptFile(text).readBytes())
        assertEquals(key, contentKey(text))
    }

    @Test
    fun copiesImageAndPdfThroughTheSignedCapabilityThenAttachesVerifiedAssets() {
        val token = signIn(USER_A)
        val png = Base64.decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jp4sAAAAASUVORK5CYII=",
            Base64.DEFAULT,
        )
        for ((kind, format, bytes) in listOf(
            Triple("image", "image/png", png), Triple("document", "application/pdf", PDF),
        )) {
            val id = share(kind, bytes = bytes, mediaType = format)
            val assetId = UUID.randomUUID()
            val serverId = UUID.randomUUID()
            enqueue(201, reservation(assetId, format))
            enqueue(200, JSONObject())
            enqueue(200, verified(assetId, format, bytes))
            enqueue(201, content(serverId, USER_A, checkNotNull(store.read(id)).receipt, assetId))

            assertEquals(Result.success(), processor.run(id))
            val reserve = take("/v1/assets/uploads", token)
            val metadata = jsonBody(reserve)
            assertEquals(setOf("filename", "media_type", "size_bytes", "sha256"), metadata.keys().asSequence().toSet())
            assertEquals(format, metadata.getString("media_type"))
            assertEquals(bytes.size.toLong(), metadata.getLong("size_bytes"))
            assertEquals(sha256(bytes), metadata.getString("sha256"))
            val put = take("/storage/$assetId", null)
            assertEquals("PUT", put.method)
            assertEquals(format, put.headers["Content-Type"])
            assertEquals("false", put.headers["x-upsert"])
            assertArrayEquals(bytes, checkNotNull(put.body).toByteArray())
            assertNull(put.headers["Idempotency-Key"])
            val complete = take("/v1/assets/$assetId/complete", token)
            assertEquals(0L, complete.bodySize)
            val create = take("/v1/contents", token)
            assertEquals(assetId.toString(), jsonBody(create).getJSONArray("asset_ids").getString(0))
            assertEquals(
                3, listOf(reserve, complete, create).map { it.headers["Idempotency-Key"] }.toSet().size,
            )
            assertEquals(serverId, progress(id).serverContentId)
            assertArrayEquals(bytes, checkNotNull(store.read(id)).sourceFile.readBytes())
        }
    }

    @Test
    fun retriesTheSameContentBodyAndKeyAfterTemporaryFailureAndRestart() {
        val token = signIn(USER_A)
        val id = share("text", text = "Preserve this source")
        val original = receiptFile(id).readBytes()
        enqueue(503, error("upstream_unavailable"))
        assertEquals(Result.retry(), processor.run(id))
        assertEquals(UploadState.RETRY_WAITING, progress(id).state)
        assertEquals("http_503", progress(id).lastError)
        val initial = take("/v1/contents", token)

        val serverId = UUID.randomUUID()
        enqueue(201, content(serverId, USER_A, checkNotNull(store.read(id)).receipt))
        val restarted = reopen()
        assertEquals(Result.success(), restarted.run(id))
        val retry = take("/v1/contents", token)
        assertEquals(initial.body, retry.body)
        assertEquals(contentKey(id), retry.headers["Idempotency-Key"])
        assertEquals(initial.headers["Idempotency-Key"], retry.headers["Idempotency-Key"])
        assertEquals(serverId, progress(id).serverContentId)
        assertArrayEquals(original, receiptFile(id).readBytes())
        assertEquals(Result.success(), restarted.run(id))
        assertEquals(3, server.requestCount)
    }

    @Test
    fun resumesCompletionWithItsPersistedKeyWithoutReuploadingBytes() {
        val token = signIn(USER_A)
        val id = share("document", bytes = PDF, mediaType = "application/pdf")
        val assetId = UUID.randomUUID()
        enqueue(201, reservation(assetId, "application/pdf"))
        enqueue(200, JSONObject())
        enqueue(503, error("upstream_unavailable"))
        assertEquals(Result.retry(), processor.run(id))
        take("/v1/assets/uploads", token)
        take("/storage/$assetId", null)
        val completion = take("/v1/assets/$assetId/complete", token)
        assertEquals(AssetStage.COMPLETE, progress(id).asset?.stage)

        enqueue(200, verified(assetId, "application/pdf", PDF))
        enqueue(201, content(UUID.randomUUID(), USER_A, checkNotNull(store.read(id)).receipt, assetId))
        assertEquals(Result.success(), reopen().run(id))
        val resumed = take("/v1/assets/$assetId/complete", token)
        assertEquals(completion.headers["Idempotency-Key"], resumed.headers["Idempotency-Key"])
        take("/v1/contents", token)
        assertEquals(AssetStage.VERIFIED, progress(id).asset?.stage)
    }

    @Test
    fun replacesAnExpiredReservationWithNewAssetKeysAndKeepsTheContentKey() {
        val token = signIn(USER_A)
        val id = share("document", bytes = PDF, mediaType = "application/pdf")
        val oldAsset = UUID.randomUUID()
        val oldProgress = AssetProgress(stage = AssetStage.PUT, assetId = oldAsset)
        store.updateProgress(id) { it.copy(asset = oldProgress) }
        enqueue(409, error("upload_expired"))
        val newAsset = UUID.randomUUID()
        enqueue(201, reservation(newAsset, "application/pdf"))
        enqueue(200, JSONObject())
        enqueue(200, verified(newAsset, "application/pdf", PDF))
        enqueue(201, content(UUID.randomUUID(), USER_A, checkNotNull(store.read(id)).receipt, newAsset))

        assertEquals(Result.success(), processor.run(id))
        val expired = take("/v1/assets/uploads", token)
        val replacement = take("/v1/assets/uploads", token)
        assertEquals(oldProgress.reservationKey.toString(), expired.headers["Idempotency-Key"])
        assertNotEquals(expired.headers["Idempotency-Key"], replacement.headers["Idempotency-Key"])
        take("/storage/$newAsset", null)
        val complete = take("/v1/assets/$newAsset/complete", token)
        assertNotEquals(oldProgress.completionKey.toString(), complete.headers["Idempotency-Key"])
        assertEquals(contentKey(id), take("/v1/contents", token).headers["Idempotency-Key"])
    }

    @Test
    fun verifiesAnAlreadyStoredObjectAfterAnInterruptedPut() {
        val token = signIn(USER_A)
        val id = share("document", bytes = PDF, mediaType = "application/pdf")
        val asset = UUID.randomUUID()
        val checkpoint = AssetProgress(stage = AssetStage.PUT, assetId = asset)
        store.updateProgress(id) { it.copy(asset = checkpoint, state = UploadState.UPLOADING) }
        enqueue(201, reservation(asset, "application/pdf"))
        enqueue(409, JSONObject().put("error", "Duplicate"))
        enqueue(200, verified(asset, "application/pdf", PDF))
        enqueue(201, content(UUID.randomUUID(), USER_A, checkNotNull(store.read(id)).receipt, asset))

        assertEquals(Result.success(), reopen().run(id))
        val reserve = take("/v1/assets/uploads", token)
        assertEquals(checkpoint.reservationKey.toString(), reserve.headers["Idempotency-Key"])
        take("/storage/$asset", null)
        val complete = take("/v1/assets/$asset/complete", token)
        assertEquals(checkpoint.completionKey.toString(), complete.headers["Idempotency-Key"])
        take("/v1/contents", token)
        assertEquals(UploadState.SYNCHRONIZED, progress(id).state)
        assertArrayEquals(PDF, checkNotNull(store.read(id)).sourceFile.readBytes())
    }

    @Test
    fun refreshesOnUnauthorizedAndSavesTheRotatedTokensInTheVault() {
        val original = signIn(USER_A)
        val id = share("text", text = "Token refresh")
        val rotated = auth(USER_A, "rotated-refresh")
        enqueue(401, error("unauthorized"))
        enqueue(200, rotated)
        enqueue(201, content(UUID.randomUUID(), USER_A, checkNotNull(store.read(id)).receipt))
        assertEquals(Result.success(), processor.run(id))

        val first = take("/v1/contents", original)
        val refresh = take("/auth/v1/token", null)
        assertEquals("grant_type=refresh_token", refresh.url.encodedQuery)
        assertEquals(PUBLISHABLE, refresh.headers["apikey"])
        assertEquals("initial-refresh", jsonBody(refresh).getString("refresh_token"))
        val retried = take("/v1/contents", rotated.getString("access_token"))
        assertEquals(first.headers["Idempotency-Key"], retried.headers["Idempotency-Key"])
        assertEquals(first.body, retried.body)
        val restored = SessionVault(sessionFile).snapshot().session
        assertEquals("rotated-refresh", restored?.refreshToken)
        assertEquals(rotated.getString("access_token"), restored?.accessToken)
        assertFalse(sessionFile.readBytes().decodeToString().contains("rotated-refresh"))
    }

    @Test
    fun wrongAccountNeverSubmitsAndRevokedRefreshLeavesTheOriginalBound() {
        signIn(USER_B)
        val id = share("text", text = "Account A private source")
        val original = receiptFile(id).readBytes()
        assertEquals(Result.success(), processor.run(id))
        assertEquals(UploadState.AUTH_REQUIRED, progress(id).state)
        val hidden = store.listShares(owner(USER_B)).single()
        assertNull(hidden["input_type"])
        assertFalse(hidden["label"].toString().contains("Account A"))
        assertEquals(1, server.requestCount)

        signIn(USER_A, expired = true)
        enqueue(400, JSONObject().put("error_code", "refresh_token_not_found"))
        assertEquals(Result.success(), processor.run(id))
        assertEquals("grant_type=refresh_token", take("/auth/v1/token", null).url.encodedQuery)
        assertNull(SessionVault(sessionFile).snapshot().session)
        assertEquals(UploadState.AUTH_REQUIRED, progress(id).state)
        assertEquals(owner(USER_A), progress(id).owner)
        assertArrayEquals(original, receiptFile(id).readBytes())
        assertEquals(3, server.requestCount)
    }

    @Test
    fun aRefreshWithAMismatchedSubjectNeverAuthorizesAnUpload() {
        signIn(USER_A, expired = true)
        val id = share("text", text = "Keep this share with A")
        val mismatched = auth(USER_B, "wrong-subject")
            .put("user", JSONObject().put("id", USER_A.toString()).put("email", "a@example.test"))
        enqueue(200, mismatched)
        assertEquals(Result.success(), processor.run(id))
        take("/auth/v1/token", null)
        assertEquals(2, server.requestCount)
        assertEquals(UploadState.AUTH_REQUIRED, progress(id).state)
        assertEquals(owner(USER_A), progress(id).owner)
        assertNull(SessionVault(sessionFile).snapshot().session)
    }

    @Test
    fun permanentErrorsStopAutomaticRetriesAndKeepSources() {
        val token = signIn(USER_A)
        for ((status, code) in listOf(422 to "http_422", 501 to "backend_not_implemented")) {
            val id = share("text", text = "Local source for $status")
            val original = receiptFile(id).readBytes()
            enqueue(status, error("validation_error"))
            assertEquals(Result.success(), processor.run(id))
            take("/v1/contents", token)
            assertEquals(UploadState.PERMANENT_FAILURE, progress(id).state)
            assertEquals(code, progress(id).lastError)
            assertArrayEquals(original, receiptFile(id).readBytes())
            assertEquals(Result.success(), reopen().run(id))
        }
        assertEquals(3, server.requestCount)
    }

    @Test
    fun overlappingRunsForOneReceiptSendOnlyOneRequest() {
        signIn(USER_A)
        val id = share("text", text = "One request")
        val acknowledgment = content(UUID.randomUUID(), USER_A, checkNotNull(store.read(id)).receipt)
        val requested = CountDownLatch(1)
        val acknowledge = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requested.countDown()
                check(acknowledge.await(15, SECONDS))
                return response(201, acknowledgment)
            }
        }
        val executor = Executors.newSingleThreadExecutor()
        try {
            val first = executor.submit<Result> { processor.run(id) }
            assertTrue(requested.await(10, SECONDS))
            assertEquals(Result.retry(), processor.run(id))
            assertEquals(2, server.requestCount)
            acknowledge.countDown()
            assertEquals(Result.success(), first.get(10, SECONDS))
            assertEquals(UploadState.SYNCHRONIZED, progress(id).state)
        } finally {
            acknowledge.countDown()
            executor.shutdownNow()
        }
    }

    private fun reopen(): UploadProcessor {
        val restoredVault = SessionVault(sessionFile)
        return UploadProcessor(LocalShareStore(inbox), config, SupabaseSessions(config, restoredVault))
    }

    private fun signIn(userId: UUID, expired: Boolean = false): String {
        val email = "$userId@example.test"
        val snapshot = vault.snapshot()
        val data = auth(userId, "initial-refresh", expired)
        enqueue(200, data)
        val session = sessions.signIn(email, "test-password")
        assertTrue(vault.replaceIfCurrent(snapshot, session))
        val request = take("/auth/v1/token", null)
        assertEquals("grant_type=password", request.url.encodedQuery)
        assertEquals(PUBLISHABLE, request.headers["apikey"])
        assertEquals(email, jsonBody(request).getString("email"))
        return data.getString("access_token")
    }

    private fun share(
        type: String,
        text: String? = null,
        url: String? = null,
        bytes: ByteArray? = null,
        mediaType: String? = null,
        assignedOwner: UploadOwner? = owner(USER_A),
    ): UUID {
        val id = UUID.randomUUID()
        store.persist(id, 1794268800000L, assignedOwner) { destination ->
            val receipt = JSONObject().put("input_type", type).put("source_text", text).put("source_url", url)
            if (bytes != null) {
                writeSynced(destination, bytes)
                receipt.put(
                    "attachment", JSONObject().put("file_ref", "source").put("filename", "fixture.$type")
                        .put("size_bytes", bytes.size).put("media_type", mediaType).put("sha256", sha256(bytes)),
                )
            }
            receipt
        }
        return id
    }

    private fun owner(id: UUID) = UploadOwner(id, config.realm)
    private fun receiptFile(id: UUID) = File(inbox, "$id/receipt.json")
    private fun progress(id: UUID) = checkNotNull(store.read(id)).progress
    private fun contentKey(id: UUID) = checkNotNull(store.read(id)).receipt.getString("client_event_id")
    private fun jsonBody(request: RecordedRequest) = JSONObject(checkNotNull(request.body).utf8())
    private fun enqueue(code: Int, body: JSONObject) = server.enqueue(response(code, body))
    private fun response(code: Int, body: JSONObject) = MockResponse.Builder().code(code).body(body.toString()).build()

    private fun take(path: String, token: String?): RecordedRequest {
        val request = checkNotNull(server.takeRequest(3, SECONDS))
        assertEquals(path, request.url.encodedPath)
        assertEquals(token?.let { "Bearer $it" }, request.headers["Authorization"])
        return request
    }

    private fun reservation(id: UUID, mediaType: String) = JSONObject().put("asset_id", id.toString())
        .put("upload_url", server.url("/storage/$id?cap=fixture").toString())
        .put("upload_headers", JSONObject().put("Content-Type", mediaType).put("x-upsert", "false"))
        .put("expires_at", Instant.now().plusSeconds(3600).toString())

    private fun verified(id: UUID, mediaType: String, bytes: ByteArray) =
        JSONObject().put("asset_id", id.toString()).put("status", "ready").put("media_type", mediaType)
            .put("size_bytes", bytes.size).put("sha256", sha256(bytes))

    private fun auth(id: UUID, refresh: String, expired: Boolean = false): JSONObject {
        val exp = Instant.now().plusSeconds(if (expired) -60 else 3600).epochSecond
        val claims = JSONObject().put("sub", id.toString()).put("role", "authenticated")
            .put("exp", exp).put("jti", UUID.randomUUID().toString())
        val payload = Base64.encodeToString(claims.toString().toByteArray(), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        return JSONObject().put("access_token", "fixture.$payload.signature").put("token_type", "bearer")
            .put("expires_in", 3600).put("refresh_token", refresh)
            .put("user", JSONObject().put("id", id.toString()).put("email", "$id@example.test"))
    }

    private fun content(id: UUID, owner: UUID, source: JSONObject, asset: UUID? = null): JSONObject =
        JSONObject().put("id", id.toString()).put("user_id", owner.toString())
            .put("input_type", source.getString("input_type"))
            .put("source_text", source.stringOrNull("source_text") ?: JSONObject.NULL)
            .put("source_url", source.stringOrNull("source_url") ?: JSONObject.NULL)
            .put("asset_ids", JSONArray(listOfNotNull(asset?.toString())))
            .put("title", JSONObject.NULL).put("user_note", JSONObject.NULL)
            .put("analysis_status", "pending").put("workflow_status", "pending").put("version", 1)
            .put("created_at", TIMESTAMP).put("updated_at", TIMESTAMP)
            .put("analysis", JSONObject.NULL).put("recommendations", JSONArray())
            .put(
                "notification", JSONObject().put("content_id", id.toString()).put("visibility", "active")
                    .put("generation", 1).put("revision", 1).put("updated_at", TIMESTAMP),
            )

    private fun error(code: String) = JSONObject().put(
        "error", JSONObject().put("code", code).put("message", "Synthetic failure")
            .put("request_id", UUID.randomUUID().toString()),
    )

    private companion object {
        val USER_A = UUID.fromString("71fdb950-9220-439c-bd16-61613bc91dbb")
        val USER_B = UUID.fromString("4c50471f-bccb-4ddb-8e4c-a241b12fb70a")
        val PDF = "%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF\n".toByteArray()
        const val TIMESTAMP = "2026-11-10T00:00:00Z"
        const val PUBLISHABLE = "sb_publishable_test_fixture"
    }
}

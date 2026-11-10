package com.itda.itda_mobile

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.os.Build
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NoticeLifecycleTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val directory = File(context.cacheDir, "notices-${UUID.randomUUID()}")
    private val store = NoticeStore(directory)
    private val ownerA = UploadOwner(UUID.randomUUID(), "a".repeat(64))
    private val ownerB = UploadOwner(UUID.randomUUID(), ownerA.realm)
    private val ref = NoticeRef(ownerA, UUID.randomUUID())
    private var owner: UploadOwner? = ownerA
    private val surface = TestSurface()

    @After
    fun cleanup() {
        directory.deleteRecursively()
    }

    @Test
    fun oneCardPerContentWithInPlaceUpdatesAndOutOfOrderResults() {
        val lifecycle = reopen()
        lifecycle.observe(ref, snapshot())
        lifecycle.observe(ref, snapshot())
        lifecycle.observe(ref, snapshot(analysis = NoticeAnalysis.PARTIAL, revision = 2, version = 2))
        lifecycle.observe(ref, snapshot())
        lifecycle.observe(ref, snapshot(analysis = NoticeAnalysis.FAILED, revision = 3, version = 3))
        lifecycle.observe(ref, snapshot(analysis = NoticeAnalysis.COMPLETED, revision = 4, version = 4))
        assertEquals(listOf(false, true, true, true), surface.updates)
        assertEquals(setOf(ref), surface.active.keys)
        assertEquals(PostedNotice(1, NoticeAnalysis.COMPLETED), surface.active[ref])
    }

    @Test
    fun offlineDismissalAndIdempotencySurviveRestartAndDelayedAnalysis() {
        var lifecycle = reopen()
        lifecycle.observe(ref, snapshot())
        surface.active.remove(ref)
        assertTrue(lifecycle.dismiss(ref, 1))
        val event = checkNotNull(store.read(ref)?.event)
        lifecycle = reopen()
        assertFalse(lifecycle.dismiss(ref, 1))
        assertEquals(event, store.read(ref)?.event)
        assertFalse(lifecycle.requestRestore(ref))
        lifecycle.observe(ref, snapshot(analysis = NoticeAnalysis.COMPLETED, revision = 2, version = 2))
        assertTrue(checkNotNull(store.read(ref)).suppressed)
        assertEquals(event, store.read(ref)?.event)
        assertEquals(listOf(false), surface.updates)
        assertNull(surface.active[ref])
    }

    @Test
    fun onlyAcknowledgedRestoreRepostsAndAnOldDeleteCannotHideIt() {
        val lifecycle = reopen()
        lifecycle.observe(ref, snapshot())
        assertTrue(lifecycle.dismiss(ref, 1))
        val dismiss = checkNotNull(store.read(ref)?.event)
        lifecycle.acknowledge(ref, dismiss, snapshot(dismissed = true, revision = 2))
        assertNull(store.read(ref)?.event)
        assertTrue(lifecycle.requestRestore(ref))
        val restore = checkNotNull(store.read(ref)?.event)
        assertNotEquals(dismiss.key, restore.key)
        assertFalse(lifecycle.requestRestore(ref))
        assertNull(surface.active[ref])

        val restored = snapshot(generation = 2, revision = 3)
        reopen().acknowledge(ref, restore, restored)
        assertFalse(lifecycle.dismiss(ref, 1))
        lifecycle.observe(ref, snapshot(dismissed = true, revision = 9))
        lifecycle.observe(ref, restored)
        assertEquals(2L, surface.activeGeneration(ref))
        assertEquals(listOf(false, false), surface.updates)
        assertNull(store.read(ref)?.event)
    }

    @Test
    fun conflictRebasesOnlyDismissalWithinTheSameGeneration() {
        val lifecycle = reopen()
        lifecycle.observe(ref, snapshot())
        assertTrue(lifecycle.dismiss(ref, 1))
        val original = checkNotNull(store.read(ref)?.event)
        assertTrue(lifecycle.resolveConflict(ref, original, snapshot(revision = 2)))
        val rebased = checkNotNull(store.read(ref)?.event)
        assertEquals(2L, rebased.revision)
        assertNotEquals(original.key, rebased.key)
        assertNull(surface.active[ref])
        lifecycle.acknowledge(ref, rebased, snapshot(dismissed = true, revision = 3))

        assertTrue(lifecycle.requestRestore(ref))
        val restore = checkNotNull(store.read(ref)?.event)
        assertFalse(lifecycle.resolveConflict(ref, restore, snapshot(dismissed = true, revision = 4)))
        assertNull(store.read(ref)?.event)
        assertNull(surface.active[ref])
        assertTrue(lifecycle.requestRestore(ref))
        assertEquals(4L, store.read(ref)?.event?.revision)
    }

    @Test
    fun permissionDenialLeavesAnUnissuedCardEligibleAfterGrant() {
        surface.enabled = false
        reopen().observe(ref, snapshot())
        assertNull(store.read(ref)?.posted)
        assertNull(surface.active[ref])
        surface.enabled = true
        reopen().observe(ref, snapshot())
        assertEquals(listOf(false), surface.updates)
        assertEquals(1L, surface.activeGeneration(ref))
    }

    @Test
    fun accountSwitchAndProgrammaticCancellationLeaveVisibilityAndEventsAlone() {
        val lifecycle = reopen()
        lifecycle.observe(ref, snapshot())
        owner = ownerB
        lifecycle.hideInactiveAccounts()
        assertNull(surface.active[ref])
        assertNull(store.read(ref)?.event)
        assertFalse(checkNotNull(store.read(ref)).suppressed)
        lifecycle.observe(ref, snapshot(analysis = NoticeAnalysis.COMPLETED, revision = 2, version = 2))
        assertEquals(NoticeAnalysis.PENDING, store.read(ref)?.content?.analysis)
        assertThrows(UploadProblem::class.java) { lifecycle.requestRestore(ref) }
        val second = NoticeRef(ownerB, ref.contentId)
        lifecycle.observe(second, snapshot())
        assertNotEquals(ref.tag, second.tag)
        assertEquals(setOf(second), surface.active.keys)
        owner = null
        lifecycle.hideInactiveAccounts()
        assertTrue(surface.active.isEmpty())
        owner = ownerA
        lifecycle.observe(ref, snapshot(analysis = NoticeAnalysis.COMPLETED, revision = 2, version = 2))
        assertTrue(surface.active.isEmpty())
        assertNull(store.read(ref)?.event)
    }

    @Test
    fun interruptionAfterIssuanceCommitCannotRepostAMissingCard() {
        surface.failPost = true
        assertThrows(IOException::class.java) { reopen().observe(ref, snapshot()) }
        assertEquals(1L, store.read(ref)?.posted?.generation)
        surface.failPost = false
        reopen().observe(ref, snapshot(analysis = NoticeAnalysis.COMPLETED, revision = 2, version = 2))
        assertTrue(surface.updates.isEmpty())
        assertNull(surface.active[ref])
    }

    @Test
    fun androidCardHasStableIdentityAndOneImmutableEditAction() {
        grantNotificationPermission()
        val android = AndroidNoticeSurface(context, mock = true)
        val manager = checkNotNull(context.getSystemService(NotificationManager::class.java))
        val lifecycle = NoticeLifecycle(store, android, { owner })
        val previousLanguage = AppLanguage.get(context)
        try {
            AppLanguage.set(context, "ko")
            val metadata = NoticeMetadata("url", "Repair cafe", "events.example.test", null)
            lifecycle.observe(ref, snapshot().copy(metadata = metadata))
            val before = awaitCard(manager, NoticeAnalysis.PENDING)
            assertEquals(AndroidNoticeSurface.CHANNEL, before.channelId)
            assertEquals("Repair cafe", before.extras.getCharSequence(Notification.EXTRA_TITLE))
            assertEquals("events.example.test · 모의", before.extras.getCharSequence(Notification.EXTRA_SUB_TEXT))
            assertEquals("처리 중", before.extras.getCharSequence(Notification.EXTRA_TEXT))
            assertEquals(listOf("수정하기"), before.actions.map { it.title.toString() })
            assertNotEquals(before.contentIntent, before.actions.single().actionIntent)
            assertNotEquals(before.contentIntent, before.deleteIntent)
            assertTrue(before.flags and Notification.FLAG_AUTO_CANCEL == 0)
            assertTrue(before.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
            if (Build.VERSION.SDK_INT >= 31) {
                assertTrue(before.contentIntent.isImmutable)
                assertTrue(before.actions.single().actionIntent.isImmutable)
                assertTrue(before.deleteIntent.isImmutable)
            }

            AppLanguage.set(context, "en")
            lifecycle.refreshPresentation(ref)
            val english = awaitCard(manager, NoticeAnalysis.PENDING)
            assertEquals("events.example.test · Mock", english.extras.getCharSequence(Notification.EXTRA_SUB_TEXT))
            assertEquals(listOf("Edit"), english.actions.map { it.title.toString() })
            assertEquals(before.contentIntent, english.contentIntent)
            assertEquals("Saved on this device", AppLanguage.resources(context.applicationContext).getString(R.string.share_saved))

            lifecycle.observe(ref, snapshot(analysis = NoticeAnalysis.PARTIAL, revision = 2, version = 2)
                .copy(metadata = metadata.copy(title = "Updated title")))
            val after = awaitCard(manager, NoticeAnalysis.PARTIAL)
            assertEquals("Updated title", after.extras.getCharSequence(Notification.EXTRA_TITLE))
            assertEquals(before.contentIntent, after.contentIntent)
            assertEquals(before.deleteIntent, after.deleteIntent)
            android.cancel(ref)
            awaitCondition { android.activeGeneration(ref) == null }
            AppLanguage.set(context, "ko")
            lifecycle.refreshPresentation(ref)
            assertNull(android.activeGeneration(ref))
            assertNull(store.read(ref)?.event)
        } finally {
            android.cancel(ref)
            AppLanguage.set(context, previousLanguage)
        }
    }

    @Test
    fun legacyNoticeHydratesSafeMetadataWithoutLosingSuppression() {
        val event = NoticeEvent(NoticeOperation.DISMISS, 1, 1)
        val original = NoticeRecord(ref, snapshot(), dismissedGeneration = 1,
            event = event, posted = PostedNotice(1, NoticeAnalysis.PENDING))
        val legacy = NoticeRecord.fromJson(original.toJson())
        val link = "https://events.example.test/calendar?access_token=synthetic"
        val response = JSONObject().put("input_type", "url").put("title", link)
            .put("source_url", link).put("source_text", "Private source text")
        val receipt = JSONObject().put("subject", "Community calendar").put("source_package", "com.example.sender")
        val metadata = NoticeMetadata.fromContent(response, receipt)
        assertEquals("Community calendar", metadata.title)
        assertEquals("events.example.test", metadata.host)
        assertEquals("com.example.sender", metadata.sourcePackage)
        assertFalse(metadata.toJson().toString().contains("access_token"))
        assertFalse(metadata.toJson().toString().contains("Private source text"))
        assertEquals("My saved title", NoticeMetadata.fromContent(response.put("title", "My saved title"), receipt).title)
        assertNull(NoticeMetadata.fromContent(response.put("title", "Bearer synthetic"), null).title)
        val merged = legacy.mergeContent(snapshot().copy(metadata = metadata))
        assertEquals(metadata, NoticeRecord.fromJson(merged.toJson()).content.metadata)
        assertEquals(original.posted, merged.posted)
        assertEquals(event, merged.event)
        assertTrue(merged.suppressed)
    }

    @Test
    fun androidDeleteIntentPersistsDismissalWhileProgrammaticCancelDoesNot() {
        grantNotificationPermission()
        val root = File(context.noBackupFilesDir, "notification-inbox-v1")
        val nativeStore = NoticeStore(root)
        val android = AndroidNoticeSurface(context, mock = true)
        val manager = checkNotNull(context.getSystemService(NotificationManager::class.java))
        val swipeRef = NoticeRef(ownerA, UUID.randomUUID())
        try {
            fun show(target: NoticeRef): Notification {
                val record = NoticeRecord(target, snapshot(), posted = PostedNotice(1, NoticeAnalysis.PENDING))
                nativeStore.write(record)
                android.post(record, update = false)
                return awaitCard(manager, NoticeAnalysis.PENDING, target)
            }
            show(ref)
            android.cancel(ref)
            awaitCondition { android.activeGeneration(ref) == null }
            assertNull(nativeStore.read(ref)?.event)

            show(swipeRef).deleteIntent.send()
            awaitCondition { nativeStore.read(swipeRef)?.event != null }
            val saved = checkNotNull(nativeStore.read(swipeRef))
            assertEquals(1L, saved.dismissedGeneration)
            assertEquals(NoticeOperation.DISMISS, saved.event?.operation)
            awaitCondition { android.activeGeneration(swipeRef) == null }
            assertNull(nativeStore.read(ref)?.event)
        } finally {
            for (target in listOf(ref, swipeRef)) {
                android.cancel(target)
                File(root, sha256(target.tag.toByteArray()) + ".json").delete()
            }
        }
    }

    private fun grantNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private fun awaitCondition(condition: () -> Boolean) {
        repeat(100) {
            if (condition()) return
            SystemClock.sleep(50)
        }
        error("Android did not complete the notification operation")
    }

    private fun awaitCard(
        manager: NotificationManager,
        analysis: NoticeAnalysis,
        target: NoticeRef = ref,
    ): Notification {
        repeat(60) {
            val card = manager.activeNotifications.filter { it.tag == target.tag }.singleOrNull()
            if (card?.notification?.extras?.getCharSequence(Notification.EXTRA_TEXT) ==
                AppLanguage.resources(context).getString(analysis.message)
            ) {
                assertEquals(AndroidNoticeSurface.ANDROID_ID, card.id)
                return card.notification
            }
            SystemClock.sleep(50)
        }
        error("Android did not display the expected notification")
    }

    private fun reopen() = NoticeLifecycle(NoticeStore(directory), surface, { owner })

    private fun snapshot(
        generation: Long = 1,
        revision: Long = 1,
        dismissed: Boolean = false,
        analysis: NoticeAnalysis = NoticeAnalysis.PENDING,
        version: Long = 1,
    ) = NoticeContent(NoticeState(generation, revision, dismissed), analysis, version, Instant.EPOCH)

    private class TestSurface : NoticeSurface {
        var enabled = true
        var failPost = false
        val active = mutableMapOf<NoticeRef, PostedNotice>()
        val updates = mutableListOf<Boolean>()
        override fun canPost() = enabled
        override fun activeGeneration(ref: NoticeRef) = active[ref]?.generation
        override fun post(record: NoticeRecord, update: Boolean) {
            if (failPost) throw IOException("Interrupted before Android received the card")
            updates.add(update)
            active[record.ref] = PostedNotice(record.state.generation, record.content.analysis)
        }
        override fun cancel(ref: NoticeRef) {
            active.remove(ref)
        }
        override fun hideOtherOwners(owner: UploadOwner?) {
            active.keys.removeAll { it.owner != owner }
        }
    }
}

package com.itda.itda_mobile

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.util.concurrent.Executors

internal enum class NoticeDestination(val wire: String) {
    DETAILS("details"), EDIT("edit"), DISMISS("dismiss");
}

internal data class NoticeLink(val ref: NoticeRef, val generation: Long, val destination: NoticeDestination)

internal object NoticeIntents {
    private const val ACTION_OPEN = "com.itda.itda_mobile.OPEN_NOTICE"
    private const val ACTION_DISMISS = "com.itda.itda_mobile.DISMISS_NOTICE"

    fun pending(context: Context, ref: NoticeRef, generation: Long, destination: NoticeDestination): PendingIntent {
        val data = Uri.Builder().scheme("itda").authority("notice")
            .appendPath(ref.owner.realm).appendPath(ref.owner.userId.toString())
            .appendPath(ref.contentId.toString()).appendPath(generation.toString())
            .appendPath(destination.wire).build()
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        if (destination == NoticeDestination.DISMISS) {
            val intent = Intent(context, NoticeDismissReceiver::class.java).setAction(ACTION_DISMISS).setData(data)
            return PendingIntent.getBroadcast(context, 0, intent, flags)
        }
        val intent = Intent(context, MainActivity::class.java).setAction(ACTION_OPEN).setData(data)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, 0, intent, flags)
    }

    fun parse(intent: Intent): NoticeLink? {
        val uri = intent.data ?: return null
        if (uri.scheme != "itda" || uri.authority != "notice") return null
        val parts = uri.pathSegments
        if (parts.size != 5 || !parts[0].matches(Regex("[a-f0-9]{64}"))) return null
        val destination = NoticeDestination.entries.firstOrNull { it.wire == parts[4] } ?: return null
        val expectedAction = if (destination == NoticeDestination.DISMISS) ACTION_DISMISS else ACTION_OPEN
        if (intent.action != expectedAction) return null
        return try {
            val owner = UploadOwner(parseUuid(parts[1]), parts[0])
            val generation = parts[3].toLong().also { require(it >= 1) }
            NoticeLink(NoticeRef(owner, parseUuid(parts[2])), generation, destination)
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

class NoticeDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val link = NoticeIntents.parse(intent)?.takeIf { it.destination == NoticeDestination.DISMISS } ?: return
        val pending = goAsync()
        val appContext = context.applicationContext
        dismissalIo.execute {
            try {
                AndroidOutbox.get(appContext).notices.dismiss(link)
            } catch (_: Exception) {
                // The issued-generation ledger still prevents re-posting a missing card.
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        val dismissalIo = Executors.newSingleThreadExecutor()
    }
}

internal class AndroidNoticeSurface(private val context: Context, private val mock: Boolean) : NoticeSurface {
    private val manager = checkNotNull(context.getSystemService(NotificationManager::class.java))

    override fun canPost(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, context.getString(R.string.notice_channel), NotificationManager.IMPORTANCE_DEFAULT),
            )
            return manager.getNotificationChannel(CHANNEL)?.let {
                it.importance != NotificationManager.IMPORTANCE_NONE
            } == true
        }
        return true
    }

    override fun activeGeneration(ref: NoticeRef): Long? = manager.activeNotifications
        .firstOrNull { it.tag == ref.tag && it.id == ANDROID_ID }
        ?.notification?.extras?.getLong(GENERATION)

    @SuppressLint("MissingPermission") // canPost checks POST_NOTIFICATIONS and channel settings.
    override fun post(record: NoticeRecord, update: Boolean) {
        if (!canPost()) return
        val ref = record.ref
        val generation = record.state.generation
        val card = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notice)
            .setContentTitle(if (mock) "ITDA · Mock" else context.applicationInfo.loadLabel(context.packageManager))
            .setContentText(record.content.analysis.text)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setContentIntent(NoticeIntents.pending(context, ref, generation, NoticeDestination.DETAILS))
            .setDeleteIntent(NoticeIntents.pending(context, ref, generation, NoticeDestination.DISMISS))
            .addAction(0, context.getString(R.string.notice_edit), NoticeIntents.pending(context, ref, generation, NoticeDestination.EDIT))
            .addExtras(Bundle().apply { putLong(GENERATION, generation) })
        val notification = card.build()
        // Notify is an upsert. Keep construction outside the final lookup-to-update window.
        if (!update || activeGeneration(ref) == generation) manager.notify(ref.tag, ANDROID_ID, notification)
    }

    override fun cancel(ref: NoticeRef) = manager.cancel(ref.tag, ANDROID_ID)

    override fun hideOtherOwners(owner: UploadOwner?) {
        val prefix = owner?.let { NoticeRef.ownerPrefix(it) }
        for (card in manager.activeNotifications) {
            val tag = card.tag ?: continue
            if (tag.startsWith(NoticeRef.TAG_PREFIX) && (prefix == null || !tag.startsWith(prefix))) {
                manager.cancel(tag, card.id)
            }
        }
    }

    companion object {
        const val CHANNEL = "saved_content"
        const val ANDROID_ID = 1
        private const val GENERATION = "itda_notice_generation"
    }
}

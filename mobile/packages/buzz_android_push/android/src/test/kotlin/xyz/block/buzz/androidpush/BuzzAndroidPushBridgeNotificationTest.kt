package xyz.block.buzz.androidpush

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Drives the production `buzz/push` method channel end to end: Flutter's
 * `showNotification` arguments go through [BuzzAndroidPushBridge] and
 * [BuzzNotificationRenderer] to the notification Android actually posts.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BuzzAndroidPushBridgeNotificationTest {
    private lateinit var context: Application
    private lateinit var messenger: CapturingMessenger

    @BeforeTest
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        registerLaunchActivity()
        messenger = CapturingMessenger()
        BuzzAndroidPushBridge(context).attachMessenger(messenger)
        assertNull(
            messenger.invoke(
                "syncPushSnapshot",
                mapOf("section" to "communities", "communities" to listOf(mapOf("id" to COMMUNITY))),
            ),
        )
    }

    @Test
    fun verifiedPreviewBecomesThePostedNotificationText() {
        assertEquals(true, showNotification("event-preview", preview = " Lunch at noon? "))

        val notification = postedNotification()
        assertEquals("Lunch at noon?", notification.contentText())
        assertEquals("Buzz", notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
    }

    @Test
    fun missingOrMalformedPreviewPostsGenericText() {
        assertEquals(true, showNotification("event-missing", preview = null))
        assertEquals("New message", postedNotification("event-missing").contentText())

        assertEquals(true, showNotification("event-malformed", preview = "line\nbreak"))
        assertEquals("New message", postedNotification("event-malformed").contentText())
    }

    @Test
    fun previewIsHiddenOnTheLockScreen() {
        val preview = "Secret launch plan"
        assertEquals(true, showNotification("event-private", preview = preview))

        val notification = postedNotification()
        assertEquals(preview, notification.contentText())
        assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
        // With no public version Android substitutes a redacted notification;
        // any explicit public version must not carry the preview either.
        notification.publicVersion?.let { assertNotEquals(preview, it.contentText()) }
    }

    private fun showNotification(eventId: String, preview: String?): Any? {
        val arguments = mutableMapOf<String, Any?>(
            "eventId" to eventId,
            "communityId" to COMMUNITY,
            "channelId" to CHANNEL,
        )
        if (preview != null) arguments["preview"] = preview
        return messenger.invoke("showNotification", arguments)
    }

    private fun postedNotification(eventId: String? = null): Notification {
        val manager = shadowOf(context.getSystemService(NotificationManager::class.java))
        if (eventId == null) return manager.allNotifications.single()
        val envelope = requireNotNull(
            BuzzNotificationEnvelope.fromTrustedFields(eventId, COMMUNITY, CHANNEL),
        )
        return requireNotNull(manager.getNotification(buzzNotificationIdFor(envelope)))
    }

    private fun Notification.contentText(): String? =
        extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()

    private fun registerLaunchActivity() {
        val packageManager = shadowOf(context.packageManager)
        val launcher = ComponentName(context.packageName, "$PACKAGE.MainActivity")
        packageManager.addActivityIfNotPresent(launcher)
        packageManager.addIntentFilterForActivity(
            launcher,
            IntentFilter(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_LAUNCHER) },
        )
    }

    /** Stands in for the Flutter engine: dispatches encoded calls to the real handler. */
    private class CapturingMessenger : BinaryMessenger {
        private val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()

        override fun send(channel: String, message: ByteBuffer?) = Unit

        override fun send(
            channel: String,
            message: ByteBuffer?,
            callback: BinaryMessenger.BinaryReply?,
        ) = Unit

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
        ) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }

        override fun setMessageHandler(
            channel: String,
            handler: BinaryMessenger.BinaryMessageHandler?,
            taskQueue: BinaryMessenger.TaskQueue?,
        ) = setMessageHandler(channel, handler)

        /** Returns the decoded success value; a native error throws FlutterException. */
        fun invoke(method: String, arguments: Any?): Any? {
            val handler = requireNotNull(handlers[CHANNEL_NAME]) { "buzz/push is not attached" }
            val codec = StandardMethodCodec.INSTANCE
            val message = codec.encodeMethodCall(MethodCall(method, arguments)).apply { rewind() }
            var reply: ByteBuffer? = null
            handler.onMessage(message) { reply = it }
            val envelope = requireNotNull(reply) { "$method did not reply" }.apply { rewind() }
            return codec.decodeEnvelope(envelope)
        }
    }

    private companion object {
        const val PACKAGE = "xyz.block.buzz.androidpush"
        const val CHANNEL_NAME = "buzz/push"
        const val COMMUNITY = "community-a"
        const val CHANNEL = "channel-a"
    }
}

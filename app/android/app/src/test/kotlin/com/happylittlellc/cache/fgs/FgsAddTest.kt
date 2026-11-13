package com.happylittlellc.cache.fgs

import android.app.Activity
import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.PowerManager
import android.os.SystemClock
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowPowerManager

/**
 * The add service (fgs/): its lifecycle (start, progress, Pause, finish), Android 15's onTimeout, the wake lock, the manifest's
 * type being the constant's, and the notification content: silent channels, the words of wording.md, and no file names or library
 * names in the lock screen's public version.
 *
 * The Dart add is replaced by [FakeRunner] (a real Flutter engine needs the native library); the Dart side has its own tests
 * (test/background/fgs_add_test.dart).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class FgsAddTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val nm: NotificationManager get() = context.getSystemService(NotificationManager::class.java)

    class FakeRunner : FgsAddRunner {
        var started = 0
        var resume: Boolean? = null
        var anyway: Boolean? = null
        var events: FgsAddEvents? = null
        val stops = mutableListOf<String>()
        val releases = mutableListOf<Long>()
        override fun start(resume: Boolean, anyway: Boolean, events: FgsAddEvents) {
            started++
            this.resume = resume
            this.anyway = anyway
            this.events = events
        }
        override fun stop(why: String) { stops += why }
        override fun release(afterMs: Long) { releases += afterMs }
    }

    private lateinit var runner: FakeRunner
    private var controller: ServiceController<FgsAddService>? = null

    @Before
    fun setUp() {
        runner = FakeRunner()
        FgsAddService.runnerFactory = { runner }
        FgsAddArm.armed = false
    }

    @After
    fun tearDown() {
        controller?.destroy()
        FgsAddService.runnerFactory = { DartFgsAddRunner(it) }
        FgsAddArm.armed = false
    }

    private fun start(): FgsAddService {
        val c = Robolectric.buildService(FgsAddService::class.java, FgsAddService.startIntent(context)).create()
        controller = c
        c.startCommand(0, 1)
        return c.get()
    }

    private fun title(n: Notification) = n.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
    private fun text(n: Notification) = n.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
    private fun posted(id: Int): Notification? = nm.activeNotifications.firstOrNull { it.id == id }?.notification

    private val progress = FgsProgress(2, 5, "Radio field manual", 0.4, "Bookshelves", "About 12 min left", "Garden notes and 2 more waiting")

    // ---- the manifest and the channels

    @Test
    fun theManifestsTypeIsTheConstantsType_dataSync() {
        val info = context.packageManager.getServiceInfo(ComponentName(context, FgsAddService::class.java), PackageManager.GET_META_DATA)
        assertEquals(FgsAddService.FGS_TYPE, info.foregroundServiceType and FgsAddService.FGS_TYPE)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC, FgsAddService.FGS_TYPE)
        assertFalse(info.exported)
    }

    @Test
    fun bothChannelsAreSilent() {
        FgsAddNotifications.ensureChannels(context)
        for ((id, name) in listOf(FgsAddNotifications.CHANNEL_ADDING to "Adding PDFs", FgsAddNotifications.CHANNEL_RESULTS to "PDFs added")) {
            val ch = nm.getNotificationChannel(id)
            assertEquals(name, ch.name.toString())
            assertEquals(NotificationManager.IMPORTANCE_LOW, ch.importance)
            assertNull(ch.sound)
            assertFalse(ch.shouldVibrate())
        }
        assertEquals("Shown while Cache adds PDFs in the background", nm.getNotificationChannel(FgsAddNotifications.CHANNEL_ADDING).description)
        assertEquals("Where adding PDFs ended, paused or failed", nm.getNotificationChannel(FgsAddNotifications.CHANNEL_RESULTS).description)
    }

    // ---- the notification content

    @Test
    fun addingSeveral_titleTextBarTimeLeftAndPause() {
        val n = FgsAddNotifications.adding(context, progress)
        assertEquals("Adding PDFs to Bookshelves", title(n))
        assertEquals("2 of 5 PDFs · Radio field manual", text(n))
        assertEquals("About 12 min left", n.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString())
        assertEquals(400, n.extras.getInt(Notification.EXTRA_PROGRESS))
        assertFalse(n.extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE))
        assertTrue(n.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(listOf("Pause"), n.actions.map { it.title.toString() })
        val big = n.extras.getCharSequence(Notification.EXTRA_BIG_TEXT).toString()
        assertTrue(big.endsWith("Garden notes and 2 more waiting"))
        assertEquals(Notification.VISIBILITY_PRIVATE, n.visibility)
    }

    @Test
    fun addingOne_usesTheAddPdfWords_andTheBarIsIndeterminateUntilTheFirstEstimate() {
        val n = FgsAddNotifications.adding(context, FgsProgress(0, 1, "Radio field manual", null, "Bookshelves", null, null))
        assertEquals("Adding a PDF", title(n))
        assertEquals("Radio field manual", text(n))
        assertTrue(n.extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE))
        assertTrue(FgsAddNotifications.adding(context, null).extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE))
    }

    @Test
    fun aNamedLibraryKeepsItsName() {
        val n = FgsAddNotifications.adding(context, progress.copy(library = "Field"))
        assertEquals("Adding PDFs to Field", title(n))
    }

    @Test
    fun lockScreen_noFileNamesAndNoLibraryNames_onEveryNotification() {
        val finishes = listOf(
            FgsFinish("added", null, 5, 5, 5, 0, null, false, "Field", null, null, null),
            FgsFinish("failed", null, 1, 1, 0, 1, null, false, "Field", "Radio field manual", "This PDF could not be added", "Nothing was added. Your PDF was not changed."),
            FgsFinish("paused", "person", 2, 5, 2, 0, null, false, "Field", null, null, null),
            FgsFinish("paused", "battery", 2, 5, 2, 0, 12, false, "Field", null, null, null),
        )
        val all = listOf(FgsAddNotifications.adding(context, progress.copy(library = "Field"))) + finishes.map { FgsAddNotifications.ended(context, it)!! }
        for (n in all) {
            val pub = n.publicVersion
            assertNotNull(pub)
            val said = (title(pub) + " " + text(pub))
            for (secret in listOf("Radio field manual", "Garden notes", "Field", "Bookshelves")) assertFalse("$secret on the lock screen: $said", said.contains(secret))
        }
        assertEquals("Adding PDFs", title(all[0].publicVersion))
        assertEquals("In the background", text(all[0].publicVersion))
        assertEquals("PDFs added", title(all[1].publicVersion))
        assertEquals("Open Cache to see them", text(all[1].publicVersion))
    }

    @Test
    fun endedNotifications_theWordsOfWordingMd() {
        fun f(kind: String, why: String? = null, done: Int = 0, total: Int = 0, added: Int = 0, failed: Int = 0, battery: Int? = null, warm: Boolean = false, name: String? = null, ft: String? = null, fb: String? = null) =
            FgsAddNotifications.ended(context, FgsFinish(kind, why, done, total, added, failed, battery, warm, "Bookshelves", name, ft, fb))!!
        f("added", added = 5, total = 5).let { assertEquals("Added 5 PDFs to Bookshelves", title(it)); assertEquals("Adding to search index", text(it)) }
        assertEquals("Added to Bookshelves", title(f("added", added = 1, total = 1)))
        f("failed", added = 4, total = 5, failed = 1).let { assertEquals("Added 4 of 5 PDFs to Bookshelves", title(it)); assertEquals("1 could not be added · tap to see", text(it)) }
        f("failed", failed = 1, total = 1, name = "Radio field manual", ft = "This PDF could not be added", fb = "Nothing was added. Your PDF was not changed.").let {
            assertEquals("This PDF could not be added", title(it))
            assertEquals("Radio field manual · Nothing was added. Your PDF was not changed.", text(it))
        }
        assertEquals("3 PDFs could not be added", title(f("failed", failed = 3, total = 3)))
        f("paused", "person", done = 2, total = 5).let {
            assertEquals("Paused · 2 of 5 PDFs", title(it)); assertEquals("Paused by you", text(it)); assertEquals(listOf("Resume"), it.actions.map { a -> a.title.toString() })
        }
        f("paused", "battery", done = 2, total = 5, battery = 12).let {
            assertEquals("Battery low (12%) · plug in to continue", text(it)); assertEquals(listOf("Resume anyway"), it.actions.map { a -> a.title.toString() })
        }
        assertEquals("Device is warm", text(f("paused", "heat", done = 1, total = 2, warm = true)))
        f("paused", "timeout", done = 2, total = 5).let {
            assertEquals("Android limits background work. It carries on while charging, or open Cache.", text(it)); assertTrue(it.actions.isNullOrEmpty())
        }
        // not ongoing: the person can swipe it away; and nothing is posted for a run that never started
        assertEquals(0, f("added", added = 1, total = 1).flags and Notification.FLAG_ONGOING_EVENT)
        assertNull(FgsAddNotifications.ended(context, FgsFinish("none", null, 0, 0, 0, 0, null, false, "Bookshelves", null, null, null)))
    }

    @Test
    fun pauseAndResumeActions_goToTheService_andResumeIsAForegroundStart() {
        val pause = FgsAddNotifications.adding(context, progress).actions.single().actionIntent
        val pi = shadowOf(pause).savedIntent
        assertEquals(FgsAddService::class.java.name, pi.component?.className)
        assertEquals(FgsAddNotifications.ACTION_PAUSE, pi.action)
        val resume = FgsAddNotifications.ended(context, FgsFinish("paused", "battery", 2, 5, 2, 0, 12, false, "Bookshelves", null, null, null))!!.actions.single().actionIntent
        val ri = shadowOf(resume).savedIntent
        assertEquals(FgsAddNotifications.ACTION_START, ri.action)
        assertTrue(ri.getBooleanExtra(FgsAddNotifications.EXTRA_RESUME, false))
        assertTrue(ri.getBooleanExtra(FgsAddNotifications.EXTRA_ANYWAY, false))
        assertTrue(shadowOf(resume).isForegroundService)
    }

    // ---- the lifecycle

    @Test
    fun start_goesForeground_withTheNotification_holdsAWakeLock_andStartsTheRun() {
        val s = start()
        assertEquals(1, runner.started)
        assertEquals(false, runner.resume)
        assertEquals(FgsAddNotifications.ID_ADDING, shadowOf(s).lastForegroundNotificationId)
        assertEquals("Adding a PDF", title(shadowOf(s).lastForegroundNotification))
        val wake = ShadowPowerManager.getLatestWakeLock()
        assertNotNull(wake)
        assertTrue(wake.isHeld)
        assertTrue(FgsAddService.running)
        // started again (a second Back, a second Home): one run
        controller!!.startCommand(0, 2)
        assertEquals(1, runner.started)
    }

    @Test
    fun resume_startsTheRunWithResume() {
        val c = Robolectric.buildService(
            FgsAddService::class.java,
            FgsAddService.startIntent(context).putExtra(FgsAddNotifications.EXTRA_RESUME, true).putExtra(FgsAddNotifications.EXTRA_ANYWAY, true),
        ).create()
        controller = c
        c.startCommand(0, 1)
        assertEquals(true, runner.resume)
        assertEquals(true, runner.anyway)
    }

    @Test
    fun progress_updatesTheNotification_atMostOnceASecond() {
        start()
        runner.events!!.onProgress(progress)
        assertEquals("2 of 5 PDFs · Radio field manual", text(posted(FgsAddNotifications.ID_ADDING)!!))
        runner.events!!.onProgress(progress.copy(done = 3, current = "Garden notes"))
        assertEquals("2 of 5 PDFs · Radio field manual", text(posted(FgsAddNotifications.ID_ADDING)!!))
        SystemClock.sleep(1100)
        runner.events!!.onProgress(progress.copy(done = 3, current = "Garden notes"))
        assertEquals("3 of 5 PDFs · Garden notes", text(posted(FgsAddNotifications.ID_ADDING)!!))
    }

    @Test
    fun pause_inTheNotification_asksTheRunToStopAsPerson() {
        val s = start()
        s.onStartCommand(android.content.Intent(context, FgsAddService::class.java).setAction(FgsAddNotifications.ACTION_PAUSE), 0, 2)
        assertEquals(listOf("person"), runner.stops)
        assertEquals(1, runner.started)
    }

    @Test
    fun finished_endsTheForegroundNotification_postsTheResult_releasesTheWakeLock_andStops() {
        val s = start()
        runner.events!!.onProgress(progress)
        runner.events!!.onFinished(FgsFinish("added", null, 5, 5, 5, 0, null, false, "Bookshelves", null, null, null))
        assertNull(posted(FgsAddNotifications.ID_ADDING))
        assertEquals("Added 5 PDFs to Bookshelves", title(posted(FgsAddNotifications.ID_RESULT)!!))
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertTrue(shadowOf(s).isStoppedBySelf)
        assertFalse(FgsAddService.running)
        assertEquals(listOf(0L), runner.releases)
    }

    @Test
    fun finishedWithNothingStarted_postsNothing() {
        val s = start()
        runner.events!!.onFinished(FgsFinish("none", "battery", 0, 0, 0, 0, 5, false, "Bookshelves", null, null, null))
        assertNull(posted(FgsAddNotifications.ID_RESULT))
        assertTrue(shadowOf(s).isStoppedBySelf)
    }

    @Test
    fun onTimeout_asksTheRunToSave_stopsAtOnce_postsThePausedLimitNotice_andKeepsTheEngineAMoment() {
        val s = start()
        runner.events!!.onProgress(progress)
        s.onTimeout(1, FgsAddService.FGS_TYPE)
        assertEquals(listOf("timeout"), runner.stops)
        assertTrue(shadowOf(s).isStoppedBySelf)
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        val n = posted(FgsAddNotifications.ID_RESULT)!!
        assertEquals("Paused · 2 of 5 PDFs", title(n))
        assertEquals("Android limits background work. It carries on while charging, or open Cache.", text(n))
        assertEquals(listOf(FgsAddService.ENGINE_GRACE_MS), runner.releases)
        assertNull(posted(FgsAddNotifications.ID_ADDING))
        // what the run says after that does not replace it
        runner.events!!.onFinished(FgsFinish("paused", "person", 3, 5, 3, 0, null, false, "Bookshelves", null, null, null))
        assertEquals("Paused · 2 of 5 PDFs", title(posted(FgsAddNotifications.ID_RESULT)!!))
    }

    @Test
    fun destroyed_releasesTheWakeLock() {
        start()
        controller!!.destroy()
        controller = null
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertFalse(FgsAddService.running)
    }

    // ---- starting as the person leaves

    private fun activity(): Activity = Robolectric.buildActivity(Activity::class.java).create().get()

    @Test
    fun leaving_startsTheServiceOnlyWhenArmed() {
        val a = activity()
        assertFalse(FgsAddArm.onLeave(a))
        assertNull(shadowOf(a.application).nextStartedService)
        FgsAddArm.armed = true
        assertTrue(FgsAddArm.onLeave(a))
        val started = shadowOf(a.application).nextStartedService
        assertEquals(FgsAddService::class.java.name, started.component?.className)
        assertEquals(FgsAddNotifications.ACTION_START, started.action)
    }
}

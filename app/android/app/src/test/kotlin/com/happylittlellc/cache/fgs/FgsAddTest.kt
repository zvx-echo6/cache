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
        FgsAddArm.reset()
    }

    @After
    fun tearDown() {
        controller?.destroy()
        FgsAddService.runnerFactory = { DartFgsAddRunner(it) }
        FgsAddArm.reset()
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
        for ((id, name) in listOf(FgsAddNotifications.CHANNEL_ADDING to "Adding and downloading", FgsAddNotifications.CHANNEL_RESULTS to "PDFs added")) {
            val ch = nm.getNotificationChannel(id)
            assertEquals(name, ch.name.toString())
            assertEquals(NotificationManager.IMPORTANCE_LOW, ch.importance)
            assertNull(ch.sound)
            assertFalse(ch.shouldVibrate())
        }
        assertEquals("Shown while Cache adds PDFs or downloads regions in the background", nm.getNotificationChannel(FgsAddNotifications.CHANNEL_ADDING).description)
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
        f("failed", added = 4, total = 5, failed = 1).let { assertEquals("Added 4 of 5 PDFs to Bookshelves", title(it)); assertEquals("1 could not be added", text(it)) }
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
    fun testHook_isNotInTheReleaseManifest_andTheServiceIsNotExported() {
        // the unit tests merge the manifest of a build without -PcacheTestApk: the hook is declared only in the test APK
        val pm = context.packageManager
        try {
            pm.getReceiverInfo(ComponentName(context, FgsAddTestHook::class.java), 0)
            org.junit.Assert.fail("the test hook receiver is in the release manifest")
        } catch (_: PackageManager.NameNotFoundException) {
        }
        assertFalse(pm.getServiceInfo(ComponentName(context, FgsAddService::class.java), 0).exported)
    }

    @Test
    fun testHook_sendsTheServiceTheNotificationsPause_andResume() {
        FgsAddTestHook().onReceive(context, android.content.Intent(FgsAddTestHook.ACTION_PAUSE))
        val app = shadowOf(RuntimeEnvironment.getApplication())
        assertEquals(FgsAddNotifications.ACTION_PAUSE, app.nextStartedService.action)
        FgsAddTestHook().onReceive(context, android.content.Intent(FgsAddTestHook.ACTION_RESUME_ANYWAY))
        val resume = app.nextStartedService
        assertEquals(FgsAddNotifications.ACTION_START, resume.action)
        assertTrue(resume.getBooleanExtra(FgsAddNotifications.EXTRA_RESUME, false))
        assertTrue(resume.getBooleanExtra(FgsAddNotifications.EXTRA_ANYWAY, false))
    }

    @Test
    fun pause_inTheNotification_asksTheRunToStopAsPerson() {
        val s = start()
        s.onStartCommand(android.content.Intent(context, FgsAddService::class.java).setAction(FgsAddNotifications.ACTION_PAUSE), 0, 2)
        assertEquals(listOf("person"), runner.stops)
        assertEquals(1, runner.started)
    }

    @Test
    fun pause_inTheNotification_saysPausedAtOnce_andProgressDoesNotPutAddingBack() {
        val s = start()
        runner.events!!.onProgress(progress)
        s.onStartCommand(android.content.Intent(context, FgsAddService::class.java).setAction(FgsAddNotifications.ACTION_PAUSE), 0, 2)
        val n = posted(FgsAddNotifications.ID_ADDING)!!
        assertEquals("Paused · 2 of 5 PDFs", title(n))
        assertEquals("Paused by you", text(n))
        assertTrue(n.actions == null || n.actions.isEmpty())
        SystemClock.sleep(1100)
        runner.events!!.onProgress(progress.copy(done = 3, current = "Garden notes"))
        assertEquals("Paused · 2 of 5 PDFs", title(posted(FgsAddNotifications.ID_ADDING)!!))
        runner.events!!.onFinished(FgsFinish("paused", "person", 2, 5, 0, 0, null, false, "Bookshelves", null, null, null))
        assertEquals("Paused · 2 of 5 PDFs", title(posted(FgsAddNotifications.ID_RESULT)!!))
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

    // ---- leaving: what counts (Pixel, 2026-11-14)

    @Test
    fun theAppsOwnPicker_isNotALeave_butAHomeLaterIs() {
        val a = activity()
        FgsAddArm.armed = true
        FgsAddArm.noteInternalLaunch(now = 1_000)
        // the leave hint that the launch itself causes, right after it
        assertFalse(FgsAddArm.onLeave(a, FgsAddArm.Leave.HINT, now = 1_400))
        // the pause and stop that follow, while the picker is up
        assertFalse(FgsAddArm.onLeave(a, FgsAddArm.Leave.STOP, now = 2_000))
        assertFalse(FgsAddArm.onLeave(a, FgsAddArm.Leave.PAUSED, now = 9_000))
        assertNull(shadowOf(a.application).nextStartedService)
        // the person is back (onResume), and later presses Home
        FgsAddArm.resumed()
        assertTrue(FgsAddArm.onLeave(a, FgsAddArm.Leave.HINT, now = 20_000))
    }

    @Test
    fun aHintLongAfterTheLaunch_isARealLeave_evenIfTheLaunchNeverPausedTheApp() {
        val a = activity()
        FgsAddArm.armed = true
        FgsAddArm.noteInternalLaunch(now = 1_000)
        assertTrue(FgsAddArm.onLeave(a, FgsAddArm.Leave.HINT, now = 10_000))
    }

    @Test
    fun recents_startsTheService_fromThePausedAppOrItsStop_andTellsTheAppToHandOff() {
        val a = activity()
        var told = 0
        FgsAddArm.tellApp = { told++ }
        FgsAddArm.armed = true
        assertTrue(FgsAddArm.onLeave(a, FgsAddArm.Leave.PAUSED))
        assertEquals(FgsAddService::class.java.name, shadowOf(a.application).nextStartedService.component?.className)
        assertEquals(1, told)
    }

    @Test
    fun notArmed_nothingStarts_andTheAppIsNotTold() {
        val a = activity()
        var told = 0
        FgsAddArm.tellApp = { told++ }
        assertFalse(FgsAddArm.onLeave(a, FgsAddArm.Leave.STOP))
        assertEquals(0, told)
    }

    // ---- region map downloads (layer jobs): the service stays up while EITHER a PDF add OR a region download runs

    private val region = FgsLayerWords("Downloading Austria", "42%", 0.42, 1)

    private fun startLayersOnly(): FgsAddService {
        val c = Robolectric.buildService(FgsAddService::class.java, FgsAddService.startIntent(context, pdf = false, layers = true)).create()
        controller = c
        c.startCommand(0, 1)
        return c.get()
    }

    private fun pausePressed(s: FgsAddService, id: Int = 2) =
        s.onStartCommand(android.content.Intent(context, FgsAddService::class.java).setAction(FgsAddNotifications.ACTION_PAUSE), 0, id)

    @Test
    fun layersNotification_regionWordsBarAndPauseOnly_noRegionNameOnTheLockScreen() {
        val n = FgsAddNotifications.layers(context, region)
        assertEquals("Downloading Austria", title(n))
        assertEquals("42%", text(n))
        assertEquals(420, n.extras.getInt(Notification.EXTRA_PROGRESS))
        assertTrue(n.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(listOf("Pause"), n.actions.map { it.title.toString() })
        val pub = n.publicVersion
        assertFalse((title(pub) + " " + text(pub)).contains("Austria"))
        assertEquals(FgsAddNotifications.CHANNEL_ADDING, n.channelId)
        // nothing known yet: indeterminate, and it still says what it is
        val none = FgsAddNotifications.layers(context, null)
        assertTrue(none.extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE))
        assertEquals("Downloading a region", title(none))
    }

    @Test
    fun layersOnlyStart_goesForeground_startsNoPdfRun_andShowsTheRegion() {
        FgsAddArm.layerProgress(region)
        val s = startLayersOnly()
        assertEquals(0, runner.started)
        assertTrue(FgsAddService.running)
        assertEquals(FgsAddNotifications.ID_ADDING, shadowOf(s).lastForegroundNotificationId)
        assertEquals("Downloading Austria", title(shadowOf(s).lastForegroundNotification))
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
    }

    @Test
    fun layerProgress_updatesTheNotification_atMostOnceASecond() {
        startLayersOnly()
        FgsAddArm.layerProgress(region)
        assertEquals("42%", text(posted(FgsAddNotifications.ID_ADDING)!!))
        FgsAddArm.layerProgress(region.copy(text = "50%", bar = 0.5))
        assertEquals("42%", text(posted(FgsAddNotifications.ID_ADDING)!!))
        SystemClock.sleep(1100)
        FgsAddArm.layerProgress(region.copy(text = "60%", bar = 0.6))
        assertEquals("60%", text(posted(FgsAddNotifications.ID_ADDING)!!))
    }

    @Test
    fun layersEnded_stopsTheService_releasesTheWakeLock_andRemovesTheNotification() {
        val s = startLayersOnly()
        FgsAddArm.layerProgress(region)
        FgsAddArm.armLayers(false)
        assertTrue(shadowOf(s).isStoppedBySelf)
        assertFalse(FgsAddService.running)
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        assertNull(posted(FgsAddNotifications.ID_ADDING))
    }

    @Test
    fun pause_inTheNotification_whileOnlyARegionRuns_asksTheAppToPauseTheLayerJobs() {
        val calls = mutableListOf<String>()
        FgsAddArm.tellLayers = { calls += it }
        val s = startLayersOnly()
        pausePressed(s)
        assertEquals(listOf("layerPause"), calls)
        assertTrue(runner.stops.isEmpty())
        // the app says the jobs ended: the service stops (no Cancel anywhere)
        FgsAddArm.armLayers(false)
        assertTrue(shadowOf(s).isStoppedBySelf)
    }

    @Test
    fun aRegionStartsDuringAPdfAdd_theNotificationShowsThePdf_thenTheRegion_andStopsOnlyWhenBothAreDone() {
        val s = start()
        runner.events!!.onProgress(progress)
        FgsAddArm.layerProgress(region)
        // the PDF add is shown while it runs
        assertEquals("2 of 5 PDFs · Radio field manual", text(posted(FgsAddNotifications.ID_ADDING)!!))
        // the PDF add ends: the service stays up, its result is posted, the ongoing notification is the region's
        runner.events!!.onFinished(FgsFinish("added", null, 5, 5, 5, 0, null, false, "Bookshelves", null, null, null))
        assertFalse(shadowOf(s).isStoppedBySelf)
        assertTrue(FgsAddService.running)
        assertEquals("Added 5 PDFs to Bookshelves", title(posted(FgsAddNotifications.ID_RESULT)!!))
        assertEquals("Downloading Austria", title(posted(FgsAddNotifications.ID_ADDING)!!))
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
        // progress of the region goes on
        SystemClock.sleep(1100)
        FgsAddArm.layerProgress(region.copy(text = "70%", bar = 0.7))
        assertEquals("70%", text(posted(FgsAddNotifications.ID_ADDING)!!))
        // Pause now is the region's
        val calls = mutableListOf<String>()
        FgsAddArm.tellLayers = { calls += it }
        pausePressed(s)
        assertEquals(listOf("layerPause"), calls)
        FgsAddArm.armLayers(false)
        assertTrue(shadowOf(s).isStoppedBySelf)
        assertFalse(FgsAddService.running)
    }

    @Test
    fun aRegionStartsDuringAPdfAdd_theRegionEndsFirst_thePdfAddKeepsTheServiceUp() {
        val s = start()
        FgsAddArm.layerProgress(region)
        FgsAddArm.armLayers(false)
        assertFalse(shadowOf(s).isStoppedBySelf)
        assertTrue(FgsAddService.running)
        assertEquals("Adding a PDF", title(shadowOf(s).lastForegroundNotification))
        runner.events!!.onFinished(FgsFinish("added", null, 1, 1, 1, 0, null, false, "Bookshelves", null, null, null))
        assertTrue(shadowOf(s).isStoppedBySelf)
        assertNull(posted(FgsAddNotifications.ID_ADDING))
    }

    @Test
    fun pause_whileBothRun_pausesThePdfAddFirst() {
        val calls = mutableListOf<String>()
        FgsAddArm.tellLayers = { calls += it }
        val s = start()
        FgsAddArm.layerProgress(region)
        pausePressed(s)
        assertEquals(listOf("person"), runner.stops)
        assertTrue(calls.isEmpty())
    }

    @Test
    fun aPdfAddStartsDuringARegion_theServiceStartsTheRun_andShowsThePdf_thenTheRegion() {
        val s = startLayersOnly()
        FgsAddArm.layerProgress(region)
        assertEquals(0, runner.started)
        // the person came back, started an add, and left again: a start with the PDF run
        s.onStartCommand(FgsAddService.startIntent(context), 0, 2)
        assertEquals(1, runner.started)
        assertEquals("Adding a PDF", title(posted(FgsAddNotifications.ID_ADDING)!!))
        // a second start is still one run
        s.onStartCommand(FgsAddService.startIntent(context), 0, 3)
        assertEquals(1, runner.started)
        // the add ends first: the region stays, and is what the notification shows
        runner.events!!.onFinished(FgsFinish("added", null, 1, 1, 1, 0, null, false, "Bookshelves", null, null, null))
        assertFalse(shadowOf(s).isStoppedBySelf)
        assertEquals("Downloading Austria", title(posted(FgsAddNotifications.ID_ADDING)!!))
        FgsAddArm.armLayers(false)
        assertTrue(shadowOf(s).isStoppedBySelf)
    }

    @Test
    fun aPdfAddStartsDuringARegion_theRegionEndsFirst_thePdfAddKeepsTheServiceUp() {
        val s = startLayersOnly()
        s.onStartCommand(FgsAddService.startIntent(context), 0, 2)
        FgsAddArm.armLayers(false)
        assertFalse(shadowOf(s).isStoppedBySelf)
        assertTrue(FgsAddService.running)
        runner.events!!.onFinished(FgsFinish("added", null, 1, 1, 1, 0, null, false, "Bookshelves", null, null, null))
        assertTrue(shadowOf(s).isStoppedBySelf)
    }

    @Test
    fun onTimeout_whileARegionRuns_pausesTheLayerJobs_andStops() {
        val calls = mutableListOf<String>()
        FgsAddArm.tellLayers = { calls += it }
        val s = startLayersOnly()
        s.onTimeout(1, FgsAddService.FGS_TYPE)
        assertEquals(listOf("layerPause"), calls)
        assertTrue(shadowOf(s).isStoppedBySelf)
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
    }

    @Test
    fun leaving_withARegionRunning_startsAServiceWithNoPdfRun() {
        val a = activity()
        FgsAddArm.armLayers(true)
        assertTrue(FgsAddArm.onLeave(a))
        val started = shadowOf(a.application).nextStartedService
        assertEquals(FgsAddService::class.java.name, started.component?.className)
        assertFalse(started.getBooleanExtra(FgsAddService.EXTRA_PDF, true))
        assertTrue(started.getBooleanExtra(FgsAddService.EXTRA_LAYERS, false))
    }

    @Test
    fun leaving_withBoth_startsOneServiceForBoth() {
        val a = activity()
        FgsAddArm.armed = true
        FgsAddArm.armLayers(true)
        assertTrue(FgsAddArm.onLeave(a))
        val started = shadowOf(a.application).nextStartedService
        assertTrue(started.getBooleanExtra(FgsAddService.EXTRA_PDF, true))
        assertTrue(started.getBooleanExtra(FgsAddService.EXTRA_LAYERS, false))
    }

    @Test
    fun leaving_withAPdfAddArmed_whileTheServiceRunsOnlyForARegion_startsItAgainForThePdf() {
        startLayersOnly()
        val a = activity()
        FgsAddArm.armLayers(true)
        // only the region is armed, and it already runs: nothing to start
        assertFalse(FgsAddArm.onLeave(a))
        FgsAddArm.armed = true
        assertTrue(FgsAddArm.onLeave(a))
        assertTrue(shadowOf(a.application).nextStartedService.getBooleanExtra(FgsAddService.EXTRA_PDF, true))
    }

    @Test
    fun leaving_withARegionArmed_whileTheServiceRunsOnlyForAPdf_startsItAgainForTheRegion() {
        start()
        val a = activity()
        FgsAddArm.armed = true
        assertFalse(FgsAddArm.onLeave(a))
        FgsAddArm.armLayers(true)
        assertTrue(FgsAddArm.onLeave(a))
        assertTrue(shadowOf(a.application).nextStartedService.getBooleanExtra(FgsAddService.EXTRA_LAYERS, false))
    }
}

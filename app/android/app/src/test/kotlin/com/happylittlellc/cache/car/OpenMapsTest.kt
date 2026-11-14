package com.happylittlellc.cache.car

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import com.happylittlellc.cache.MainActivity
import com.happylittlellc.cache.OpenMaps
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Link audit: a tap on the phone's guidance notifications opens Cache's activity asking for the Maps tab (OpenMaps). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class OpenMapsTest {
    private val app: Application get() = RuntimeEnvironment.getApplication()

    private fun assertOpensMaps(pi: PendingIntent?) {
        assertNotNull("the notification has a tap on the phone", pi)
        val i = shadowOf(pi).savedIntent
        assertEquals(MainActivity::class.java.name, i.component?.className)
        assertTrue(shadowOf(pi).isActivityIntent)
        assertTrue(OpenMaps.wants(i))
    }

    @Test
    fun theTurnByTurnNotificationOpensTheMapsTabOnThePhone() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val trip = CarTrip.from(
            mapOf(
                "phase" to "guiding", "available" to true, "units" to "imperial",
                "step" to mapOf("turn" to "left", "type" to "left", "cue" to "Turn left onto Road 1.", "road" to "Road 1", "distanceM" to 400.0),
            ),
        )
        CarNotifications(app).show(trip)
        val nm = app.getSystemService(NotificationManager::class.java)
        val n = shadowOf(nm).getNotification(CarNotifications.ID)
        assertNotNull("the turn notification was posted", n)
        assertOpensMaps(n.contentIntent)
    }

    @Test
    fun theCarScreenNotificationOpensTheMapsTab() {
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_FINE_LOCATION)
        val service = Robolectric.buildService(CarLocationService::class.java).create().get()
        service.onStartCommand(Intent(app, CarLocationService::class.java), 0, 1)
        val n = shadowOf(service).lastForegroundNotification
        assertNotNull("Cache is on the car screen was posted", n)
        assertOpensMaps(n.contentIntent)
    }

    @Test
    fun onlyAFreshTapAsksForTheMapsTab() {
        assertTrue(OpenMaps.wants(OpenMaps.intent(app)))
        assertFalse(OpenMaps.wants(null))
        assertFalse(OpenMaps.wants(Intent(app, MainActivity::class.java)))
        assertFalse(OpenMaps.wants(Intent(app, MainActivity::class.java).putExtra(OpenMaps.EXTRA, "other")))
        // Brought back from Recents, the activity repeats the intent it was started with: not a new tap.
        assertFalse(OpenMaps.wants(OpenMaps.intent(app).addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)))
    }
}

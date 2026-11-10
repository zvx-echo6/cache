package com.happylittlellc.cache.car

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.happylittlellc.cache.R

/**
 * Keeps Cache able to read the position while a car screen is attached and the phone is locked in a pocket with the phone app
 * closed: a foreground service of type location for as long as the car session lasts. It reads nothing itself; the app's own
 * position stream (Dart, geolocator) keeps getting fixes because the process now has a foreground location service. Started by
 * [CarSession] when the car connects, stopped when it disconnects. Needs the location permission the app already has.
 */
class CarLocationService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Car screen", NotificationManager.IMPORTANCE_LOW))
        val n = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_cache)
            .setContentTitle("Cache is on the car screen")
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
        try {
            ServiceCompat.startForeground(this, ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } catch (e: Exception) {
            Log.w(TAG, "the car's location service could not start", e)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val TAG = "CacheCar"
        const val CHANNEL = "cache_car_connected"
        const val ID = 7310

        fun start(context: Context) {
            val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
            if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) return
            try {
                ContextCompat.startForegroundService(context, Intent(context, CarLocationService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "the car's location service was not allowed to start", e)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CarLocationService::class.java))
        }
    }
}

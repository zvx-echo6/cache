package com.happylittlellc.cache.nfc

import android.app.Activity
import android.content.ComponentName
import android.nfc.NfcAdapter
import android.nfc.cardemulation.CardEmulation

/**
 * The one link this phone hands out by NFC while the link-code sheet is open. [LinkTagService] reads [message]; with none set
 * the service finds no tag, so nothing can be read from a pocket. Dart sets the link when the sheet opens and clears it when it
 * closes; the activity suspends it while the app is not in front and brings it back with the sheet still open.
 */
object LinkTag {
    /** The link the sheet wants served, whether or not the app is in front right now. */
    private var wanted: String? = null

    /** What the service serves: null unless a link is wanted and the app is in front. */
    @Volatile var message: ByteArray? = null
        private set

    fun serve(activity: Activity, link: String?, inFront: Boolean) {
        wanted = link
        apply(activity, inFront)
    }

    fun apply(activity: Activity, inFront: Boolean) {
        val link = wanted
        val on = link != null && inFront
        message = if (on) LinkNdef.message(link!!, activity.packageName) else null
        val adapter = NfcAdapter.getDefaultAdapter(activity) ?: return
        try {
            val emulation = CardEmulation.getInstance(adapter)
            val service = ComponentName(activity, LinkTagService::class.java)
            if (on) emulation.setPreferredService(activity, service) else emulation.unsetPreferredService(activity)
        } catch (_: Exception) {
            // No card emulation on this phone: the other phone can still not read it, and nothing else breaks.
        }
    }
}

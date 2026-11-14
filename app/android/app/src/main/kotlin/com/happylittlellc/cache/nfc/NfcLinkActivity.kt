package com.happylittlellc.cache.nfc

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.os.Bundle
import com.happylittlellc.cache.MainActivity

/**
 * A tag or phone with a `cachelink:` link touched while Cache is in the background or closed. No screen: it passes the link to
 * MainActivity as the VIEW intent a camera's scan makes (MainActivity.readLink) and finishes.
 */
class NfcLinkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uri = linkFrom(intent)
        if (uri != null) {
            startActivity(
                Intent(this, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(uri)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
        finish()
    }

    @Suppress("DEPRECATION")
    private fun linkFrom(i: Intent?): Uri? {
        if (i == null) return null
        i.data?.let { if ("cachelink".equals(it.scheme, ignoreCase = true)) return it }
        val raw = i.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES) ?: return null
        for (m in raw) {
            for (r in (m as? NdefMessage)?.records ?: continue) {
                if (r.tnf != NdefRecord.TNF_WELL_KNOWN && r.tnf != NdefRecord.TNF_ABSOLUTE_URI) continue
                val u = r.toUri() ?: continue
                if ("cachelink".equals(u.scheme, ignoreCase = true)) return u
            }
        }
        return null
    }
}

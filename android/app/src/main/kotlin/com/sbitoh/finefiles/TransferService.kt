package com.sbitoh.finefiles

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class TransferService : Service() {

    companion object {
        const val CHANNEL_ID = "finefiles_transfer_channel"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.sbitoh.finefiles.ACTION_START_TRANSFER"
        const val ACTION_UPDATE = "com.sbitoh.finefiles.ACTION_UPDATE_TRANSFER"
        const val ACTION_STOP = "com.sbitoh.finefiles.ACTION_STOP_TRANSFER"

        const val EXTRA_TITLE = "title"
        const val EXTRA_PROGRESS = "progress"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "正在传输文件..."
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                startForeground(NOTIFICATION_ID, buildNotification(title, progress))
            }
            ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "正在传输文件..."
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(NOTIFICATION_ID, buildNotification(title, progress))
            }
            ACTION_STOP -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "文件传输服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持初晴文件管理在后台稳定传输大文件，防止被系统冻结杀后台"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, progress: Int): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("初晴文件管理 · 后台传输中")
            .setContentText(title)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (progress in 1..99) {
            builder.setProgress(100, progress, false)
        } else if (progress == 0) {
            builder.setProgress(100, 0, true)
        } else {
            builder.setProgress(0, 0, false)
        }

        return builder.build()
    }
}

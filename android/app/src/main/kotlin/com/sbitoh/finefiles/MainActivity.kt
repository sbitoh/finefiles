package com.sbitoh.finefiles

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sbitoh.finefiles/background_service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTransferService" -> {
                    val title = call.argument<String>("title") ?: "正在传输文件..."
                    val progress = call.argument<Int>("progress") ?: 0
                    val intent = Intent(this, TransferService::class.java).apply {
                        action = TransferService.ACTION_START
                        putExtra(TransferService.EXTRA_TITLE, title)
                        putExtra(TransferService.EXTRA_PROGRESS, progress)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "updateTransferService" -> {
                    val title = call.argument<String>("title") ?: "正在传输文件..."
                    val progress = call.argument<Int>("progress") ?: 0
                    val intent = Intent(this, TransferService::class.java).apply {
                        action = TransferService.ACTION_UPDATE
                        putExtra(TransferService.EXTRA_TITLE, title)
                        putExtra(TransferService.EXTRA_PROGRESS, progress)
                    }
                    startService(intent)
                    result.success(true)
                }
                "stopTransferService" -> {
                    val intent = Intent(this, TransferService::class.java).apply {
                        action = TransferService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                "notifyRootsChanged" -> {
                    val rootsUri = android.provider.DocumentsContract.buildRootsUri("com.sbitoh.finefiles.documents")
                    contentResolver.notifyChange(rootsUri, null)
                    result.success(true)
                }
                "getSystemCookies" -> {
                    val url = call.argument<String>("url") ?: "https://pan.baidu.com"
                    val cookieManager = android.webkit.CookieManager.getInstance()
                    val cookieStr = cookieManager.getCookie(url) ?: ""
                    result.success(cookieStr)
                }
                else -> result.notImplemented()
            }
        }
    }
}


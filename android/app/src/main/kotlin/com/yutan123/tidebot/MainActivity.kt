package com.yutan123.tidebot
import android.content.Intent
import android.content.Context
import android.content.ComponentName
import android.net.Uri

import android.os.Bundle
import android.os.BatteryManager
import android.provider.Settings

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
// URI helpers are not needed after overlay removal.
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.location.LocationManager
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat

import android.graphics.pdf.PdfRenderer
import android.provider.AlarmClock
import androidx.annotation.NonNull
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity: FlutterActivity() {
    private var dataTransfer: DataTransfer? = null
    override fun dispatchTouchEvent(event: android.view.MotionEvent): Boolean {
        selectionMenu?.beforeTouchEvent(event)
        return super.dispatchTouchEvent(event)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (dataTransfer?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
    private val backgroundCoordinator = java.util.concurrent.Executors.newSingleThreadExecutor()

    private fun backgroundResult(result: MethodChannel.Result, code: String, action: () -> Any?) {
        backgroundCoordinator.execute {
            try {
                val value = action()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                val errorCode = if (code == "VITAL_FAILED" && e.message == "Vital state is busy") "VITAL_BUSY" else code
                runOnUiThread { result.error(errorCode, e.message, null) }
            }
        }
    }
    private val CHANNEL = "tidebot.native.channel"
    private var nativeChannel: MethodChannel? = null
    private var selectionMenu: NativeSelectionMenu? = null
    private var pendingInstallApk: File? = null
    // 悬浮窗消息转发已移除。


    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 使用增强版后台任务调度器
        TideEnhancedBackgroundWork.ensureScheduled(this)
    }
    
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
    override fun onDestroy() {
        dataTransfer?.dispose()
        selectionMenu?.dispose()
        selectionMenu = null
        TideNativeNotifications.activityVisible = false
        TideNativeNotifications.visibleChatBotId = null
        // The service owns bounded request leases. Activity teardown alone is
        // not proof that the Flutter engine's network request has finished.
        backgroundCoordinator.shutdown()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        TideNativeNotifications.activityVisible = true
        val apk = pendingInstallApk ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
            pendingInstallApk = null
            openApkInstaller(apk)
        }
    }

    override fun onPause() {
        TideNativeNotifications.activityVisible = false
        // Persist deadlines natively before Flutter's UI timers can be suspended.
        backgroundCoordinator.execute {
            runCatching {
                TideFutureTasks.reconcile(applicationContext)
                TideProactiveTasks.reconcile(applicationContext)
                TideEnhancedBackgroundWork.ensureScheduled(applicationContext)
                TideMasterScheduler.restoreAllTasks(applicationContext)
            }.onFailure { android.util.Log.e("TideBackground", "Background handoff failed", it) }
        }
        super.onPause()
    }

    private fun openApkInstaller(apk: File) {
        val uri = androidx.core.content.FileProvider.getUriForFile(
            this, "$packageName.fileprovider", apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        TideMemoryEmbedding.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        dataTransfer?.dispose()
        dataTransfer = DataTransfer(this, flutterEngine.dartExecutor.binaryMessenger)
        selectionMenu?.dispose()
        selectionMenu = NativeSelectionMenu(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "tidebot/native_selectable_text",
            NativeSelectableTextFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        nativeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        nativeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "openChatFile" -> {
                    try {
                        val path = call.argument<String>("path")
                        require(!path.isNullOrBlank()) { "文件路径为空" }
                        val source = File(path)
                        require(source.isFile && source.canRead()) { "文件不存在或无法读取" }
                        // Share a cached copy: external apps cannot read sandbox file:// URLs.
                        val directory = File(cacheDir, "open_files/${java.util.UUID.randomUUID()}")
                        check(directory.mkdirs()) { "无法准备文件" }
                        val shared = File(directory, source.name)
                        source.copyTo(shared)
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", shared)
                        val extension = shared.extension.lowercase(java.util.Locale.ROOT)
                        val mime = android.webkit.MimeTypeMap.getSingleton()
                            .getMimeTypeFromExtension(extension) ?: "*/*"
                        val view = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime)
                            clipData = android.content.ClipData.newRawUri("文件附件", uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        val chooser = Intent.createChooser(view, "选择应用打开").apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            clipData = view.clipData
                        }
                        startActivity(chooser)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("OPEN_FILE_FAILED", error.message, null)
                    }
                }
                "stageFullRestore" -> backgroundResult(result, "RESTORE_PREPARE_FAILED") {
                    TideColdRestore.stage(this, call.argument<String>("path") ?: error("Missing restore path"))
                    true
                }
                "consumeRestoreResult" -> result.success(TideColdRestore.consumeResult(this))
                "restartForRestore" -> {
                    val launch = Intent.makeRestartActivityTask(ComponentName(this, MainActivity::class.java))
                    val pending = android.app.PendingIntent.getActivity(this, 712391, launch,
                        android.app.PendingIntent.FLAG_CANCEL_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE)
                    val alarms = getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
                    alarms.set(android.app.AlarmManager.ELAPSED_REALTIME, android.os.SystemClock.elapsedRealtime() + 1000, pending)
                    result.success(null)
                    finishAndRemoveTask()
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        val manager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                        manager.runningAppProcesses?.filter { it.uid == android.os.Process.myUid() && it.pid != android.os.Process.myPid() }
                            ?.forEach { android.os.Process.killProcess(it.pid) }
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }, 100)
                }
                "consumeMessageNotification" -> {
                    val botId = intent?.getStringExtra("tide_bot_id")
                    val messageId = intent?.getStringExtra("tide_message_id")
                    intent?.removeExtra("tide_bot_id")
                    intent?.removeExtra("tide_message_id")
                    result.success(if (botId.isNullOrBlank()) null else mapOf("bot_id" to botId, "message_id" to messageId))
                }

                "setVisibleChat" -> {
                    TideNativeNotifications.visibleChatBotId = call.argument<String>("botId")
                    result.success(null)
                }
                "deliverPendingMessages" -> backgroundResult(result, "NOTIFICATION_FAILED") {
                    TideNativeNotifications.deliverPending(applicationContext)
                    null
                }
                "beginRequestExecution", "renewRequestExecution" -> {
                    val id = call.argument<String>("id").orEmpty()
                    if (id.isBlank()) {
                        result.error("REQUEST_PROTECTION_FAILED", "Missing request ID", null)
                    } else {
                        val completion: (String?) -> Unit = { error ->
                            if (error == null) result.success(mapOf("foreground" to true))
                            else result.error("REQUEST_PROTECTION_FAILED", error, null)
                        }
                        try {
                            if (call.method == "beginRequestExecution") {
                                TideBackgroundService.beginRequest(applicationContext, id, completion)
                            } else {
                                TideBackgroundService.renewRequest(applicationContext, id, completion)
                            }
                        } catch (error: Exception) {
                            result.error("REQUEST_PROTECTION_FAILED", error.message, null)
                        }
                    }
                }
                "endRequestExecution" -> {
                    val id = call.argument<String>("id").orEmpty()
                    TideBackgroundService.endRequest(id)
                    result.success(null)
                }
                // 悬浮窗待处理消息接口已移除。
                "tickVitalSigns" -> {
                    val id = call.argument<String>("botId").orEmpty()
                    backgroundResult(result, "VITAL_FAILED") {
                        require(id.isNotBlank()) { "Missing bot ID" }
                        TideVitalSigns.tick(applicationContext, id).toString()
                    }
                }
                "drainBackgroundLogs" -> backgroundResult(result, "LOG_FAILED") { TideBackgroundLog.drain(applicationContext) }
                "interruptProactiveReply" -> {
                    val botId = call.argument<String>("botId").orEmpty()
                    TideProactiveReplyEngine.interrupt(botId) { result.success(null) }
                }
                "synchronizeBackgroundTasks" -> backgroundResult(result, "SYNC_FAILED") {
                    TideFutureTasks.reconcile(applicationContext)
                    for (id in TideConfigReader.getEnabledBotIds(applicationContext)) {
                        runCatching { TideVitalSigns.tick(applicationContext, id) }
                            .onFailure { android.util.Log.e("TideBackground", "Vital synchronization failed: $id", it) }
                    }
                    TideProactiveTasks.reconcile(applicationContext)
                    TideEnhancedBackgroundWork.ensureScheduled(applicationContext)
                    TideMasterScheduler.restoreAllTasks(applicationContext)
                    val due = TideStore.open(applicationContext).use { db ->
                        TideStore.rows(db, "SELECT task_id,trigger_time FROM background_tasks WHERE enabled=1 AND task_type='PROACTIVE_REPLY' AND trigger_time<=?", System.currentTimeMillis().toString())
                    }
                    for (task in due) {
                        TideBackgroundService.startTask(applicationContext, task.getString("task_id"), task.getLong("trigger_time"))
                    }
                    null
                }
                "scheduleFutureTask" -> {
                    val taskId = call.argument<String>("taskId").orEmpty()
                    val triggerAt = call.argument<Number>("triggerAt")?.toLong() ?: 0L
                    val title = call.argument<String>("title") ?: "TideBot 提醒"
                    if (taskId.startsWith("vital:")) {
                        result.success(TideAlarmScheduler.schedule(this, taskId, triggerAt, title, false))
                    } else {
                        try {
                            TideFutureTasks.reconcile(this)
                            result.success(TideMasterScheduler.isRegistered(this, taskId))
                        } catch (e: Exception) {
                            result.error("SCHEDULE_FAILED", e.message, null)
                        }
                    }
                }
                "cancelFutureTask" -> {
                    TideMasterScheduler.cancelTask(this, call.argument<String>("taskId").orEmpty())
                    result.success(null)
                }
                "setAlarmManager" -> {
                    val hour = call.argument<Int>("hour") ?: 0
                    val minute = call.argument<Int>("minute") ?: 0
                    val message = call.argument<String>("message") ?: "TideBot 提醒"
                    
                    val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                        putExtra(AlarmClock.EXTRA_HOUR, hour)
                        putExtra(AlarmClock.EXTRA_MINUTES, minute)
                        putExtra(AlarmClock.EXTRA_MESSAGE, message)
                        putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                    }
                    
                    if (intent.resolveActivity(packageManager) != null) {
                        startActivity(intent)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "storageInfo" -> {
                    try {
                        fun sizeOf(file: File?): Long {
                            if (file == null || !file.exists()) return 0L
                            if (file.isFile) return file.length()
                            return file.listFiles()?.sumOf { sizeOf(it) } ?: 0L
                        }
                        val stat = StatFs(filesDir.absolutePath)
                        val apk = applicationInfo.sourceDir?.let { File(it) }
                        result.success(mapOf(
                            "total" to stat.totalBytes,
                            "available" to stat.availableBytes,
                            "data" to sizeOf(File(applicationInfo.dataDir)),
                            "apk" to sizeOf(apk),
                            "cache" to sizeOf(cacheDir),
                            "files" to sizeOf(filesDir)
                        ))
                    } catch (_: Exception) { result.success(mapOf<String, Long>()) }
                }
                "vibrate" -> {
                    val duration = (call.argument<Int>("duration") ?: 24).toLong().coerceIn(1L, 500L)
                    val amplitude = (call.argument<Int>("amplitude") ?: 180).coerceIn(1, 255)
                    try {
                        val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            (getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
                        } else {
                            @Suppress("DEPRECATION")
                            getSystemService(VIBRATOR_SERVICE) as Vibrator
                        }
                        if (vibrator?.hasVibrator() != true) {
                            result.success(false)
                        } else {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                vibrator.vibrate(VibrationEffect.createOneShot(duration, amplitude))
                            } else {
                                @Suppress("DEPRECATION")
                                vibrator.vibrate(duration)
                            }
                            result.success(true)
                        }
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "deviceContext" -> result.success(TideDeviceContext.read(
                    applicationContext, call.argument<List<String>>("allowed")?.toSet() ?: emptySet()
                ))
                "installedApps" -> {
                    val apps = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        packageManager.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(0))
                    } else {
                        @Suppress("DEPRECATION")
                        packageManager.getInstalledApplications(0)
                    }).filter { packageManager.getLaunchIntentForPackage(it.packageName) != null }
                        .map { mapOf("packageName" to it.packageName, "label" to packageManager.getApplicationLabel(it).toString(), "isTideBot" to (it.packageName == packageName)) }
                        .sortedBy { it["label"].toString() }
                    result.success(apps)
                }
                "capabilityState" -> result.success(mapOf(
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "installPackages" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()),
                    "usageAccess" to hasUsageAccess(),
                    "notificationAccess" to (Settings.Secure.getString(contentResolver, "enabled_notification_listeners")?.split(':')?.any { ComponentName.unflattenFromString(it)?.packageName == packageName } == true),
                    "locationPermission" to (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED)
                ))
                "latestDeviceEvent" -> {
                    val notification = TideNotificationListenerService.lastEvent?.toMutableMap()?.apply {
                        this["type"] = "new_notification"
                        this["time"] = (this["postedAt"] as? Number)?.toLong() ?: 0L
                    }
                    val selected = listOfNotNull(notification)
                        .maxByOrNull { (it["time"] as? Number)?.toLong() ?: 0L }
                    result.success(selected)
                }
                "openPermissionSettings" -> {
                    val kind = call.argument<String>("kind")
                    if (kind == "autostart") {
                        if (TideAutoStartSettings.open(this)) result.success(null)
                        else result.error("settings_unavailable", "无法打开自启动设置", null)
                        return@setMethodCallHandler
                    }
                    val action = when (kind) {
                        "battery" -> Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                        "alarm" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM else Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                        "install" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES else Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                        else -> Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                    }
                    val intent = Intent(action).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    try {
                        startActivity(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        try {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                            result.success(null)
                        } catch (fallback: Exception) {
                            result.error("settings_unavailable", "无法打开系统授权设置", null)
                        }
                    }
                }
                "openUsageAccessSettings" -> {
                    startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                    result.success(null)
                }
                "openNotificationListenerSettings" -> {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(null)
                }
                "openLocationSettings" -> {
                    startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                    result.success(null)
                }
                // 悬浮窗与无障碍操控 MethodChannel 接口已移除。
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "Missing APK path", null)
                    } else {
                        val apk = File(path)
                        if (!apk.exists()) {
                            result.error("missing_file", "APK file does not exist", null)
                        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()) {
                            val settingsIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            if (settingsIntent.resolveActivity(packageManager) != null) {
                                pendingInstallApk = apk
                                startActivity(settingsIntent)
                                result.success(mapOf("permissionRequested" to true))
                            } else {
                                result.error("install_permission_unavailable", "无法打开未知来源安装授权设置", null)
                            }
                        } else {
                            openApkInstaller(apk)
                            result.success(true)
                        }
                    }
                }
                "recognizeText" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "Missing image path", null)
                    } else {
                        recognizeText(path, result)
                    }
                }
                "prepareVideo" -> {
                    val path = call.argument<String>("path")
                    val intervalMs = call.argument<Int>("intervalMs") ?: 3000
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "Missing video path", null)
                    } else {
                        Thread {
                            val output = try {
                                prepareVideo(path, intervalMs)
                            } catch (e: Exception) {
                                mapOf("error" to (e.message ?: "视频预处理失败"))
                            }
                            runOnUiThread { result.success(output) }
                        }.start()
                    }
                }
                "extractPdfText" -> {
                    val path = call.argument<String>("path")
                    val maxPages = (call.argument<Int>("maxPages") ?: 3).coerceIn(1, 6)
                    val maxChars = (call.argument<Int>("maxChars") ?: 120000).coerceIn(1000, 200000)
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "Missing PDF path", null)
                    } else {
                        extractPdfText(path, maxPages, maxChars, result)
                    }
                }
                                "registerBackgroundTask" -> {
                    val taskId = call.argument<String>("taskId").orEmpty()
                    val taskType = call.argument<String>("taskType").orEmpty()
                    val botId = call.argument<String>("botId")
                    val triggerTime = call.argument<Number>("triggerTime")?.toLong() ?: 0L
                    val repeating = call.argument<Boolean>("repeating") == true
                    val config = call.argument<String>("config")
                    
                    val configJson = if (!config.isNullOrEmpty()) {
                        try { org.json.JSONObject(config) } catch (e: Exception) { null }
                    } else null
                    
                    val success = TideMasterScheduler.registerTask(
                        this, taskId, taskType, botId, triggerTime, repeating, configJson
                    )
                    result.success(success)
                }
                "cancelBackgroundTask" -> {
                    val taskId = call.argument<String>("taskId").orEmpty()
                    result.success(TideMasterScheduler.cancelTask(this, taskId))
                }
                "getBatteryStatus" -> {
                    result.success(mapOf(
                        "isCharging" to TideBatteryMonitor.isCharging(this),
                        "isLowBattery" to TideBatteryMonitor.isLowBattery(this),
                        "level" to TideBatteryMonitor.getBatteryLevel(this)
                    ))
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, applicationInfo.uid, packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, applicationInfo.uid, packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun recognizeText(path: String, result: MethodChannel.Result) {
        try {
            val image = InputImage.fromFilePath(this, Uri.fromFile(File(path)))
            val recognizer = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
            recognizer.process(image)
                .addOnSuccessListener { result.success(it.text) }
                .addOnFailureListener { result.error("ocr_failed", it.message, null) }
        } catch (e: Exception) {
            result.error("ocr_failed", e.message, null)
        }
    }

    private fun extractPdfText(
        path: String,
        maxPages: Int,
        maxChars: Int,
        result: MethodChannel.Result
    ) {
        Thread {
            val source = File(path)
            if (!source.exists()) {
                runOnUiThread { result.success(mapOf("error" to "PDF 文件不存在")) }
                return@Thread
            }

            var descriptor: ParcelFileDescriptor? = null
            var renderer: PdfRenderer? = null
            try {
                val openedDescriptor =
                    ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
                descriptor = openedDescriptor
                val openedRenderer = PdfRenderer(openedDescriptor)
                renderer = openedRenderer
                val pages = minOf(openedRenderer.pageCount, maxPages)
                val allText = StringBuilder()
                var index = 0

                fun processNextPage() {
                    if (index >= pages || allText.length >= maxChars) {
                        runOnUiThread {
                            result.success(
                                mapOf(
                                    "text" to allText.take(maxChars).toString(),
                                    "pagesProcessed" to index,
                                    "pageCount" to openedRenderer.pageCount
                                )
                            )
                        }
                        try { openedRenderer.close() } catch (_: Exception) {}
                        try { openedDescriptor.close() } catch (_: Exception) {}
                        return
                    }

                    val page = openedRenderer.openPage(index)
                    val scale = 2
                    val bitmap = Bitmap.createBitmap(
                        (page.width * scale).coerceAtLeast(1),
                        (page.height * scale).coerceAtLeast(1),
                        Bitmap.Config.ARGB_8888
                    )
                    bitmap.eraseColor(android.graphics.Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    page.close()
                    val image = InputImage.fromBitmap(bitmap, 0)
                    TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
                        .process(image)
                        .addOnSuccessListener { recognized ->
                            if (recognized.text.isNotBlank()) {
                                allText.append("\n[第 ${index + 1} 页]\n")
                                allText.append(recognized.text)
                                allText.append('\n')
                            }
                            bitmap.recycle()
                            index += 1
                            processNextPage()
                        }
                        .addOnFailureListener { error ->
                            bitmap.recycle()
                            index += 1
                            allText.append("\n[第 $index 页 OCR 失败：${error.message ?: "未知错误"}]\n")
                            processNextPage()
                        }
                }

                if (pages == 0) {
                    runOnUiThread { result.success(mapOf("text" to "", "pagesProcessed" to 0, "pageCount" to 0)) }
                    openedRenderer.close()
                    openedDescriptor.close()
                } else {
                    processNextPage()
                }
            } catch (e: Exception) {
                try { renderer?.close() } catch (_: Exception) {}
                try { descriptor?.close() } catch (_: Exception) {}
                runOnUiThread { result.success(mapOf("error" to (e.message ?: "PDF OCR 失败"))) }
            }
        }.start()
    }

    private fun prepareVideo(path: String, intervalMs: Int): Map<String, Any> {
        val source = File(path)
        require(source.exists()) { "视频文件不存在" }

        val outputDir = File(cacheDir, "tidebot_video_${System.currentTimeMillis()}")
        outputDir.mkdirs()
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val durationMs = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION
            )?.toLongOrNull() ?: 0L
            val frames = mutableListOf<String>()
            var timeMs = 0L
            while (timeMs <= durationMs && frames.size < 120) {
                val frame: Bitmap? = retriever.getFrameAtTime(
                    timeMs * 1000,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                )
                if (frame != null) {
                    val frameFile = File(outputDir, "frame_${frames.size}.jpg")
                    FileOutputStream(frameFile).use {
                        frame.compress(Bitmap.CompressFormat.JPEG, 85, it)
                    }
                    frames.add(frameFile.absolutePath)
                }
                timeMs += intervalMs.coerceAtLeast(1000)
            }
            val audioPath = extractAudio(path, outputDir)
            return mapOf(

                "frames" to frames,
                "audioPath" to (audioPath ?: ""),
                "durationMs" to durationMs
            )
        } finally {
            retriever.release()
        }
    }
    private fun extractAudio(sourcePath: String, outputDir: File): String? {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var output: File? = null
        try {
            extractor.setDataSource(sourcePath)
            var audioTrack = -1
            var audioMime = ""
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrack = index
                    audioMime = mime
                    break
                }
            }
            if (audioTrack < 0) return null

            val webm = audioMime.contains("opus") || audioMime.contains("vorbis")
            output = File(outputDir, if (webm) "audio.webm" else "audio.m4a")
            extractor.selectTrack(audioTrack)
            val destination = output ?: return null
            muxer = MediaMuxer(
                destination.absolutePath,
                if (webm) MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
                else MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            )

            val muxerTrack = muxer.addTrack(extractor.getTrackFormat(audioTrack))
            muxer.start()
            val buffer = java.nio.ByteBuffer.allocate(1024 * 1024)
            val info = MediaCodec.BufferInfo()
            while (true) {
                info.offset = 0
                info.size = extractor.readSampleData(buffer, 0)
                if (info.size < 0) break
                info.presentationTimeUs = extractor.sampleTime
                info.flags = extractor.sampleFlags
                muxer.writeSampleData(muxerTrack, buffer, info)
                extractor.advance()
            }
            return output?.absolutePath

        } catch (_: Exception) {
            output?.delete()
            return null

        } finally {
            try {
                muxer?.stop()
            } catch (_: Exception) {
            }
            muxer?.release()
            extractor.release()
        }
    }
}

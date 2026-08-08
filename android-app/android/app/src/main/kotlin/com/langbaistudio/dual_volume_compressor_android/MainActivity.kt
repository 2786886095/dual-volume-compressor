package com.langbaistudio.dual_volume_compressor_android

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.system.Os
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.min

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.langbaistudio.dual_volume_compressor/native"
        private const val REQUEST_FILES = 4101
        private const val REQUEST_FOLDER = 4102
        private const val REQUEST_OUTPUT = 4103
    }

    private lateinit var channel: MethodChannel
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPickerResult: MethodChannel.Result? = null
    private val pendingSharedUris = mutableListOf<Uri>()
    @Volatile private var cancelRequested = false
    @Volatile private var runningProcess: Process? = null
    @Volatile private var compressionRunning = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        collectShareUris(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result -> handleMethodCall(call, result) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val before = pendingSharedUris.size
        collectShareUris(intent)
        if (::channel.isInitialized && pendingSharedUris.size > before) {
            importPendingShares { imported -> channel.invokeMethod("sharedInputs", imported) }
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFiles" -> launchFilePicker(result)
            "pickFolder" -> launchFolderPicker(result)
            "pickOutputDirectory" -> launchOutputPicker(result)
            "getInitialInputs" -> importPendingShares { result.success(it) }
            "runCompression" -> startCompression(call.arguments as? Map<*, *>, result)
            "cancelCompression" -> {
                cancelRequested = true
                runningProcess?.destroy()
                result.success(true)
            }
            "clearImportedFiles" -> {
                File(cacheDir, "imports").deleteRecursively()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun launchFilePicker(result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("PICKER_BUSY", "已有文件选择器正在运行", null)
            return
        }
        pendingPickerResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(intent, REQUEST_FILES)
    }

    private fun launchFolderPicker(result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("PICKER_BUSY", "已有文件选择器正在运行", null)
            return
        }
        pendingPickerResult = result
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQUEST_FOLDER)
    }

    private fun launchOutputPicker(result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("PICKER_BUSY", "已有文件选择器正在运行", null)
            return
        }
        pendingPickerResult = result
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQUEST_OUTPUT)
    }

    @Deprecated("Deprecated in Android SDK but retained for FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val result = pendingPickerResult ?: return
        pendingPickerResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return
        }

        when (requestCode) {
            REQUEST_FILES -> {
                val uris = mutableListOf<Uri>()
                data.clipData?.let { clip ->
                    for (index in 0 until clip.itemCount) uris += clip.getItemAt(index).uri
                }
                data.data?.let { uris += it }
                importUris(uris, result)
            }
            REQUEST_FOLDER -> {
                val uri = data.data
                if (uri == null) result.success(null) else importFolder(uri, result)
            }
            REQUEST_OUTPUT -> {
                val uri = data.data
                if (uri == null) {
                    result.success(null)
                } else {
                    val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    try { contentResolver.takePersistableUriPermission(uri, flags) } catch (_: Exception) { }
                    val folder = DocumentFile.fromTreeUri(this, uri)
                    result.success(mapOf("uri" to uri.toString(), "name" to (folder?.name ?: "已选择目录")))
                }
            }
        }
    }

    private fun importUris(uris: List<Uri>, result: MethodChannel.Result) {
        executor.execute {
            try {
                val destination = newImportDirectory()
                val items = uris.distinct().map { copyUriToDirectory(it, destination) }.map { describeInput(it) }
                mainHandler.post { result.success(items) }
            } catch (error: Exception) {
                mainHandler.post { result.error("IMPORT_FAILED", error.message, null) }
            }
        }
    }

    private fun importFolder(uri: Uri, result: MethodChannel.Result) {
        executor.execute {
            try {
                val source = DocumentFile.fromTreeUri(this, uri) ?: error("所选文件夹不可读取")
                val destinationRoot = newImportDirectory()
                val destination = uniqueFile(destinationRoot, safeName(source.name ?: "导入文件夹"), true)
                destination.mkdirs()
                copyDocumentTree(source, destination)
                mainHandler.post { result.success(listOf(describeInput(destination))) }
            } catch (error: Exception) {
                mainHandler.post { result.error("IMPORT_FOLDER_FAILED", error.message, null) }
            }
        }
    }

    private fun collectShareUris(intent: Intent?) {
        if (intent == null) return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { pendingSharedUris += it }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { pendingSharedUris += it }
            }
        }
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) pendingSharedUris += clip.getItemAt(index).uri
        }
    }

    private fun importPendingShares(callback: (List<Map<String, Any>>) -> Unit) {
        val uris = synchronized(pendingSharedUris) {
            val copy = pendingSharedUris.distinct()
            pendingSharedUris.clear()
            copy
        }
        if (uris.isEmpty()) {
            callback(emptyList())
            return
        }
        executor.execute {
            val imported = try {
                val destination = newImportDirectory()
                uris.map { copyUriToDirectory(it, destination) }.map { describeInput(it) }
            } catch (error: Exception) {
                emitProgress("分享文件导入失败: ${error.message}")
                emptyList()
            }
            mainHandler.post { callback(imported) }
        }
    }

    private fun newImportDirectory(): File {
        return File(cacheDir, "imports/${System.currentTimeMillis()}-${UUID.randomUUID().toString().take(8)}").apply { mkdirs() }
    }

    private fun copyUriToDirectory(uri: Uri, destination: File): File {
        val name = queryDisplayName(uri) ?: "导入文件-${System.currentTimeMillis()}"
        val target = uniqueFile(destination, safeName(name), false)
        contentResolver.openInputStream(uri)?.use { input ->
            BufferedInputStream(input).use { bufferedInput ->
                BufferedOutputStream(FileOutputStream(target)).use { output -> bufferedInput.copyTo(output) }
            }
        } ?: error("无法读取 $name")
        return target
    }

    private fun copyDocumentTree(source: DocumentFile, destination: File) {
        for (child in source.listFiles()) {
            val target = uniqueFile(destination, safeName(child.name ?: "未命名"), child.isDirectory)
            if (child.isDirectory) {
                target.mkdirs()
                copyDocumentTree(child, target)
            } else {
                contentResolver.openInputStream(child.uri)?.use { input ->
                    BufferedInputStream(input).use { bufferedInput ->
                        BufferedOutputStream(FileOutputStream(target)).use { output -> bufferedInput.copyTo(output) }
                    }
                } ?: error("无法读取 ${child.name}")
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }

    private fun safeName(value: String): String {
        val cleaned = value.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]"), "_").trim().trimEnd('.')
        return cleaned.ifBlank { "未命名" }
    }

    private fun uniqueFile(parent: File, name: String, directory: Boolean): File {
        var target = File(parent, name)
        if (!target.exists()) return target
        val dot = if (directory) -1 else name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var index = 2
        while (target.exists()) {
            target = File(parent, "$stem ($index)$extension")
            index++
        }
        return target
    }

    private fun describeInput(file: File): Map<String, Any> = mapOf(
        "path" to file.absolutePath,
        "name" to file.name,
        "isDirectory" to file.isDirectory,
        "size" to fileSize(file)
    )

    private fun fileSize(file: File): Long = if (file.isFile) file.length() else file.listFiles()?.sumOf { fileSize(it) } ?: 0L

    private fun startCompression(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (arguments == null) {
            result.error("BAD_ARGUMENTS", "缺少压缩参数", null)
            return
        }
        if (compressionRunning) {
            result.error("BUSY", "已有压缩任务正在运行", null)
            return
        }
        compressionRunning = true
        cancelRequested = false
        executor.execute {
            try {
                val outputs = executeCompression(arguments)
                mainHandler.post { result.success(outputs) }
            } catch (error: Exception) {
                mainHandler.post { result.error(if (cancelRequested) "CANCELLED" else "COMPRESS_FAILED", error.message, null) }
            } finally {
                compressionRunning = false
                runningProcess = null
                cancelRequested = false
            }
        }
    }

    private fun executeCompression(arguments: Map<*, *>): List<Map<String, Any>> {
        val inputPaths = (arguments["inputs"] as? List<*>)?.map { File(it.toString()) } ?: emptyList()
        require(inputPaths.isNotEmpty()) { "没有待压缩项目" }
        inputPaths.forEach { require(it.exists()) { "输入不存在: ${it.name}" } }
        val outputUri = Uri.parse(arguments["outputUri"]?.toString() ?: error("未选择输出目录"))
        val outputRoot = DocumentFile.fromTreeUri(this, outputUri) ?: error("输出目录不可访问")
        require(outputRoot.canWrite()) { "输出目录没有写入权限" }

        val separate = arguments["separateOutputs"] as? Boolean ?: false
        val doubleCompressionEnabled = arguments["doubleCompressionEnabled"] as? Boolean ?: true
        val requestedBase = safeName(arguments["baseName"]?.toString() ?: "double-archive")
        val innerFormat = arguments["innerFormat"]?.toString() ?: "7z"
        val outerFormat = arguments["outerFormat"]?.toString() ?: "7z"
        val volumeMode = arguments["volumeMode"]?.toString() ?: "size"
        val volumeSize = (arguments["volumeSize"] as? Number)?.toLong() ?: 500L
        val volumeUnit = arguments["volumeUnit"]?.toString() ?: "MB"
        val volumeCount = (arguments["volumeCount"] as? Number)?.toInt() ?: 5
        val level = (arguments["level"] as? Number)?.toInt() ?: 5
        val password = arguments["password"]?.toString() ?: ""
        val encryptHeaders = arguments["encryptHeaders"] as? Boolean ?: true
        val keepParts = arguments["keepParts"] as? Boolean ?: false
        val overwrite = arguments["overwrite"] as? Boolean ?: false

        val jobs = if (separate) inputPaths.map { listOf(it) } else listOf(inputPaths)
        val results = mutableListOf<Map<String, Any>>()
        jobs.forEachIndexed { index, jobInputs ->
            ensureNotCancelled()
            val baseName = if (separate) inputBaseName(jobInputs.first()) else requestedBase
            emitProgress("任务 ${index + 1}/${jobs.size}: $baseName")
            results += compressJob(
                inputs = jobInputs,
                outputRoot = outputRoot,
                baseName = baseName,
                doubleCompressionEnabled = doubleCompressionEnabled,
                innerFormat = innerFormat,
                outerFormat = outerFormat,
                volumeMode = volumeMode,
                volumeSize = volumeSize,
                volumeUnit = volumeUnit,
                volumeCount = volumeCount,
                level = level,
                password = password,
                encryptHeaders = encryptHeaders,
                keepParts = keepParts,
                overwrite = overwrite
            )
        }
        return results
    }

    private fun inputBaseName(file: File): String {
        val name = file.name
        return safeName(if (file.isDirectory) name else name.substringBeforeLast('.', name))
    }

    private fun compressJob(
        inputs: List<File>, outputRoot: DocumentFile, baseName: String, doubleCompressionEnabled: Boolean, innerFormat: String,
        outerFormat: String, volumeMode: String, volumeSize: Long, volumeUnit: String,
        volumeCount: Int, level: Int, password: String, encryptHeaders: Boolean,
        keepParts: Boolean, overwrite: Boolean
    ): Map<String, Any> {
        val stage = File(cacheDir, "compression/${System.currentTimeMillis()}-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val sourceRoot = File(stage, "source").apply { mkdirs() }
            val stagedInputs = inputs.map { input ->
                val destination = uniqueFile(sourceRoot, safeName(input.name), input.isDirectory)
                stageInput(input, destination)
                destination
            }
            val innerName = "$baseName.payload.$innerFormat"
            val innerArchive = File(stage, innerName)
            val inputList = File(stage, "inputs.txt")
            inputList.writeText(stagedInputs.joinToString("\n") { it.name }, Charsets.UTF_8)

            if (!doubleCompressionEnabled) {
                val finalArchive = File(stage, "$baseName.$outerFormat")
                emitProgress("普通压缩模式: 创建单个压缩包，不生成分卷")
                run7Zip(
                    archiveArguments(outerFormat, finalArchive, inputList, level, password, encryptHeaders, null),
                    sourceRoot
                )
                require(finalArchive.isFile) { "普通压缩包生成失败" }
                val finalDocument = copyToOutput(outputRoot, finalArchive, overwrite)
                emitProgress("完成: ${finalDocument.name ?: finalArchive.name}")
                return mapOf(
                    "name" to (finalDocument.name ?: finalArchive.name),
                    "uri" to finalDocument.uri.toString(),
                    "volumeCount" to 0,
                    "keptFolder" to ""
                )
            }

            val fixedCount = volumeMode == "count"

            emitProgress(if (fixedCount) "阶段 1/2: 创建完整加密压缩包" else "阶段 1/2: 创建分卷压缩包")
            val innerArgs = archiveArguments(
                format = innerFormat,
                archive = innerArchive,
                listFile = inputList,
                level = level,
                password = password,
                encryptHeaders = encryptHeaders,
                volume = if (fixedCount) null else "$volumeSize${if (volumeUnit == "GB") "g" else "m"}"
            )
            run7Zip(innerArgs, sourceRoot)

            val parts = if (fixedCount) {
                require(innerArchive.isFile) { "完整压缩包生成失败" }
                emitProgress("按实际大小均分为 $volumeCount 个分卷")
                val split = splitFileEvenly(innerArchive, volumeCount)
                innerArchive.delete()
                split
            } else {
                stage.listFiles()?.filter {
                    it.isFile && (it.name == innerName || it.name.startsWith("$innerName."))
                }?.sortedBy { it.name } ?: emptyList()
            }
            require(parts.isNotEmpty()) { "没有找到第一阶段分卷" }
            emitProgress("第一阶段完成，分卷数: ${parts.size}")

            val partList = File(stage, "parts.txt")
            partList.writeText(parts.joinToString("\n") { it.name }, Charsets.UTF_8)
            val finalArchive = File(stage, "$baseName.$outerFormat")
            emitProgress("阶段 2/2: 封装最终压缩包")
            run7Zip(
                archiveArguments(outerFormat, finalArchive, partList, level, password, encryptHeaders, null),
                stage
            )
            require(finalArchive.isFile) { "最终压缩包生成失败" }

            val finalDocument = copyToOutput(outputRoot, finalArchive, overwrite)
            var keptFolder: String? = null
            if (keepParts) {
                val folderName = "${baseName}_volumes_${System.currentTimeMillis()}"
                val folder = outputRoot.createDirectory(folderName) ?: error("无法创建分卷保留目录")
                for (part in parts) copyToOutput(folder, part, false)
                keptFolder = folder.name ?: folderName
            }
            emitProgress("完成: ${finalDocument.name ?: finalArchive.name}")
            return mapOf(
                "name" to (finalDocument.name ?: finalArchive.name),
                "uri" to finalDocument.uri.toString(),
                "volumeCount" to parts.size,
                "keptFolder" to (keptFolder ?: "")
            )
        } finally {
            stage.deleteRecursively()
        }
    }

    private fun stageInput(source: File, destination: File) {
        ensureNotCancelled()
        if (source.isDirectory) {
            require(destination.mkdirs() || destination.isDirectory) { "无法创建暂存目录: ${destination.name}" }
            source.listFiles()?.forEach { child ->
                stageInput(child, uniqueFile(destination, safeName(child.name), child.isDirectory))
            }
            return
        }

        destination.parentFile?.mkdirs()
        try {
            Os.link(source.absolutePath, destination.absolutePath)
        } catch (_: Exception) {
            BufferedInputStream(FileInputStream(source)).use { input ->
                BufferedOutputStream(FileOutputStream(destination)).use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        ensureNotCancelled()
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                    }
                }
            }
        }
    }

    private fun archiveArguments(
        format: String, archive: File, listFile: File, level: Int, password: String,
        encryptHeaders: Boolean, volume: String?
    ): List<String> {
        val args = mutableListOf("a", "-t$format", archive.absolutePath, "@${listFile.absolutePath}", "-scsUTF-8", "-mx=$level", "-y", "-bb1")
        if (password.isNotEmpty()) {
            args += "-p$password"
            if (format == "7z" && encryptHeaders) args += "-mhe=on"
            if (format == "zip") args += "-mem=AES256"
        }
        if (!volume.isNullOrBlank()) args += "-v$volume"
        return args
    }

    private fun run7Zip(arguments: List<String>, workingDirectory: File) {
        ensureNotCancelled()
        val executable = File(applicationInfo.nativeLibraryDir, "lib7zz.so")
        require(executable.isFile) { "APK 中缺少 7-Zip 原生内核" }
        val command = mutableListOf(executable.absolutePath).apply { addAll(arguments) }
        val process = ProcessBuilder(command)
            .directory(workingDirectory)
            .redirectErrorStream(true)
            .apply { environment()["LD_LIBRARY_PATH"] = applicationInfo.nativeLibraryDir }
            .start()
        runningProcess = process
        process.inputStream.bufferedReader().useLines { lines ->
            lines.forEach { line ->
                ensureNotCancelled()
                if (line.isNotBlank() && !line.contains("-p")) emitProgress(line)
            }
        }
        val exitCode = process.waitFor()
        runningProcess = null
        ensureNotCancelled()
        if (exitCode != 0) error("7-Zip 压缩失败，退出码 $exitCode")
    }

    private fun splitFileEvenly(source: File, count: Int): List<File> {
        require(count >= 2) { "固定分卷数量至少为 2" }
        require(source.length() >= count) { "压缩包过小，无法生成 $count 个非空分卷" }
        val baseSize = source.length() / count
        val remainder = source.length() % count
        val width = maxOf(3, count.toString().length)
        val result = mutableListOf<File>()
        RandomAccessFile(source, "r").use { input ->
            val buffer = ByteArray(1024 * 1024)
            for (index in 1..count) {
                ensureNotCancelled()
                var remaining = baseSize + if (index <= remainder) 1 else 0
                val part = File("${source.absolutePath}.${index.toString().padStart(width, '0')}")
                FileOutputStream(part).use { output ->
                    while (remaining > 0) {
                        ensureNotCancelled()
                        val read = input.read(buffer, 0, min(buffer.size.toLong(), remaining).toInt())
                        if (read <= 0) error("均分时意外到达文件末尾")
                        output.write(buffer, 0, read)
                        remaining -= read
                    }
                }
                result += part
                emitProgress("已均分 $index/$count: ${part.name}")
            }
        }
        return result
    }

    private fun copyToOutput(directory: DocumentFile, source: File, overwrite: Boolean): DocumentFile {
        ensureNotCancelled()
        directory.findFile(source.name)?.let { existing ->
            if (!overwrite) error("输出文件已存在: ${source.name}")
            if (!existing.delete()) error("无法覆盖已有文件: ${source.name}")
        }
        val mime = when (source.extension.lowercase()) {
            "7z" -> "application/x-7z-compressed"
            "zip" -> "application/zip"
            else -> "application/octet-stream"
        }
        val document = directory.createFile(mime, source.name) ?: error("无法创建输出文件: ${source.name}")
        contentResolver.openOutputStream(document.uri, "w")?.use { rawOutput ->
            BufferedOutputStream(rawOutput).use { output ->
                BufferedInputStream(FileInputStream(source)).use { input ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        ensureNotCancelled()
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                    }
                }
            }
        } ?: error("无法写入输出文件: ${source.name}")
        return document
    }

    private fun ensureNotCancelled() {
        if (cancelRequested) error("用户已取消")
    }

    private fun emitProgress(message: String) {
        if (!::channel.isInitialized) return
        mainHandler.post { channel.invokeMethod("progress", message) }
    }

    override fun onDestroy() {
        cancelRequested = true
        runningProcess?.destroy()
        executor.shutdownNow()
        super.onDestroy()
    }
}

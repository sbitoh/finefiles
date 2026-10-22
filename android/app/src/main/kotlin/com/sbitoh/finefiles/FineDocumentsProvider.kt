package com.sbitoh.finefiles

import android.content.Context
import android.content.SharedPreferences
import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.util.Base64
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import org.w3c.dom.Element
import org.w3c.dom.Node
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import javax.xml.parsers.DocumentBuilderFactory

class FineDocumentsProvider : DocumentsProvider() {

    private val ALL_MIME_TYPES = """
        */*
        image/*
        video/*
        audio/*
        text/*
        application/*
        application/pdf
        application/msword
        application/vnd.openxmlformats-officedocument.wordprocessingml.document
        application/vnd.ms-excel
        application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
        application/vnd.ms-powerpoint
        application/vnd.openxmlformats-officedocument.presentationml.presentation
        application/zip
        application/vnd.android.package-archive
    """.trimIndent()

    private val DEFAULT_ROOT_PROJECTION = arrayOf(
        DocumentsContract.Root.COLUMN_ROOT_ID,
        DocumentsContract.Root.COLUMN_MIME_TYPES,
        DocumentsContract.Root.COLUMN_FLAGS,
        DocumentsContract.Root.COLUMN_ICON,
        DocumentsContract.Root.COLUMN_TITLE,
        DocumentsContract.Root.COLUMN_SUMMARY,
        DocumentsContract.Root.COLUMN_DOCUMENT_ID,
        DocumentsContract.Root.COLUMN_AVAILABLE_BYTES
    )

    private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_FLAGS,
        DocumentsContract.Document.COLUMN_SIZE
    )

    override fun onCreate(): Boolean {
        // Android DocumentsProvider 回调运行在系统的 Binder 线程池中，直接支持网络 I/O
        // 允许网络访问与安全兜底
        android.os.StrictMode.setThreadPolicy(android.os.StrictMode.ThreadPolicy.Builder().permitAll().build())
        
        // 全局绕过自签名证书/私有泛域名反代证书拦截 (兼容 Lucky/Nginx 反代 HTTPS 端口)
        try {
            val trustAllCerts = arrayOf<TrustManager>(object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
                override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
                override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
            })
            val sslContext = SSLContext.getInstance("TLS")
            sslContext.init(null, trustAllCerts, SecureRandom())
            HttpsURLConnection.setDefaultSSLSocketFactory(sslContext.socketFactory)
            HttpsURLConnection.setDefaultHostnameVerifier(HostnameVerifier { _, _ -> true })
            android.util.Log.i("FineDocProvider", "Global SSL trust-all initialized for HTTPS WebDAV")
        } catch (e: Exception) {
            android.util.Log.e("FineDocProvider", "Failed to init SSL trust-all", e)
        }

        return true
    }

    private fun getStorageAccounts(): List<StorageAccount> {
        val list = mutableListOf<StorageAccount>()
        val ctx = context ?: return list
        
        // 尝试从多个渠道获取
        val candidates = listOf("FlutterSharedPreferences", "storage_accounts", "finefiles_prefs")
        var jsonStr: String? = null
        for (name in candidates) {
            val sp = ctx.getSharedPreferences(name, Context.MODE_PRIVATE)
            jsonStr = sp.getString("flutter.storage_accounts", null)
                ?: sp.getString("storage_accounts", null)
            if (jsonStr != null && jsonStr.isNotEmpty() && jsonStr != "[]") {
                android.util.Log.i("FineDocProvider", "getStorageAccounts: read from SP '$name': ${jsonStr.take(100)}")
                break
            }
        }

        // 文件兜底方案（跨进程最稳定）
        if (jsonStr == null || jsonStr.isEmpty() || jsonStr == "[]") {
            try {
                // 1. 尝试读私有 filesDir
                val f = File(ctx.filesDir, "storage_accounts.json")
                if (f.exists()) {
                    jsonStr = f.readText(Charsets.UTF_8)
                    android.util.Log.i("FineDocProvider", "getStorageAccounts: read from filesDir: ${jsonStr.take(100)}")
                }
            } catch (e: Exception) {}
            
            // 2. 尝试读跨进程共享的外部缓存文件
            if (jsonStr == null || jsonStr.isEmpty() || jsonStr == "[]") {
                try {
                    val extF = File(ctx.getExternalFilesDir(null), "storage_accounts.json")
                    if (extF.exists()) {
                        jsonStr = extF.readText(Charsets.UTF_8)
                        android.util.Log.i("FineDocProvider", "getStorageAccounts: read from extFilesDir: ${jsonStr.take(100)}")
                    }
                } catch (e: Exception) {}
            }
        }

        if (jsonStr != null && jsonStr.isNotEmpty() && jsonStr != "[]") {
            try {
                val arr = JSONArray(jsonStr)
                for (i in 0 until arr.length()) {
                    val obj = arr.getJSONObject(i)
                    list.add(
                        StorageAccount(
                            id = obj.getString("id"),
                            name = obj.getString("name"),
                            type = obj.getString("type"),
                            serverUrl = obj.getString("serverUrl"),
                            username = obj.optString("username", ""),
                            password = obj.optString("password", ""),
                            extraToken = obj.optString("extraToken", "")
                        )
                    )
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        return list
    }

    private fun resolveRootProjection(projection: Array<out String>?): Array<out String> {
        return projection ?: DEFAULT_ROOT_PROJECTION
    }

    private fun resolveDocumentProjection(projection: Array<out String>?): Array<out String> {
        return projection ?: DEFAULT_DOCUMENT_PROJECTION
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val proj = resolveRootProjection(projection)
        val result = MatrixCursor(proj)
        var accounts = getStorageAccounts()
        android.util.Log.i("FineDocProvider", ">>> queryRoots invoked! Found ${accounts.size} accounts: ${accounts.map { it.name + '(' + it.id + ')' }}")

        // 核心兜底保护：如果此时还没添加任何账号，必须向系统返回一个“初晴云盘”默认就绪 Root 根节点！
        // 否则系统 DocumentsUI / 微信检测到 0 个 Root 会判定为 "Provider returned no roots. Possibly naughty"，从而将该 Provider 彻底拉黑并从侧边栏永久隐藏！
        if (accounts.isEmpty()) {
            accounts = listOf(
                StorageAccount(
                    id = "default_cloud",
                    name = "初晴云盘 (请在App内添加存储)",
                    type = "webdav",
                    serverUrl = "http://127.0.0.1",
                    username = "",
                    password = ""
                )
            )
        }

    for (acc in accounts) {
        val flags = DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD or
                DocumentsContract.Root.FLAG_SUPPORTS_CREATE or
                DocumentsContract.Root.FLAG_SUPPORTS_RECENTS or
                DocumentsContract.Root.FLAG_SUPPORTS_SEARCH

        val docId = "${acc.id}:/"
        val row = result.newRow()
        for (col in proj) {
            when (col) {
                DocumentsContract.Root.COLUMN_ROOT_ID -> row.add(acc.id)
                DocumentsContract.Root.COLUMN_DOCUMENT_ID -> row.add(docId)
                DocumentsContract.Root.COLUMN_TITLE -> row.add(acc.name)
                DocumentsContract.Root.COLUMN_SUMMARY -> row.add("初晴云盘 · ${acc.type.uppercase()}")
                DocumentsContract.Root.COLUMN_FLAGS -> row.add(flags)
                DocumentsContract.Root.COLUMN_MIME_TYPES -> row.add(null) // 传 null 代表支持所有 MIME 类型，系统选择器永不过滤隐藏该根节点
                DocumentsContract.Root.COLUMN_AVAILABLE_BYTES -> row.add(1024L * 1024L * 1024L * 100L)
                DocumentsContract.Root.COLUMN_ICON -> row.add(R.mipmap.ic_launcher)
                else -> row.add(null)
            }
        }
    }
        return result
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val proj = resolveDocumentProjection(projection)
        val result = MatrixCursor(proj)
        val parts = documentId.split(":", limit = 2)
        val accId = parts[0]
        val path = if (parts.size > 1 && parts[1].isNotEmpty()) parts[1] else "/"

        val accounts = getStorageAccounts()
        val acc = accounts.find { it.id == accId }
        val name = if (path == "/" || path.isEmpty()) acc?.name ?: "Cloud Storage" else File(path).name

        val isDir = path == "/" || path.endsWith("/") || parts.size == 1
        val flags = if (isDir) {
            DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
        } else {
            DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        }
        val mimeType = if (isDir) {
            DocumentsContract.Document.MIME_TYPE_DIR
        } else {
            getMimeType(name)
        }

        val row = result.newRow()
        for (col in proj) {
            when (col) {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row.add(documentId)
                DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row.add(name)
                DocumentsContract.Document.COLUMN_MIME_TYPE -> row.add(mimeType)
                DocumentsContract.Document.COLUMN_FLAGS -> row.add(flags)
                DocumentsContract.Document.COLUMN_SIZE -> row.add(if (isDir) null else 1024L)
                DocumentsContract.Document.COLUMN_LAST_MODIFIED -> row.add(System.currentTimeMillis())
                else -> row.add(null)
            }
        }
        return result
    }

    override fun queryRecentDocuments(
        rootId: String,
        projection: Array<out String>?
    ): Cursor {
        val proj = resolveDocumentProjection(projection)
        val result = MatrixCursor(proj)
        // 支持 Recent 聚合查询，微信的 Recent 视图便可直接列出初晴云盘的最新文件
        val accounts = getStorageAccounts()
        val acc = accounts.find { it.id == rootId } ?: return result
        try {
            val files = if (acc.type == "baidu") fetchBaiduChildren(acc, "/") else fetchWebDavChildren(acc, "/")
            var count = 0
            for (f in files) {
                if (!f.isDir) {
                    val docId = "$rootId:${f.path}"
                    val row = result.newRow()
                    for (col in proj) {
                        when (col) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row.add(docId)
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row.add(f.name)
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> row.add(getMimeType(f.name))
                            DocumentsContract.Document.COLUMN_SIZE -> row.add(f.size)
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED -> row.add(f.lastModified)
                            DocumentsContract.Document.COLUMN_FLAGS -> row.add(DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE)
                            else -> row.add(null)
                        }
                    }
                    count++
                    if (count >= 20) break
                }
            }
        } catch (e: Exception) {}
        return result
    }

    override fun querySearchDocuments(
        rootId: String,
        query: String,
        projection: Array<out String>?
    ): Cursor {
        val proj = resolveDocumentProjection(projection)
        val result = MatrixCursor(proj)
        val accounts = getStorageAccounts()
        val acc = accounts.find { it.id == rootId } ?: return result
        try {
            val files = if (acc.type == "baidu") fetchBaiduChildren(acc, "/") else fetchWebDavChildren(acc, "/")
            for (f in files) {
                if (f.name.contains(query, ignoreCase = true)) {
                    val docId = "$rootId:${f.path}"
                    val row = result.newRow()
                    for (col in proj) {
                        when (col) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row.add(docId)
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row.add(f.name)
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> row.add(if (f.isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(f.name))
                            DocumentsContract.Document.COLUMN_SIZE -> row.add(f.size)
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED -> row.add(f.lastModified)
                            DocumentsContract.Document.COLUMN_FLAGS -> row.add(if (f.isDir) DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE else (DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE))
                            else -> row.add(null)
                        }
                    }
                }
            }
        } catch (e: Exception) {}
        return result
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        val pParts = parentDocumentId.split(":", limit = 2)
        val cParts = documentId.split(":", limit = 2)
        if (pParts[0] != cParts[0]) return false
        val pPath = if (pParts.size > 1 && pParts[1].isNotEmpty()) pParts[1].trimEnd('/') else ""
        val cPath = if (cParts.size > 1 && cParts[1].isNotEmpty()) cParts[1].trimEnd('/') else ""
        return cPath.startsWith(pPath)
    }

    // Android 8.0+ DocumentsUI 核心要求：同时重写带 queryArgs 的版本，微信和现代系统选择器默认调这个！
    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        queryArgs: android.os.Bundle?
    ): Cursor {
        return queryChildDocuments(parentDocumentId, projection, null as String?)
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val proj = resolveDocumentProjection(projection)
        val result = MatrixCursor(proj)
        val parts = parentDocumentId.split(":", limit = 2)
        val accId = parts[0]
        val parentPath = if (parts.size > 1 && parts[1].isNotEmpty()) parts[1] else "/"

        val accounts = getStorageAccounts()
        val acc = accounts.find { it.id == accId }
        if (acc == null) {
            android.util.Log.e("FineDocProvider", "queryChildDocuments: account $accId NOT FOUND in ${accounts.map { it.id }}")
            return result
        }

        if (acc.type == "webdav") {
            try {
                android.util.Log.i("FineDocProvider", "queryChildDocuments WebDAV accId=$accId parentPath=$parentPath")
                val files = fetchWebDavChildren(acc, parentPath)
                android.util.Log.i("FineDocProvider", "queryChildDocuments WebDAV returned ${files.size} items")
                for (f in files) {
                    val docId = "$accId:${f.path}"
                    val flags = if (f.isDir) {
                        DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                    } else {
                        DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                    }
                    val row = result.newRow()
                    for (col in proj) {
                        when (col) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row.add(docId)
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row.add(f.name)
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> row.add(if (f.isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(f.name))
                            DocumentsContract.Document.COLUMN_SIZE -> row.add(f.size)
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED -> row.add(f.lastModified)
                            DocumentsContract.Document.COLUMN_FLAGS -> row.add(flags)
                            else -> row.add(null)
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        } else if (acc.type == "baidu") {
            try {
                val files = fetchBaiduChildren(acc, parentPath)
                for (f in files) {
                    val docId = "$accId:${f.path}"
                    val flags = if (f.isDir) {
                        DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                    } else {
                        DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                    }
                    val row = result.newRow()
                    for (col in proj) {
                        when (col) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row.add(docId)
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row.add(f.name)
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> row.add(if (f.isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(f.name))
                            DocumentsContract.Document.COLUMN_SIZE -> row.add(f.size)
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED -> row.add(f.lastModified)
                            DocumentsContract.Document.COLUMN_FLAGS -> row.add(flags)
                            else -> row.add(null)
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        } else if (acc.type == "alipan") {
            try {
                val files = fetchAlipanChildren(acc, parentPath)
                for (f in files) {
                    val docId = "$accId:${f.path}"
                    val flags = if (f.isDir) {
                        DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                    } else {
                        DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                    }
                    val row = result.newRow()
                    for (col in proj) {
                        when (col) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row.add(docId)
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row.add(f.name)
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> row.add(if (f.isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(f.name))
                            DocumentsContract.Document.COLUMN_SIZE -> row.add(f.size)
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED -> row.add(f.lastModified)
                            DocumentsContract.Document.COLUMN_FLAGS -> row.add(flags)
                            else -> row.add(null)
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        } else if (acc.type == "quark") {
            try {
                val files = fetchQuarkChildren(acc, parentPath)
                for (f in files) {
                    val docId = "$accId:${f.path}"
                    val flags = if (f.isDir) {
                        DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                    } else {
                        DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                    }
                    val row = result.newRow()
                    for (col in proj) {
                        when (col) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> row.add(docId)
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> row.add(f.name)
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> row.add(if (f.isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(f.name))
                            DocumentsContract.Document.COLUMN_SIZE -> row.add(f.size)
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED -> row.add(f.lastModified)
                            DocumentsContract.Document.COLUMN_FLAGS -> row.add(flags)
                            else -> row.add(null)
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        return result
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val isWrite = mode.indexOf('w') != -1
        val parts = documentId.split(":", limit = 2)
        val accId = parts[0]
        val path = if (parts.size > 1 && parts[1].isNotEmpty()) parts[1] else "/"

        val accounts = getStorageAccounts()
        val acc = accounts.find { it.id == accId }
            ?: throw java.io.FileNotFoundException("Account not found")

        val ctx = context ?: throw java.io.FileNotFoundException("Context unavailable")
        val cacheDir = File(ctx.cacheDir, "webdav_cache")
        if (!cacheDir.exists()) cacheDir.mkdirs()

        val safeName = "${accId}_${File(path).name}"
        val localFile = File(cacheDir, safeName)

        // 如果是读取，先下载远端文件
        if (!isWrite && (!localFile.exists() || localFile.length() == 0L)) {
            if (acc.type == "baidu") {
                downloadBaiduFile(acc, path, localFile)
            } else if (acc.type == "alipan") {
                downloadAlipanFile(acc, path, localFile)
            } else if (acc.type == "quark") {
                downloadQuarkFile(acc, path, localFile)
            } else {
                downloadWebDavFile(acc, path, localFile)
            }
        }

        val accessMode = ParcelFileDescriptor.parseMode(mode)
        return ParcelFileDescriptor.open(localFile, accessMode)
    }

    private fun fetchBaiduChildren(acc: StorageAccount, folderPath: String): List<WebDavEntry> {
        val list = mutableListOf<WebDavEntry>()
        var token = if (acc.password.isNotEmpty()) acc.password else acc.extraToken
        if (token.startsWith("122.")) {
            try {
                val refreshUrl = "https://openapi.baidu.com/oauth/2.0/token?grant_type=refresh_token&refresh_token=$token&client_id=[REDACTED]&client_secret=[REDACTED]"
                val u = URL(refreshUrl)
                val c = u.openConnection() as HttpURLConnection
                c.requestMethod = "GET"
                if (c.responseCode in 200..299) {
                    val s = c.inputStream.bufferedReader().use { it.readText() }
                    val j = org.json.JSONObject(s)
                    token = j.optString("access_token", token)
                }
            } catch (e: Exception) {}
        }
        val cleanPath = folderPath.trim('/')
        val dirParam = if (cleanPath.isEmpty()) "/" else "/$cleanPath"
        val encodedDir = java.net.URLEncoder.encode(dirParam, "UTF-8")

        val fullUrl = "https://pan.baidu.com/rest/2.0/xpan/file?method=list&dir=$encodedDir&access_token=$token&folder=0&start=0&limit=1000"
        try {
            val url = URL(fullUrl)
            val conn = url.openConnection() as HttpURLConnection
            conn.requestMethod = "GET"
            // 关键：百度 OpenAPI 必须携带指定合法 UA
            conn.setRequestProperty("User-Agent", "pan.baidu.com")
            conn.connectTimeout = 10000
            conn.readTimeout = 20000

            val code = conn.responseCode
            if (code in 200..299) {
                val reader = java.io.BufferedReader(java.io.InputStreamReader(conn.inputStream, "UTF-8"))
                val sb = StringBuilder()
                var line: String? = reader.readLine()
                while (line != null) {
                    sb.append(line)
                    line = reader.readLine()
                }
                reader.close()

                val json = org.json.JSONObject(sb.toString())
                if (json.optInt("errno", -1) == 0) {
                    val arr = json.optJSONArray("list")
                    if (arr != null) {
                        for (i in 0 until arr.length()) {
                            val item = arr.getJSONObject(i)
                            val name = item.getString("server_filename")
                            val isDir = item.optInt("isdir", 0) == 1
                            val size = item.optLong("size", 0L)
                            val time = item.optLong("server_mtime", System.currentTimeMillis() / 1000) * 1000
                            val path = item.getString("path")
                            list.add(WebDavEntry(name = name, path = path, isDir = isDir, size = size, lastModified = time))
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return list
    }

    private fun setRequestMethodViaReflection(conn: HttpURLConnection, method: String) {
        try {
            conn.requestMethod = method
        } catch (pe: java.net.ProtocolException) {
            // Android 原生 HttpURLConnection 底层是 OkHttp，对非标准 HTTP 谓词 (PROPFIND 等) 抛 ProtocolException
            // 通过反射直接修改 field 'method' 彻底破除 Android 系统限制！
            try {
                var target: Any = conn
                if (conn is HttpsURLConnection) {
                    try {
                        val delegateField = conn.javaClass.getDeclaredField("delegate")
                        delegateField.isAccessible = true
                        target = delegateField.get(conn) ?: conn
                    } catch (e: Exception) {}
                }
                var c: Class<*>? = target.javaClass
                var methodField: java.lang.reflect.Field? = null
                while (c != null && methodField == null) {
                    try {
                        methodField = c.getDeclaredField("method")
                    } catch (e: Exception) {
                        c = c.superclass
                    }
                }
                if (methodField != null) {
                    methodField.isAccessible = true
                    methodField.set(target, method)
                }
            } catch (e: Exception) {
                android.util.Log.e("FineDocProvider", "Failed to reflect set method $method", e)
            }
        }
    }

    private fun fetchWebDavChildren(acc: StorageAccount, folderPath: String): List<WebDavEntry> {
        val list = mutableListOf<WebDavEntry>()
        var cleanServer = acc.serverUrl.trimEnd('/')
        if (!cleanServer.startsWith("http://") && !cleanServer.startsWith("https://")) {
            cleanServer = "http://$cleanServer"
        }
        val cleanPath = folderPath.trim('/')
        val fullUrl = if (cleanPath.isEmpty()) "$cleanServer/" else "$cleanServer/$cleanPath/"

        // 核心诊断保护：直接把 URL 和鉴权打到 Logcat，微信点进时一眼查出是 401 还是超时还是路径不对
        android.util.Log.i("FineDocProvider", ">>> fetchWebDavChildren start: url=$fullUrl username=${acc.username} hasPassword=${acc.password.isNotEmpty()}")

        val url = URL(fullUrl)
        val conn = url.openConnection() as HttpURLConnection
        // 允许跟随重定向 (针对部分 WebDAV 服务器末尾斜杠重定向)
        conn.instanceFollowRedirects = true
        setRequestMethodViaReflection(conn, "PROPFIND")
        conn.setRequestProperty("Depth", "1")
        conn.setRequestProperty("User-Agent", "FineFiles/1.0")
        if (acc.username.isNotEmpty()) {
            val auth = Base64.encodeToString("${acc.username}:${acc.password}".toByteArray(), Base64.NO_WRAP)
            conn.setRequestProperty("Authorization", "Basic $auth")
        }
        conn.connectTimeout = 6000
        conn.readTimeout = 10000

        try {
            val code = conn.responseCode
            android.util.Log.i("FineDocProvider", "WebDAV PROPFIND $fullUrl -> HTTP $code")
            if (code in 200..299) {
                // 读取完整 XML 字符串便于调试与容错
                val rawXml = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                android.util.Log.d("FineDocProvider", "WebDAV XML: ${rawXml.take(500)}")

                val factory = DocumentBuilderFactory.newInstance()
                factory.isNamespaceAware = false
                val builder = factory.newDocumentBuilder()
                val doc = builder.parse(org.xml.sax.InputSource(java.io.StringReader(rawXml)))
                var responses = doc.getElementsByTagName("d:response")
                if (responses.length == 0) responses = doc.getElementsByTagName("D:response")
                if (responses.length == 0) responses = doc.getElementsByTagName("response")

                for (i in 0 until responses.length) {
                    val resp = responses.item(i) as Element
                    var hrefNode = resp.getElementsByTagName("d:href").item(0)
                        ?: resp.getElementsByTagName("D:href").item(0)
                        ?: resp.getElementsByTagName("href").item(0)
                        ?: continue
                    var href = hrefNode.textContent.trim()
                    try {
                        href = URLDecoder.decode(href, "UTF-8")
                    } catch (e: Exception) {}

                    // 解析相对路径
                    var relPath = href
                    if (relPath.startsWith("http://") || relPath.startsWith("https://")) {
                        try {
                            val u = URL(relPath)
                            relPath = u.path
                        } catch (e: Exception) {}
                    }
                    
                    // 去除 serverUrl 路径前缀（不区分大小写，规范处理）
                    val serverBasePath = try {
                        URL(cleanServer).path.trimEnd('/')
                    } catch (e: Exception) {
                        ""
                    }
                    if (serverBasePath.isNotEmpty() && relPath.startsWith(serverBasePath)) {
                        relPath = relPath.substring(serverBasePath.length)
                    }
                    relPath = "/" + relPath.trim('/')

                    // 规范化比较路径（与 Dart 端逻辑严格 100% 保持一致）
                    val parentClean = "/" + cleanPath.trim('/')
                    if (relPath == parentClean || (parentClean == "/" && relPath == "/")) {
                        continue
                    }

                    var isDir = false
                    var size = 0L
                    var lastMod = System.currentTimeMillis()

                    val resTypes = resp.getElementsByTagName("collection")
                    val dResTypes = resp.getElementsByTagName("d:collection")
                    val capResTypes = resp.getElementsByTagName("D:collection")
                    if (resTypes.length > 0 || dResTypes.length > 0 || capResTypes.length > 0 || href.endsWith("/")) {
                        isDir = true
                    }

                    var getLens = resp.getElementsByTagName("getcontentlength")
                    if (getLens.length == 0) getLens = resp.getElementsByTagName("d:getcontentlength")
                    if (getLens.length == 0) getLens = resp.getElementsByTagName("D:getcontentlength")
                    if (getLens.length > 0) {
                        val s = getLens.item(0).textContent.trim().toLongOrNull() ?: 0L
                        if (s > 0) size = s
                    }

                    // 提取展示名称：优先从 displayname 获取，若没有则从路径截取
                    var displayName = ""
                    val dNames = resp.getElementsByTagName("displayname")
                    val ddNames = resp.getElementsByTagName("d:displayname")
                    val dcapNames = resp.getElementsByTagName("D:displayname")
                    if (dNames.length > 0 && dNames.item(0).textContent.trim().isNotEmpty()) {
                        displayName = dNames.item(0).textContent.trim()
                    } else if (ddNames.length > 0 && ddNames.item(0).textContent.trim().isNotEmpty()) {
                        displayName = ddNames.item(0).textContent.trim()
                    } else if (dcapNames.length > 0 && dcapNames.item(0).textContent.trim().isNotEmpty()) {
                        displayName = dcapNames.item(0).textContent.trim()
                    }
                    if (displayName.isEmpty()) {
                        displayName = relPath.split('/').lastOrNull { it.isNotEmpty() } ?: ""
                    }

                    if (displayName.isNotEmpty()) {
                        list.add(WebDavEntry(name = displayName, path = relPath, isDir = isDir, size = size, lastModified = lastMod))
                    }
                }
            } else {
                android.util.Log.e("FineDocProvider", "WebDAV HTTP Error: $code")
            }
        } catch (e: Exception) {
            android.util.Log.e("FineDocProvider", "WebDAV Exception", e)
            e.printStackTrace()
        }
        return list
    }

    private fun downloadBaiduFile(acc: StorageAccount, remotePath: String, dest: File) {
        var token = if (acc.password.isNotEmpty()) acc.password else acc.extraToken
        if (token.startsWith("122.")) {
            try {
                val refreshUrl = "https://openapi.baidu.com/oauth/2.0/token?grant_type=refresh_token&refresh_token=$token&client_id=[REDACTED]&client_secret=[REDACTED]"
                val u = URL(refreshUrl)
                val c = u.openConnection() as HttpURLConnection
                c.requestMethod = "GET"
                if (c.responseCode in 200..299) {
                    val s = c.inputStream.bufferedReader().use { it.readText() }
                    val j = org.json.JSONObject(s)
                    token = j.optString("access_token", token)
                }
            } catch (e: Exception) {}
        }
        val cleanPath = remotePath.trim('/')
        val encodedPath = java.net.URLEncoder.encode("/$cleanPath", "UTF-8")
        val dlinkUrl = "https://d.pcs.baidu.com/rest/2.0/pcs/file?method=download&access_token=$token&path=$encodedPath"
        val url = URL(dlinkUrl)
        val conn = url.openConnection() as HttpURLConnection
        conn.setRequestProperty("User-Agent", "netdisk")
        conn.connectTimeout = 8000
        conn.readTimeout = 30000

        conn.inputStream.use { input ->
            FileOutputStream(dest).use { output ->
                input.copyTo(output)
            }
        }
    }

    private fun fetchAlipanChildren(acc: StorageAccount, folderPath: String): List<WebDavEntry> {
        val list = mutableListOf<WebDavEntry>()
        var token = acc.password
        if (token.isEmpty() && acc.extraToken.isNotEmpty()) {
            try {
                val alistUrl = URL("https://api.alistgo.com/alist/ali_open/token?refresh_ui=" + java.net.URLEncoder.encode(acc.extraToken, "UTF-8") + "&server_use=true&driver_txt=alicloud_qr")
                val ac = alistUrl.openConnection() as HttpURLConnection
                ac.requestMethod = "GET"
                if (ac.responseCode in 200..299) {
                    val res = ac.inputStream.bufferedReader().use { it.readText() }
                    val json = JSONObject(res)
                    val aToken = json.optString("access_token", "")
                    if (aToken.isNotEmpty()) {
                        token = aToken
                        acc.password = token
                    }
                }
            } catch (e: Exception) {}

            if (token.isEmpty()) {
                try {
                    val u = URL("https://api.aliyundrive.com/token/refresh")
                    val c = u.openConnection() as HttpURLConnection
                    c.requestMethod = "POST"
                    c.setRequestProperty("Content-Type", "application/json")
                    c.doOutput = true
                    c.outputStream.use { it.write(JSONObject(mapOf("refresh_token" to acc.extraToken)).toString().toByteArray()) }
                    if (c.responseCode in 200..299) {
                        val res = c.inputStream.bufferedReader().use { it.readText() }
                        val json = JSONObject(res)
                        token = json.optString("access_token", token)
                        acc.password = token
                        acc.username = json.optString("default_drive_id", acc.username)
                    }
                } catch (e: Exception) {}
            }
        }

        var driveId = acc.username
        if (driveId.isEmpty()) {
            try {
                val u = URL("https://api.aliyundrive.com/v2/user/get")
                val c = u.openConnection() as HttpURLConnection
                c.requestMethod = "POST"
                c.setRequestProperty("Authorization", "Bearer $token")
                c.setRequestProperty("Content-Type", "application/json")
                c.doOutput = true
                c.outputStream.use { it.write("{}".toByteArray()) }
                if (c.responseCode in 200..299) {
                    val res = c.inputStream.bufferedReader().use { it.readText() }
                    driveId = JSONObject(res).optString("default_drive_id", "")
                    acc.username = driveId
                }
            } catch (e: Exception) {}
        }

        val cleanPath = folderPath.trim('/')
        val parentId = if (cleanPath.isEmpty()) "root" else cleanPath

        try {
            val u = URL("https://api.aliyundrive.com/adrive/v1.0/openFile/list")
            val c = u.openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.setRequestProperty("Authorization", "Bearer $token")
            c.setRequestProperty("Content-Type", "application/json")
            c.doOutput = true
            val reqBody = JSONObject()
            reqBody.put("drive_id", driveId)
            reqBody.put("parent_file_id", parentId)
            reqBody.put("limit", 200)
            c.outputStream.use { it.write(reqBody.toString().toByteArray()) }

            if (c.responseCode in 200..299) {
                val res = c.inputStream.bufferedReader().use { it.readText() }
                val items = JSONObject(res).optJSONArray("items")
                if (items != null) {
                    for (i in 0 until items.length()) {
                        val item = items.getJSONObject(i)
                        val isDir = item.optString("type") == "folder"
                        val name = item.optString("name")
                        val fileId = item.optString("file_id")
                        val size = item.optLong("size", 0L)
                        val lastMod = System.currentTimeMillis()
                        list.add(WebDavEntry(name = name, path = fileId, isDir = isDir, size = size, lastModified = lastMod))
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return list
    }

    private fun fetchQuarkChildren(acc: StorageAccount, folderPath: String): List<WebDavEntry> {
        val list = mutableListOf<WebDavEntry>()
        val cleanPath = folderPath.trim('/')
        val pdirFid = if (cleanPath.isEmpty()) "0" else cleanPath
        var cookie = acc.extraToken
        if (!cookie.contains("=")) cookie = "__puus=$cookie"

        try {
            val sortUrl = "https://drive.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=$pdirFid&_page=1&_size=200&_sort=file_type:asc,updated_at:desc"
            val u = URL(sortUrl)
            val c = u.openConnection() as HttpURLConnection
            c.requestMethod = "GET"
            c.setRequestProperty("Cookie", cookie)
            c.setRequestProperty("User-Agent", "Mozilla/5.0")
            c.setRequestProperty("Referer", "https://pan.quark.cn/")
            if (c.responseCode in 200..299) {
                val res = c.inputStream.bufferedReader().use { it.readText() }
                val j = JSONObject(res)
                val data = j.optJSONObject("data")
                val arr = data?.optJSONArray("list")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val item = arr.getJSONObject(i)
                        val isDir = item.optInt("file_type", 1) == 0
                        val name = item.optString("file_name")
                        val fid = item.optString("fid")
                        val size = item.optLong("size", 0L)
                        list.add(WebDavEntry(name = name, path = fid, isDir = isDir, size = size, lastModified = System.currentTimeMillis()))
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return list
    }

    private fun downloadAlipanFile(acc: StorageAccount, fileId: String, dest: File) {
        val token = acc.password
        val driveId = acc.username
        try {
            val u = URL("https://api.aliyundrive.com/v2/file/get_download_url")
            val c = u.openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.setRequestProperty("Authorization", "Bearer $token")
            c.setRequestProperty("Content-Type", "application/json")
            c.doOutput = true
            val body = JSONObject()
            body.put("drive_id", driveId)
            body.put("file_id", fileId)
            c.outputStream.use { it.write(body.toString().toByteArray()) }

            if (c.responseCode in 200..299) {
                val res = c.inputStream.bufferedReader().use { it.readText() }
                val downloadUrl = JSONObject(res).optString("url", "")
                if (downloadUrl.isNotEmpty()) {
                    val du = URL(downloadUrl)
                    val dc = du.openConnection() as HttpURLConnection
                    dc.setRequestProperty("User-Agent", "Mozilla/5.0")
                    dc.setRequestProperty("Referer", "https://www.aliyundrive.com/")
                    dc.inputStream.use { input ->
                        FileOutputStream(dest).use { output ->
                            input.copyTo(output)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun downloadQuarkFile(acc: StorageAccount, fid: String, dest: File) {
        var cookie = acc.extraToken
        if (!cookie.contains("=")) cookie = "__puus=$cookie"
        try {
            val u = URL("https://drive.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc&uc_param_str=")
            val c = u.openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.setRequestProperty("Cookie", cookie)
            c.setRequestProperty("User-Agent", "Mozilla/5.0")
            c.setRequestProperty("Referer", "https://pan.quark.cn/")
            c.setRequestProperty("Content-Type", "application/json")
            c.doOutput = true
            val body = JSONObject()
            val arr = JSONArray()
            arr.put(fid)
            body.put("fids", arr)
            c.outputStream.use { it.write(body.toString().toByteArray()) }

            if (c.responseCode in 200..299) {
                val res = c.inputStream.bufferedReader().use { it.readText() }
                val j = JSONObject(res)
                val data = j.optJSONArray("data")
                if (data != null && data.length() > 0) {
                    val downloadUrl = data.getJSONObject(0).optString("download_url", "")
                    if (downloadUrl.isNotEmpty()) {
                        val du = URL(downloadUrl)
                        val dc = du.openConnection() as HttpURLConnection
                        dc.setRequestProperty("User-Agent", "Mozilla/5.0")
                        dc.setRequestProperty("Referer", "https://pan.quark.cn/")
                        dc.setRequestProperty("Cookie", cookie)
                        dc.inputStream.use { input ->
                            FileOutputStream(dest).use { output ->
                                input.copyTo(output)
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun downloadWebDavFile(acc: StorageAccount, remotePath: String, dest: File) {
        val cleanServer = acc.serverUrl.trimEnd('/')
        val cleanPath = remotePath.trim('/')
        val url = URL("$cleanServer/$cleanPath")
        val conn = url.openConnection() as HttpURLConnection
        if (acc.username.isNotEmpty()) {
            val auth = Base64.encodeToString("${acc.username}:${acc.password}".toByteArray(), Base64.NO_WRAP)
            conn.setRequestProperty("Authorization", "Basic $auth")
        }
        conn.connectTimeout = 8000
        conn.readTimeout = 30000

        conn.inputStream.use { input ->
            FileOutputStream(dest).use { output ->
                input.copyTo(output)
            }
        }
    }

    private fun getMimeType(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "")
        if (ext.isEmpty()) return "application/octet-stream"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase()) ?: "application/octet-stream"
    }

    data class StorageAccount(
        val id: String,
        val name: String,
        val type: String,
        val serverUrl: String,
        var username: String,
        var password: String,
        val extraToken: String = ""
    )

    data class WebDavEntry(
        val name: String,
        val path: String,
        val isDir: Boolean,
        val size: Long,
        val lastModified: Long
    )
}

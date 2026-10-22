import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

// --------------------------------------------------------------------------
// 阿里云盘内置网页/扫码登录提取 Refresh Token 页面
// --------------------------------------------------------------------------
class AlipanLoginScreen extends StatefulWidget {
  const AlipanLoginScreen({super.key});

  @override
  State<AlipanLoginScreen> createState() => _AlipanLoginScreenState();
}

class _AlipanLoginScreenState extends State<AlipanLoginScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  Timer? _checkTimer;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.parse(request.url);
            if (!uri.scheme.startsWith('http')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (url) {
            setState(() => _isLoading = false);
            _inspectStorage();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.aliyundrive.com/sign/in'));

    _checkTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _inspectStorage();
    });
  }

  Future<void> _inspectStorage() async {
    try {
      final tokenJson = await _controller.runJavaScriptReturningResult('localStorage.getItem("token")') as String;
      if (tokenJson.isNotEmpty && tokenJson != 'null' && tokenJson != '""') {
        final decoded = jsonDecode(tokenJson is String && (tokenJson.startsWith('"') || tokenJson.startsWith('"{')) ? jsonDecode(tokenJson) : tokenJson);
        final refreshToken = decoded['refresh_token'] as String?;
        if (refreshToken != null && refreshToken.isNotEmpty) {
          _checkTimer?.cancel();
          if (mounted) {
            Navigator.pop(context, refreshToken);
          }
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('阿里云盘登录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// 夸克网盘内置网页/扫码登录提取 Cookie 页面
// --------------------------------------------------------------------------
class QuarkLoginScreen extends StatefulWidget {
  const QuarkLoginScreen({super.key});

  @override
  State<QuarkLoginScreen> createState() => _QuarkLoginScreenState();
}

class _QuarkLoginScreenState extends State<QuarkLoginScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  Timer? _checkTimer;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (iPad; CPU OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1')
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.parse(request.url);
            if (!uri.scheme.startsWith('http')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (url) {
            setState(() => _isLoading = false);
            // 自动注入样式，将夸克的二维码登录框置顶并适度放大，隐藏无关背景内容
            _controller.runJavaScript('''
              try {
                var loginBox = document.querySelector('.LoginComponent--modal--SE0w1Zi') || document.querySelector('[class*="LoginComponent"]');
                if (loginBox) {
                  loginBox.scrollIntoView({behavior: "smooth", block: "center"});
                }
              } catch(e) {}
            ''');
            _inspectCookies();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://pan.quark.cn/'));

    _checkTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _inspectCookies();
    });
  }

  Future<void> _inspectCookies({bool force = false}) async {
    try {
      // 通过 Android 原生 CookieManager 穿透提取 HttpOnly 保护的 __puus 和 __pus
      String nativeCookie = '';
      try {
        const channel = MethodChannel('com.sbitoh.finefiles/background_service');
        nativeCookie = await channel.invokeMethod<String>('getSystemCookies', {'url': 'https://pan.quark.cn'}) ?? '';
      } catch (_) {}

      final jsCookie = (await _controller.runJavaScriptReturningResult('document.cookie') as String).replaceAll('"', '');
      final combined = '$nativeCookie; $jsCookie';

      if (combined.contains('__puus=') || force) {
        _checkTimer?.cancel();
        if (mounted) {
          Navigator.pop(context, combined.isNotEmpty ? combined : jsCookie);
        }
      }
    } catch (_) {
      if (force && mounted) {
        _checkTimer?.cancel();
        Navigator.pop(context, 'force_login');
      }
    }
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('夸克网盘登录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
          TextButton(
            onPressed: () => _inspectCookies(force: true),
            child: const Text('完成登录', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// 百度网盘官方官方直连登录提取 Cookie (BDUSS) 页面 (纯官方，无任何第三方)
// --------------------------------------------------------------------------
class BaiduLoginScreen extends StatefulWidget {
  const BaiduLoginScreen({super.key});

  @override
  State<BaiduLoginScreen> createState() => _BaiduLoginScreenState();
}

class _BaiduLoginScreenState extends State<BaiduLoginScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  Timer? _checkTimer;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.parse(request.url);
            if (!uri.scheme.startsWith('http')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (url) {
            setState(() => _isLoading = false);
            // 只要页面加载完成，且 URL 已经进入了百度网盘主页 (pan.baidu.com)，说明登录已彻底完成！
            if (url.contains('pan.baidu.com/wap/home') || url.contains('pan.baidu.com/disk') || url.contains('pan.baidu.com/wap/welcome')) {
              _inspectCookies(force: true);
            } else {
              _inspectCookies();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://wappass.baidu.com/passport/login?adapter=3&u=https%3A%2F%2Fpan.baidu.com%2Fwap%2Fhome'));

    _checkTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _inspectCookies();
    });
  }

  Future<void> _inspectCookies({bool force = false}) async {
    try {
      // 1. 先通过 Android 原生 CookieManager 读取完整的系统 Cookie (包含所有 HttpOnly 的 BDUSS/STOKEN)
      // 注意：必须同时读取 .baidu.com 与 pan.baidu.com，因为 BDUSS 绑定在 .baidu.com 上！
      String nativeCookie = '';
      try {
        const channel = MethodChannel('com.sbitoh.finefiles/background_service');
        final c1 = await channel.invokeMethod<String>('getSystemCookies', {'url': 'https://baidu.com'}) ?? '';
        final c2 = await channel.invokeMethod<String>('getSystemCookies', {'url': 'https://pan.baidu.com'}) ?? '';
        final c3 = await channel.invokeMethod<String>('getSystemCookies', {'url': 'https://passport.baidu.com'}) ?? '';
        nativeCookie = '$c1; $c2; $c3';
      } catch (_) {}

      // 2. 网页端的 document.cookie
      final cookieString = await _controller.runJavaScriptReturningResult('document.cookie') as String;
      final cleanCookies = cookieString.replaceAll('"', '');

      final combined = '$nativeCookie; $cleanCookies';

      if (combined.contains('BDUSS=') || combined.contains('STOKEN=') || combined.contains('PANPSC=') || force) {
        _checkTimer?.cancel();
        if (mounted) {
          Navigator.pop(context, combined.isNotEmpty ? combined : cleanCookies);
        }
      }
    } catch (_) {
      if (force && mounted) {
        _checkTimer?.cancel();
        Navigator.pop(context, 'force_login');
      }
    }
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('百度网盘官方登录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
          TextButton(
            onPressed: () => _inspectCookies(force: true),
            child: const Text('完成', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

class BackgroundTransferManager {
  static const MethodChannel _channel = MethodChannel('com.sbitoh.finefiles/background_service');

  static Future<void> start(String title, [int progress = 0]) async {
    try {
      await _channel.invokeMethod('startTransferService', {
        'title': title,
        'progress': progress,
      });
    } catch (_) {}
  }

  static Future<void> update(String title, int progress) async {
    try {
      await _channel.invokeMethod('updateTransferService', {
        'title': title,
        'progress': progress,
      });
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopTransferService');
    } catch (_) {}
  }

  static Future<void> notifyRootsChanged() async {
    try {
      await _channel.invokeMethod('notifyRootsChanged');
    } catch (_) {}
  }
}

class BaiduUploader {
  // 百度单片大小（标准 4MB）
  static const int chunkSize = 4 * 1024 * 1024;

  static Future<bool> upload({
    required File file,
    required String targetPath,
    required String token,
    required void Function(double progress) onProgress,
  }) async {
    final fileSize = await file.length();
    final cleanPath = targetPath.replaceAll(RegExp(r'^/+|/+$'), '');
    final fullPath = cleanPath.isEmpty ? '/${file.path.split('/').last}' : '/$cleanPath';

    var cookie = token;
    if (!cookie.contains('=')) cookie = 'BDUSS=$token';

    // 1. 小于 4MB 的文件走单步快速直传 (支持 BDUSS Cookie 模式)
    if (fileSize <= chunkSize) {
      final uploadUrl = 'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=upload&path=${Uri.encodeComponent(fullPath)}&ondup=overwrite${token.startsWith('121.') || token.startsWith('122.') ? '&access_token=$token' : ''}';
      final request = ProgressMultipartRequest(
        'POST',
        Uri.parse(uploadUrl),
        onProgress: (bytes, total) {
          if (total > 0) onProgress(bytes / total);
        },
      );
      request.headers['User-Agent'] = 'netdisk;7.30.5;PC;PC-Windows;10.0.19041;WindowsBaiduYunGuanJia';
      request.headers['Cookie'] = cookie;
      request.files.add(await http.MultipartFile.fromPath('file', file.path, filename: file.path.split('/').last));
      final res = await request.send();
      return res.statusCode == 200;
    }

    // 2. 大于 4MB 的文件：严格遵循百度 OpenAPI 官方标准三步法 (precreate -> superfile2 -> create)
    final totalChunks = (fileSize / chunkSize).ceil();
    final List<String> blockList = [];
    final raf = await file.open(mode: FileMode.read);

    // 第一步：快速计算所有分块的 MD5
    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final length = (start + chunkSize > fileSize) ? (fileSize - start) : chunkSize;
        await raf.setPosition(start);
        final bytes = await raf.read(length);
        blockList.add(md5.convert(bytes).toString());
      }
    } finally {
      await raf.close();
    }

    // 第二步：向百度 OpenAPI / Web 端触发 precreate 预上传
    final isCookie = cookie.contains('BDUSS=');
    final precreateUrl = isCookie
        ? 'https://pan.baidu.com/api/precreate?clienttype=2'
        : 'https://pan.baidu.com/rest/2.0/xpan/file?method=precreate&access_token=$token';
    final precreateRes = await http.post(
      Uri.parse(precreateUrl),
      headers: {
        'User-Agent': 'netdisk;7.30.5;PC;PC-Windows;10.0.19041;WindowsBaiduYunGuanJia',
        if (isCookie) 'Cookie': cookie,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'path': fullPath,
        'size': fileSize.toString(),
        'isdir': '0',
        'autoinit': '1',
        'rtype': '3', // 覆盖
        'block_list': jsonEncode(blockList),
      },
    );

    debugPrint('Baidu precreate response: ${precreateRes.body}');
    if (precreateRes.statusCode != 200) {
      throw Exception('预上传失败 (HTTP ${precreateRes.statusCode})');
    }
    final preDec = jsonDecode(precreateRes.body);
    if (preDec['errno'] != 0) {
      throw Exception('预上传失败: ${preDec['errno']} (${precreateRes.body})');
    }

    // 如果网盘中已存在相同 MD5 文件，百度秒传直接返回 return_type = 2
    if (preDec['return_type'] == 2) {
      onProgress(1.0);
      return true;
    }

    final uploadid = preDec['uploadid'] as String;
    final List partsToUpload = preDec['block_list'] as List? ?? List.generate(totalChunks, (i) => i);

    // 动态获取百度上传节点域名 (AList 官方策略，避免 d.pcs.baidu.com 被 peer reset)
    String uploadHost = 'https://d.pcs.baidu.com';
    try {
      final locateUrl = 'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locateupload&appid=250528&path=${Uri.encodeComponent(fullPath)}&uploadid=${Uri.encodeComponent(uploadid)}&upload_version=2.0';
      final lResp = await http.get(Uri.parse(locateUrl));
      if (lResp.statusCode == 200) {
        final lData = jsonDecode(lResp.body);
        final servers = lData['servers'] as List?;
        if (servers != null && servers.isNotEmpty && servers[0]['server'] != null) {
          uploadHost = servers[0]['server'];
        } else {
          final bakServers = lData['bak_servers'] as List?;
          if (bakServers != null && bakServers.isNotEmpty && bakServers[0]['server'] != null) {
            uploadHost = bakServers[0]['server'];
          }
        }
      }
    } catch (e) {
      debugPrint('locateupload err: $e, fallback to $uploadHost');
    }

    // 第三步：按官方标准逐个上传分片到 superfile2
    final fileRaf = await file.open(mode: FileMode.read);
    int uploadedBytes = 0;

    try {
      for (int idx = 0; idx < partsToUpload.length; idx++) {
        final int partseq = (partsToUpload[idx] as num).toInt();
        final start = partseq * chunkSize;
        final length = (start + chunkSize > fileSize) ? (fileSize - start) : chunkSize;
        await fileRaf.setPosition(start);
        final chunkBytes = await fileRaf.read(length);

        final superfileUrl = isCookie
            ? '$uploadHost/rest/2.0/pcs/superfile2?method=upload&type=tmpfile&app_id=250528&path=${Uri.encodeComponent(fullPath)}&uploadid=${Uri.encodeComponent(uploadid)}&partseq=$partseq'
            : '$uploadHost/rest/2.0/pcs/superfile2?method=upload&access_token=$token&type=tmpfile&path=${Uri.encodeComponent(fullPath)}&uploadid=${Uri.encodeComponent(uploadid)}&partseq=$partseq';

        final request = http.MultipartRequest('POST', Uri.parse(superfileUrl));
        request.headers['User-Agent'] = 'netdisk;7.30.5;PC;PC-Windows;10.0.19041;WindowsBaiduYunGuanJia';
        if (isCookie) request.headers['Cookie'] = cookie;
        request.files.add(http.MultipartFile.fromBytes(
          'file',
          chunkBytes,
          filename: 'part-$partseq',
        ));

        final res = await request.send();
        if (res.statusCode != 200) {
          throw Exception('分片 $partseq 上传失败 (HTTP ${res.statusCode})');
        }

        uploadedBytes += chunkBytes.length;
        onProgress((uploadedBytes / fileSize) * 0.95);
      }
    } finally {
      await fileRaf.close();
    }

    // 第四步：所有分片上传成功后，调用 create 接口在网盘生成文件
    final createUrl = isCookie
        ? 'https://pan.baidu.com/api/create?a=commit&clienttype=2'
        : 'https://pan.baidu.com/rest/2.0/xpan/file?method=create&access_token=$token';
    final createRes = await http.post(
      Uri.parse(createUrl),
      headers: {
        'User-Agent': 'netdisk;7.30.5;PC;PC-Windows;10.0.19041;WindowsBaiduYunGuanJia',
        if (isCookie) 'Cookie': cookie,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'path': fullPath,
        'size': fileSize.toString(),
        'isdir': '0',
        'rtype': '3',
        'uploadid': uploadid,
        'block_list': jsonEncode(blockList),
      },
    );

    if (createRes.statusCode == 200) {
      final createDec = jsonDecode(createRes.body);
      if (createDec['errno'] == 0 || createDec['fs_id'] != null) {
        onProgress(1.0);
        return true;
      }
    }

    return false;
  }
}

class QuarkUploader {
  static Future<bool> upload({
    required File file,
    required String pdirFid,
    required String cookie,
    required void Function(double progress) onProgress,
  }) async {
    final fileSize = await file.length();
    final fileName = file.path.split('/').last;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    var actualCookie = cookie;
    if (!actualCookie.contains('=')) actualCookie = '__puus=$actualCookie';

    // 1. 预上传 pre
    final preUrl = 'https://drive.quark.cn/1/clouddrive/file/upload/pre?pr=ucpro&fr=pc';
    final preResp = await http.post(
      Uri.parse(preUrl),
      headers: {
        'Cookie': actualCookie,
        'Referer': 'https://pan.quark.cn/',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'ccp_hash_update': true,
        'dir_name': '',
        'file_name': fileName,
        'format_type': 'application/octet-stream',
        'l_created_at': nowMs,
        'l_updated_at': nowMs,
        'pdir_fid': pdirFid.isEmpty ? '0' : pdirFid,
        'size': fileSize,
      }),
    );

    debugPrint('Quark preResp: ${preResp.statusCode} body: ${preResp.body}');
    if (preResp.statusCode != 200) return false;
    final preJson = jsonDecode(preResp.body);
    if (preJson['code'] != 0) return false;

    final data = preJson['data'];
    final taskId = data['task_id'] as String;
    final bucket = data['bucket'] as String;
    final objKey = data['obj_key'] as String;
    final uploadId = data['upload_id'] as String;
    final authInfo = data['auth_info'] as String;
    final callbackData = data['callback'];
    final partSize = (preJson['metadata']?['part_size'] as num?)?.toInt() ?? 4194304;

    // 步骤 2: 计算全文件 MD5 与 SHA1 并同步更新 hash
    try {
      final wholeBytes = await file.readAsBytes();
      final md5Str = md5.convert(wholeBytes).toString();
      final sha1Str = sha1.convert(wholeBytes).toString();
      final hashResp = await http.post(
        Uri.parse('https://drive.quark.cn/1/clouddrive/file/update/hash?pr=ucpro&fr=pc'),
        headers: {
          'Cookie': actualCookie,
          'Referer': 'https://pan.quark.cn/',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'task_id': taskId,
          'md5': md5Str,
          'sha1': sha1Str,
        }),
      );
      debugPrint('Quark update/hash: ${hashResp.statusCode} body: ${hashResp.body}');
      if (hashResp.statusCode == 200) {
        final hJson = jsonDecode(hashResp.body);
        if (hJson['data']?['finish'] == true) {
          onProgress(1.0);
          return true;
        }
      }
    } catch (e) {
      debugPrint('Quark hash calc/update error: $e');
    }

    var uploadUrlStr = data['upload_url'] as String;
    if (uploadUrlStr.startsWith('http://')) {
      uploadUrlStr = uploadUrlStr.substring(7);
    } else if (uploadUrlStr.startsWith('https://')) {
      uploadUrlStr = uploadUrlStr.substring(8);
    }

    final totalParts = (fileSize / partSize).ceil();
    final List<String> etags = [];
    final raf = await file.open(mode: FileMode.read);
    int uploaded = 0;

    try {
      for (int i = 0; i < totalParts; i++) {
        final partNumber = i + 1;
        final start = i * partSize;
        final length = (start + partSize > fileSize) ? (fileSize - start) : partSize;
        await raf.setPosition(start);
        final chunkBytes = await raf.read(length);

        // 格式化 GMT 时间
        final nowUtc = DateTime.now().toUtc();
        final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        final timeStr = '${weekdays[nowUtc.weekday - 1]}, ${nowUtc.day.toString().padLeft(2, '0')} ${months[nowUtc.month - 1]} ${nowUtc.year} ${nowUtc.hour.toString().padLeft(2, '0')}:${nowUtc.minute.toString().padLeft(2, '0')}:${nowUtc.second.toString().padLeft(2, '0')} GMT';

        const mineType = 'application/octet-stream';
        final authMeta = 'PUT\n\n$mineType\n$timeStr\nx-oss-date:$timeStr\nx-oss-user-agent:aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit\n/$bucket/$objKey?partNumber=$partNumber&uploadId=$uploadId';

        // 获取 OSS 授权签名
        final authResp = await http.post(
          Uri.parse('https://drive.quark.cn/1/clouddrive/file/upload/auth?pr=ucpro&fr=pc'),
          headers: {
            'Cookie': actualCookie,
            'Referer': 'https://pan.quark.cn/',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'auth_info': authInfo,
            'auth_meta': authMeta,
            'task_id': taskId,
          }),
        );
        if (authResp.statusCode != 200) return false;
        final authJson = jsonDecode(authResp.body);
        final authKey = authJson['data']?['auth_key'] as String?;
        if (authKey == null) return false;

        // PUT 分片至 OSS
        final ossPutUrl = 'https://$bucket.$uploadUrlStr/$objKey?partNumber=$partNumber&uploadId=$uploadId';
        final ossReq = http.Request('PUT', Uri.parse(ossPutUrl));
        ossReq.headers.addAll({
          'Authorization': authKey,
          'Content-Type': mineType,
          'Referer': 'https://pan.quark.cn/',
          'x-oss-date': timeStr,
          'x-oss-user-agent': 'aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit',
        });
        ossReq.bodyBytes = chunkBytes;
        final streamedOss = await http.Client().send(ossReq);
        if (streamedOss.statusCode != 200) return false;
        final etag = streamedOss.headers['etag'] ?? streamedOss.headers['ETag'] ?? '';
        etags.add(etag);

        uploaded += length;
        onProgress((uploaded / fileSize) * 0.95);
      }
    } finally {
      await raf.close();
    }

    // 提交 commit
    final nowUtc = DateTime.now().toUtc();
    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final timeStr = '${weekdays[nowUtc.weekday - 1]}, ${nowUtc.day.toString().padLeft(2, '0')} ${months[nowUtc.month - 1]} ${nowUtc.year} ${nowUtc.hour.toString().padLeft(2, '0')}:${nowUtc.minute.toString().padLeft(2, '0')}:${nowUtc.second.toString().padLeft(2, '0')} GMT';

    final sb = StringBuffer();
    sb.write('<?xml version="1.0" encoding="UTF-8"?>\n<CompleteMultipartUpload>\n');
    for (int i = 0; i < etags.length; i++) {
      sb.write('<Part><PartNumber>${i + 1}</PartNumber><ETag>${etags[i]}</ETag></Part>\n');
    }
    sb.write('</CompleteMultipartUpload>');
    final xmlBody = sb.toString();

    final xmlMd5 = base64Encode(md5.convert(utf8.encode(xmlBody)).bytes);
    final callbackBase64 = base64Encode(utf8.encode(jsonEncode(callbackData)));

    final commitMeta = 'POST\n$xmlMd5\napplication/xml\n$timeStr\nx-oss-callback:$callbackBase64\nx-oss-date:$timeStr\nx-oss-user-agent:aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit\n/$bucket/$objKey?uploadId=$uploadId';

    final commitAuthResp = await http.post(
      Uri.parse('https://drive.quark.cn/1/clouddrive/file/upload/auth?pr=ucpro&fr=pc'),
      headers: {
        'Cookie': actualCookie,
        'Referer': 'https://pan.quark.cn/',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'auth_info': authInfo,
        'auth_meta': commitMeta,
        'task_id': taskId,
      }),
    );
    if (commitAuthResp.statusCode != 200) return false;
    final commitAuthKey = jsonDecode(commitAuthResp.body)['data']?['auth_key'] as String?;
    if (commitAuthKey == null) return false;

    // POST Commit 至 OSS
    final commitUrl = 'https://$bucket.$uploadUrlStr/$objKey?uploadId=$uploadId';
    final commitReq = http.Request('POST', Uri.parse(commitUrl));
    commitReq.headers.addAll({
      'Authorization': commitAuthKey,
      'Content-MD5': xmlMd5,
      'Referer': 'https://pan.quark.cn/',
      'x-oss-callback': callbackBase64,
      'x-oss-date': timeStr,
      'x-oss-user-agent': 'aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit',
    });
    commitReq.headers['Content-Type'] = 'application/xml';
    commitReq.bodyBytes = utf8.encode(xmlBody);
    final streamedCommit = await http.Client().send(commitReq);
    final commitRespBody = await streamedCommit.stream.bytesToString();
    debugPrint('Quark commit status: ${streamedCommit.statusCode} body: $commitRespBody');
    // 阿里云 OSS 回调失败（如 203 CallbackFailed）时，分片文件其实已完整上传成功
    if (streamedCommit.statusCode != 200 && streamedCommit.statusCode != 203) return false;

    // finish
    final finishResp = await http.post(
      Uri.parse('https://drive.quark.cn/1/clouddrive/file/upload/finish?pr=ucpro&fr=pc'),
      headers: {
        'Cookie': actualCookie,
        'Referer': 'https://pan.quark.cn/',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'obj_key': objKey,
        'task_id': taskId,
      }),
    );
    debugPrint('Quark finishResp: ${finishResp.statusCode} body: ${finishResp.body}');
    if (finishResp.statusCode == 200) {
      final fJson = jsonDecode(finishResp.body);
      if (fJson['code'] == 0 || fJson['status'] == 200) {
        onProgress(1.0);
        return true;
      }
    }
    return false;
  }
}

class ProgressStreamRequest extends http.BaseRequest {
  final http.ByteStream _stream;
  final int _contentLength;
  final void Function(int bytes, int totalBytes)? onProgress;

  ProgressStreamRequest(
    super.method,
    super.url,
    Stream<List<int>> stream,
    this._contentLength, {
    this.onProgress,
  }) : _stream = http.ByteStream(stream);

  @override
  int get contentLength => _contentLength;

  @override
  http.ByteStream finalize() {
    super.finalize();
    if (onProgress == null) return _stream;
    int bytes = 0;
    final t = StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (List<int> data, EventSink<List<int>> sink) {
        bytes += data.length;
        if (_contentLength > 0) {
          onProgress!(bytes, _contentLength);
        }
        sink.add(data);
      },
    );
    return http.ByteStream(_stream.transform(t));
  }
}

class AlipanUploader {
  static Future<bool> upload({
    required File file,
    required String targetFolder,
    required StorageAccount account,
    required void Function(double progress) onProgress,
  }) async {
    try {
      var token = account.password.isNotEmpty ? account.password : account.extraToken;
      if (token.length == 32) {
        final rResp = await http.post(
          Uri.parse('https://api.aliyundrive.com/token/refresh'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': token}),
        );
        if (rResp.statusCode == 200) token = jsonDecode(rResp.body)['access_token'];
      }
      var driveId = account.serverUrl;
      if (driveId == 'resource' || driveId.isEmpty) {
        final uResp = await http.post(
          Uri.parse('https://user.aliyundrive.com/v2/user/get'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
          body: '{}',
        );
        if (uResp.statusCode == 200) {
          final uData = jsonDecode(uResp.body);
          driveId = uData['resource_drive_id'] ?? uData['default_drive_id'] ?? '';
        }
      }
      final parentId = (targetFolder == '/' || targetFolder.isEmpty) ? 'root' : targetFolder;
      final fileName = file.path.split('/').last;
      final fileSize = await file.length();

      // 分片策略：10MB 一片，计算总片数
      const partSize = 10 * 1024 * 1024;
      final numParts = (fileSize / partSize).ceil() == 0 ? 1 : (fileSize / partSize).ceil();
      final partInfoList = <Map<String, dynamic>>[];
      for (int i = 1; i <= numParts; i++) {
        partInfoList.add({'part_number': i});
      }

      final preResp = await http.post(
        Uri.parse('https://api.aliyundrive.com/adrive/v2/file/createWithFolders'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'drive_id': driveId,
          'parent_file_id': parentId,
          'name': fileName,
          'type': 'file',
          'check_name_mode': 'auto_rename',
          'size': fileSize,
          'part_info_list': partInfoList,
        }),
      );

      if (preResp.statusCode != 200 && preResp.statusCode != 201) {
        debugPrint('Alipan create failed: ${preResp.statusCode} ${preResp.body}');
        return false;
      }

      final pData = jsonDecode(preResp.body);
      final fileId = pData['file_id'];
      final uploadId = pData['upload_id'];
      final returnedParts = pData['part_info_list'] as List? ?? [];

      // 若已经秒传完成
      if (pData['exist'] == true || returnedParts.isEmpty) {
        onProgress(1.0);
        return true;
      }

      final client = http.Client();
      int totalUploaded = 0;

      for (var part in returnedParts) {
        final partNum = part['part_number'] as int;
        final uploadUrl = part['upload_url'] as String?;
        if (uploadUrl == null) continue;

        final start = (partNum - 1) * partSize;
        final end = (start + partSize) > fileSize ? fileSize : (start + partSize);
        final currentPartLength = end - start;

        final stream = file.openRead(start, end);
        final putReq = ProgressStreamRequest(
          'PUT',
          Uri.parse(uploadUrl),
          stream,
          currentPartLength,
          onProgress: (sent, _) {
            final cur = totalUploaded + sent;
            if (fileSize > 0) {
              onProgress(cur / fileSize);
            }
          },
        );
        putReq.headers['Content-Type'] = '';

        debugPrint('Alipan uploading part $partNum/$numParts length: $currentPartLength');
        final streamed = await client.send(putReq);
        final putRespBody = await streamed.stream.bytesToString();
        debugPrint('Alipan part $partNum status: ${streamed.statusCode} body: $putRespBody');
        if (streamed.statusCode != 200 && streamed.statusCode != 204) {
          debugPrint('Alipan part $partNum upload failed: ${streamed.statusCode}');
          return false;
        }
        totalUploaded += currentPartLength;
      }

      // 完成合并
      final compResp = await http.post(
        Uri.parse('https://api.aliyundrive.com/v2/file/complete'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'drive_id': driveId,
          'file_id': fileId,
          'upload_id': uploadId,
        }),
      );

      if (compResp.statusCode == 200) {
        onProgress(1.0);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('AlipanUploader error: $e');
      return false;
    }
  }
}

class ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(int bytes, int totalBytes)? onProgress;

  ProgressMultipartRequest(
    super.method,
    super.url, {
    this.onProgress,
  });

  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();
    if (onProgress == null) return byteStream;

    final total = contentLength;
    int bytes = 0;

    final t = StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (List<int> data, EventSink<List<int>> sink) {
        bytes += data.length;
        if (total > 0) {
          onProgress!(bytes, total);
        }
        sink.add(data);
      },
    );

    return http.ByteStream(byteStream.transform(t));
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String savedLang = 'zh';
  try {
    final prefs = await SharedPreferences.getInstance();
    savedLang = prefs.getString('app_lang') ?? 'zh';
  } catch (e) {
    debugPrint('SharedPreferences init fallback: $e');
  }
  runApp(FineFilesApp(initialLocale: Locale(savedLang)));
}

class StorageAccount {
  final String id;
  String name;
  final String type; // 'webdav', 'alipan', 'quark', 'baidu'
  String serverUrl;
  String username;
  String password;
  String extraToken;

  StorageAccount({
    required this.id,
    required this.name,
    required this.type,
    required this.serverUrl,
    required this.username,
    required this.password,
    this.extraToken = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
        'extraToken': extraToken,
      };

  factory StorageAccount.fromJson(Map<String, dynamic> json) => StorageAccount(
        id: json['id'] ?? '',
        name: json['name'] ?? '',
        type: json['type'] ?? 'webdav',
        serverUrl: json['serverUrl'] ?? '',
        username: json['username'] ?? '',
        password: json['password'] ?? '',
        extraToken: json['extraToken'] ?? '',
      );
}

class FineFilesApp extends StatefulWidget {
  final Locale initialLocale;
  const FineFilesApp({super.key, required this.initialLocale});

  static void setLocale(BuildContext context, Locale newLocale) {
    _FineFilesAppState? state =
        context.findAncestorStateOfType<_FineFilesAppState>();
    state?.changeLocale(newLocale);
  }

  @override
  State<FineFilesApp> createState() => _FineFilesAppState();
}

class _FineFilesAppState extends State<FineFilesApp> {
  late Locale _locale;

  @override
  void initState() {
    super.initState();
    _locale = widget.initialLocale;
  }

  void changeLocale(Locale locale) async {
    setState(() {
      _locale = locale;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_lang', locale.languageCode);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _locale.languageCode == 'en' ? 'FineFiles' : '初晴文件管理',
      debugShowCheckedModeBanner: false,
      locale: _locale,
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0284C7),
          brightness: Brightness.light,
          primary: const Color(0xFF0284C7),
          surface: const Color(0xFFF8FAFC),
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 1,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<StorageAccount> _accounts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkStoragePermission();
    });
  }

  Future<void> _checkStoragePermission() async {
    final status = await Permission.manageExternalStorage.status;
    if (!status.isGranted && mounted) {
      final isEn = _isEn(context);
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.folder_shared, color: Color(0xFF0284C7)),
              const SizedBox(width: 8),
              Text(isEn ? 'Storage Permission' : '需要授予存储权限'),
            ],
          ),
          content: Text(
            isEn
                ? 'FineFiles needs "All files access" to browse local storage, select files for upload, and save downloaded files.'
                : '初晴文件管理需要“所有文件访问权限”，以便直接浏览手机本地文件、选择文件上传至云端以及保存下载的文件。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isEn ? 'Later' : '稍后再说'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                await Permission.manageExternalStorage.request();
              },
              child: Text(isEn ? 'Grant Permission' : '去授予权限'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _loadAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var jsonStr = prefs.getString('storage_accounts');

      if (jsonStr == null || jsonStr.isEmpty || jsonStr == '[]') {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final extFile = File('${extDir.path}/storage_accounts.json');
          if (await extFile.exists()) {
            jsonStr = await extFile.readAsString();
          }
        }
      }

      if (jsonStr != null && jsonStr.isNotEmpty && jsonStr != '[]') {
        final List decoded = jsonDecode(jsonStr);
        _accounts = decoded.map((e) => StorageAccount.fromJson(e)).toList();
      }
    } catch (_) {}
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _saveAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_accounts.map((e) => e.toJson()).toList());
      await prefs.setString('storage_accounts', jsonStr);

      // 双保险落盘：同步写入 context.filesDir 与 getExternalFilesDir，供底层 DocumentsProvider 跨进程 100% 稳定读取
      final docDir = await getApplicationDocumentsDirectory();
      final backupFile = File('${docDir.parent.path}/files/storage_accounts.json');
      await backupFile.parent.create(recursive: true);
      await backupFile.writeAsString(jsonStr);

      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final extFile = File('${extDir.path}/storage_accounts.json');
        await extFile.writeAsString(jsonStr);
      }

      // 通知系统 DocumentsUI 实时刷新根盘符与挂载点
      await BackgroundTransferManager.notifyRootsChanged();
    } catch (_) {}
  }

  bool _isEn(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'en';

  @override
  Widget build(BuildContext context) {
    final isEn = _isEn(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(isEn ? 'FineFiles' : '初晴文件管理'),
        actions: [
          // 显式汉字/英文语言切换药丸按钮（一眼看懂）
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                backgroundColor: const Color(0xFFF1F5F9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
              ),
              onPressed: () {
                FineFilesApp.setLocale(
                  context,
                  isEn ? const Locale('zh', 'CN') : const Locale('en', 'US'),
                );
              },
              child: Text(
                isEn ? '中 / EN' : 'EN / 中',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0284C7),
                ),
              ),
            ),
          ),
          // 关于入口
          IconButton(
            icon: const Icon(Icons.info_outline, color: Color(0xFF475569)),
            tooltip: isEn ? 'About' : '关于',
            onPressed: () => _showAboutDialog(context),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // SAF 系统激活状态条
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.08),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF38BDF8).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.verified_outlined,
                                color: Color(0xFF38BDF8), size: 18),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            isEn ? 'System-level SAF Mount Ready' : '系统级 SAF 存储驱动已激活',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isEn
                            ? 'Drives configured below will automatically appear in WeChat, WPS, and Android native file picker.'
                            : '已添加的存储将自动接入 Android 底层。在微信、WPS 发送或选取文件时，侧边栏直接可见并无缝访问。',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),

                // 本地内置存储卡片
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE0F2FE),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.phone_android_outlined, color: Color(0xFF0284C7)),
                    ),
                    title: Text(
                      isEn ? 'Internal Storage' : '手机内部存储',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    subtitle: Text(
                      isEn ? 'Browse local files, downloads & media' : '浏览本机文件、下载目录、照片与文档',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                    onTap: () async {
                      // 申请权限后进入本地文件浏览
                      var status = await Permission.manageExternalStorage.status;
                      if (!status.isGranted) {
                        status = await Permission.manageExternalStorage.request();
                        if (!status.isGranted) {
                          await Permission.storage.request();
                        }
                      }
                      if (context.mounted) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LocalFileBrowserScreen(currentPath: '/storage/emulated/0'),
                          ),
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),

                // 列表标题与快速添加
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        isEn ? 'Mounted Cloud Storage' : '已连接的云端与网盘',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _showAddStorageSheet(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(isEn ? 'Add' : '添加存储'),
                      ),
                    ],
                  ),
                ),

                // 驱动器列表或空状态
                Expanded(
                  child: _accounts.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 80,
                                  height: 80,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE2E8F0).withOpacity(0.5),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(Icons.cloud_queue_outlined,
                                      size: 44, color: Colors.blueGrey.shade400),
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  isEn ? 'No cloud storage mounted' : '暂未添加任何云盘或存储',
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                const SizedBox(height: 6),
                Text(
                  isEn
                      ? 'Supports WebDAV, NAS, Alipan, Baidu Netdisk, Quark'
                      : '支持标准 WebDAV · 家用 NAS · 阿里云盘 · 百度网盘 · 夸克网盘',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12,
                  ),
                ),

                                const SizedBox(height: 20),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF0284C7),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 24, vertical: 12),
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: () => _showAddStorageSheet(context),
                                  icon: const Icon(Icons.add),
                                  label: Text(isEn ? 'Add Storage / Drive' : '添加网盘与存储'),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          itemCount: _accounts.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (ctx, idx) {
                            final acc = _accounts[idx];
                            return Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                    color: const Color(0xFFE2E8F0)),
                              ),
                              child: ListTile(
                                leading: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE0F2FE),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    _getDriveIcon(acc.type),
                                    color: const Color(0xFF0284C7),
                                  ),
                                ),
                                title: Text(
                                  acc.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                                subtitle: Text(
                                  acc.type == 'webdav'
                                      ? acc.serverUrl
                                      : '${acc.type.toUpperCase()} · ${isEn ? "Cloud Drive" : "官方直连网盘"}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          color: Colors.redAccent, size: 20),
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: Text(isEn ? 'Delete Storage' : '删除存储账号'),
                                            content: Text(isEn
                                                ? 'Are you sure you want to remove "${acc.name}"? (Files on the cloud drive will not be deleted)'
                                                : '确定要删除存储账号 "${acc.name}" 吗？（仅移除本地挂载，不会删除网盘内文件）'),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(ctx, false),
                                                child: Text(isEn ? 'Cancel' : '取消'),
                                              ),
                                              ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: Colors.redAccent,
                                                  foregroundColor: Colors.white,
                                                ),
                                                onPressed: () => Navigator.pop(ctx, true),
                                                child: Text(isEn ? 'Delete' : '确认删除'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          setState(() {
                                            _accounts.removeAt(idx);
                                          });
                                          _saveAccounts();
                                        }
                                      },
                                    ),
                                    const Icon(Icons.chevron_right,
                                        color: Colors.grey),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => FileBrowserScreen(
                                        account: acc,
                                        currentPath: '/',
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  IconData _getDriveIcon(String type) {
    switch (type) {
      case 'alipan':
        return Icons.rocket_launch_outlined;
      case 'quark':
        return Icons.flash_on_outlined;
      case 'baidu':
        return Icons.all_inclusive_outlined;
      default:
        return Icons.dns_outlined;
    }
  }

  void _showAddStorageSheet(BuildContext context) {
    final isEn = _isEn(context);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 12),
                child: Text(
                  isEn ? 'Select Storage Type' : '选择要连接的存储类型',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              _buildTypeTile(
                icon: Icons.dns_outlined,
                title: isEn ? 'WebDAV / Self-hosted NAS' : 'WebDAV / 家用 NAS / 坚果云',
                subtitle: isEn
                    ? 'Connect to Synology, QNAP, TrueNAS, AList, etc.'
                    : '支持群晖、威联通、TrueNAS、AList 或标准 WebDAV 服务',
                onTap: () {
                  Navigator.pop(ctx);
                  _showWebDavDialog(context);
                },
              ),
              _buildTypeTile(
                icon: Icons.rocket_launch_outlined,
                title: isEn ? 'Aliyun Drive (阿里云盘)' : '阿里云盘 (开放平台直连)',
                subtitle: isEn
                    ? 'Connect via Refresh Token / OAuth'
                    : '免中间服务直连，输入 Refresh Token 自动挂载',
                onTap: () {
                  Navigator.pop(ctx);
                  _showAlipanDialog(context);
                },
              ),
              _buildTypeTile(
                icon: Icons.flash_on_outlined,
                title: isEn ? 'Quark Drive (夸克网盘)' : '夸克网盘 (极速直连)',
                subtitle: isEn
                    ? 'Direct connection via Cookie / __puus'
                    : '免搭建第三方代理，输入 Cookie 或 __puus 直接接入',
                onTap: () {
                  Navigator.pop(ctx);
                  _showQuarkDialog(context);
                },
              ),
              _buildTypeTile(
                icon: Icons.all_inclusive_outlined,
                title: isEn ? 'Baidu Netdisk (百度网盘)' : '百度网盘 (开放平台直连)',
                subtitle: isEn
                    ? 'Baidu Netdisk OpenAPI direct connection'
                    : '通过百度开发者 Access Token 直接接入系统底层',
                onTap: () {
                  Navigator.pop(ctx);
                  _showBaiduDialog(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypeTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFFE0F2FE),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: const Color(0xFF0284C7)),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      onTap: onTap,
    );
  }

  // 1. WebDAV 弹窗（脱敏，纯净空白默认值）
  void _showWebDavDialog(BuildContext context) {
    final isEn = _isEn(context);
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(isEn ? 'Add WebDAV Storage' : '添加 WebDAV 存储'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: isEn ? 'Drive Name' : '驱动器名称',
                  hintText: isEn ? 'e.g. My Storage' : '例如：家庭 NAS / 坚果云',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  labelText: isEn ? 'WebDAV Server URL' : '服务器完整地址 (URL)',
                  hintText: 'https://example.com/dav',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: userCtrl,
                decoration: InputDecoration(
                  labelText: isEn ? 'Username (Optional)' : '用户名 (选填)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: isEn ? 'Password (Optional)' : '密码 (选填)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(isEn ? 'Cancel' : '取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              if (urlCtrl.text.trim().isEmpty) return;
              final newAcc = StorageAccount(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                name: nameCtrl.text.trim().isEmpty ? 'WebDAV' : nameCtrl.text.trim(),
                type: 'webdav',
                serverUrl: urlCtrl.text.trim(),
                username: userCtrl.text.trim(),
                password: passCtrl.text.trim(),
              );
              setState(() {
                _accounts.add(newAcc);
              });
              _saveAccounts();
              Navigator.pop(ctx);
            },
            child: Text(isEn ? 'Save & Mount' : '保存并挂载'),
          ),
        ],
      ),
    );
  }

  // 2. 阿里云盘弹窗 (支持内置扫码/一键登录 与 手动输入)
  void _showAlipanDialog(BuildContext context) {
    final isEn = _isEn(context);
    final nameCtrl = TextEditingController(text: isEn ? 'Aliyun Drive' : '阿里云盘');
    final tokenCtrl = TextEditingController();
    String driveCategory = 'resource'; // 'resource' 资源盘(默认), 'backup' 备份盘

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(isEn ? 'Mount Aliyun Drive' : '挂载阿里云盘'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: isEn ? 'Drive Name' : '网盘显示名称',
                  ),
                ),
                const SizedBox(height: 12),
                // 方案一：内置一键网页/扫码登录
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    label: Text(
                      isEn ? 'Log in with Aliyun (Scan / Web)' : '内置网页/扫码一键登录',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () async {
                      final resultToken = await Navigator.push<String?>(
                        context,
                        MaterialPageRoute(builder: (_) => const AlipanLoginScreen()),
                      );
                      if (resultToken != null && resultToken.isNotEmpty) {
                        final newAcc = StorageAccount(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          name: nameCtrl.text.trim().isEmpty ? '阿里云盘' : nameCtrl.text.trim(),
                          type: 'alipan',
                          serverUrl: driveCategory,
                          username: '',
                          password: '',
                          extraToken: resultToken,
                        );
                        setState(() {
                          _accounts.add(newAcc);
                        });
                        _saveAccounts();
                        Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(isEn ? 'Aliyun Drive mounted successfully!' : '阿里云盘登录并挂载成功！')),
                          );
                        }
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        isEn ? 'OR MANUAL INPUT' : '或 手动输入凭据',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: tokenCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Refresh Token',
                    hintText: isEn ? 'Paste Refresh Token' : '粘贴阿里云盘 Refresh Token',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isEn ? 'Drive Space Type:' : '默认进入分区：',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(isEn ? 'Resource Space (Web / Shared files)' : '资源库（网页端、转存分享内容）'),
                  value: 'resource',
                  groupValue: driveCategory,
                  onChanged: (v) {
                    setDialogState(() => driveCategory = v ?? 'resource');
                  },
                ),
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(isEn ? 'Backup Space (Mobile auto-backups)' : '备份盘（手机照片、设备备份文件夹）'),
                  value: 'backup',
                  groupValue: driveCategory,
                  onChanged: (v) {
                    setDialogState(() => driveCategory = v ?? 'backup');
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  isEn
                      ? 'Tip: App directly exchanges access tokens using official OpenAPI, completely client-side.'
                      : '说明：支持一键扫码/网页登录，亦可手动填入 Token。端对端官方通信。',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isEn ? 'Cancel' : '取消'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (tokenCtrl.text.trim().isEmpty) return;
                final newAcc = StorageAccount(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameCtrl.text.trim().isEmpty ? '阿里云盘' : nameCtrl.text.trim(),
                  type: 'alipan',
                  serverUrl: driveCategory, // 记录选择的分区
                  username: '',
                  password: '',
                  extraToken: tokenCtrl.text.trim(),
                );
                setState(() {
                  _accounts.add(newAcc);
                });
                _saveAccounts();
                Navigator.pop(ctx);
              },
              child: Text(isEn ? 'Save & Mount' : '保存并挂载'),
            ),
          ],
        ),
      ),
    );
  }

  // 2.1 夸克网盘弹窗 (支持内置扫码/一键登录 与 手动输入)
  void _showQuarkDialog(BuildContext context) {
    final isEn = _isEn(context);
    final nameCtrl = TextEditingController(text: isEn ? 'Quark Drive' : '夸克网盘');
    final cookieCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(isEn ? 'Mount Quark Drive' : '挂载夸克网盘'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: isEn ? 'Drive Name' : '网盘显示名称',
                  ),
                ),
                const SizedBox(height: 12),
                // 方案一：内置一键网页/扫码登录
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    label: Text(
                      isEn ? 'Log in with Quark (Scan / Web)' : '内置网页/扫码一键登录',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () async {
                      final resultCookie = await Navigator.push<String?>(
                        context,
                        MaterialPageRoute(builder: (_) => const QuarkLoginScreen()),
                      );
                      if (resultCookie != null && resultCookie.isNotEmpty) {
                        final newAcc = StorageAccount(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          name: nameCtrl.text.trim().isEmpty ? '夸克网盘' : nameCtrl.text.trim(),
                          type: 'quark',
                          serverUrl: 'https://drive.quark.cn',
                          username: '',
                          password: '',
                          extraToken: resultCookie,
                        );
                        setState(() {
                          _accounts.add(newAcc);
                        });
                        _saveAccounts();
                        Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(isEn ? 'Quark Drive mounted successfully!' : '夸克网盘登录并挂载成功！')),
                          );
                        }
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        isEn ? 'OR MANUAL INPUT' : '或 手动输入凭据',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: cookieCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Cookie / __puus',
                    hintText: isEn ? 'Paste Cookie or __puus' : '粘贴网页端 Cookie 或 __puus',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isEn
                      ? 'Tip: App directly communicates with Quark cloud API via SSL.'
                      : '说明：支持一键扫码/网页登录（推荐，完整捕获凭据不失效），亦可手动粘贴 Cookie。',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isEn ? 'Cancel' : '取消'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (cookieCtrl.text.trim().isEmpty) return;
                final newAcc = StorageAccount(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameCtrl.text.trim().isEmpty ? '夸克网盘' : nameCtrl.text.trim(),
                  type: 'quark',
                  serverUrl: 'https://drive.quark.cn',
                  username: '',
                  password: '',
                  extraToken: cookieCtrl.text.trim(),
                );
                setState(() {
                  _accounts.add(newAcc);
                });
                _saveAccounts();
                Navigator.pop(ctx);
              },
              child: Text(isEn ? 'Save & Mount' : '保存并挂载'),
            ),
          ],
        ),
      ),
    );
  }

  // 4. 百度网盘弹窗 (支持内置扫码/账号一键登录 与 手动输入)
  void _showBaiduDialog(BuildContext context) {
    final isEn = _isEn(context);
    final nameCtrl = TextEditingController(text: isEn ? 'Baidu Netdisk' : '百度网盘');
    final tokenCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(isEn ? 'Mount Baidu Netdisk' : '挂载百度网盘'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: isEn ? 'Drive Name' : '网盘显示名称',
                  ),
                ),
                const SizedBox(height: 12),
                // 方案一：内置一键网页/扫码登录
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    label: Text(
                      isEn ? 'Log in with Baidu (Scan / Web)' : '内置网页/扫码一键登录',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () async {
                      final resultCookie = await Navigator.push<String?>(
                        context,
                        MaterialPageRoute(builder: (_) => const BaiduLoginScreen()),
                      );
                      if (resultCookie != null && resultCookie.isNotEmpty) {
                        final newAcc = StorageAccount(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          name: nameCtrl.text.trim().isEmpty ? '百度网盘' : nameCtrl.text.trim(),
                          type: 'baidu',
                          serverUrl: 'https://pan.baidu.com',
                          username: '',
                          password: '',
                          extraToken: resultCookie,
                        );
                        setState(() {
                          _accounts.add(newAcc);
                        });
                        _saveAccounts();
                        Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(isEn ? 'Baidu Netdisk mounted successfully!' : '百度网盘登录并挂载成功！')),
                          );
                        }
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        isEn ? 'OR MANUAL INPUT' : '或 手动输入凭据',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: tokenCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: isEn ? 'Cookie (BDUSS) / Token' : 'BDUSS 或 完整 Cookie / Token',
                    hintText: isEn ? 'Paste BDUSS or full Cookie' : '可手动粘贴 BDUSS 或 完整 Cookie',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isEn
                      ? 'Tip: You can log in via scan/web above, or paste BDUSS directly. No developer registration needed.'
                      : '说明：支持上方一键扫码/网页登录，亦可直接粘贴 BDUSS。无需申请开发者权限，任何人均可使用。',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isEn ? 'Cancel' : '取消'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (tokenCtrl.text.trim().isEmpty) return;
                final newAcc = StorageAccount(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameCtrl.text.trim().isEmpty ? '百度网盘' : nameCtrl.text.trim(),
                  type: 'baidu',
                  serverUrl: 'https://pan.baidu.com',
                  username: '',
                  password: '',
                  extraToken: tokenCtrl.text.trim(),
                );
                setState(() {
                  _accounts.add(newAcc);
                });
                _saveAccounts();
                Navigator.pop(ctx);
              },
              child: Text(isEn ? 'Save & Mount' : '保存并挂载'),
            ),
          ],
        ),
      ),
    );
  }

  // 5. 关于弹窗（开源无广告，规范说明）
  void _showAboutDialog(BuildContext context) {
    final isEn = _isEn(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.asset('icon_512.png',
                    errorBuilder: (_, __, ___) => const Icon(Icons.cloud, size: 40, color: Color(0xFF0284C7))),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isEn ? 'FineFiles' : '初晴文件管理',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'v1.0.0 (Build 20261020)',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Text(
                isEn
                    ? 'FineFiles is an open-source, lightweight Android file manager and system-level SAF (Storage Access Framework) driver.\n\nIt seamlessly mounts WebDAV, home NAS, Alipan, Baidu Netdisk, and Quark Drive directly into the Android system, allowing third-party apps (such as WeChat and WPS) to transparently access remote cloud files.'
                    : '初晴文件管理（FineFiles）是一款纯净、开源、轻量级的 Android 文件管理器与系统级 SAF（Storage Access Framework）存储驱动。\n\n旨在将 WebDAV、家用 NAS、阿里云盘、百度网盘、夸克网盘 等远端存储无缝挂载为 Android 系统的底层盘符，让微信、WPS、相册等第三方应用能够透明地直接读写云端数据。',
                style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey.shade800),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.code, size: 16, color: Color(0xFF0284C7)),
                const SizedBox(width: 4),
                Text(
                  isEn ? 'Open Source · Apache-2.0 License' : '开源协议 · Apache-2.0 License',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF0284C7)),
                ),
              ],
            ),

          ],
        ),
        actions: [
          Center(
            child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isEn ? 'Close' : '关闭'),
            ),
          ),
        ],
      ),
    );
  }
}

class FileItem {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final Map<String, dynamic>? extra;

  FileItem({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    this.extra,
  });
}

// 选择下载保存目录的弹窗界面
// 通用云端目录选择器（支持 WebDAV 与 百度网盘逐级选择保存目录）
class CloudFolderPickerScreen extends StatefulWidget {
  final StorageAccount account;
  final String currentPath;

  const CloudFolderPickerScreen({
    super.key,
    required this.account,
    required this.currentPath,
  });

  @override
  State<CloudFolderPickerScreen> createState() => _CloudFolderPickerScreenState();
}

class _CloudFolderPickerScreenState extends State<CloudFolderPickerScreen> {
  List<FileItem> _folders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchFolders();
  }

  Future<void> _fetchFolders() async {
    final acc = widget.account;
    if (acc.type == 'alipan') {
      try {
        var token = acc.password.isNotEmpty ? acc.password : acc.extraToken;
        if (token.length == 32) {
          final refreshUrl = 'https://api.aliyundrive.com/token/refresh';
          final rResp = await http.post(
            Uri.parse(refreshUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': token}),
          );
          if (rResp.statusCode == 200) {
            token = jsonDecode(rResp.body)['access_token'];
          }
        }
        var driveId = acc.serverUrl;
        if (driveId == 'resource' || driveId.isEmpty) {
          final userUrl = 'https://user.aliyundrive.com/v2/user/get';
          final uResp = await http.post(
            Uri.parse(userUrl),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: '{}',
          );
          if (uResp.statusCode == 200) {
            final uData = jsonDecode(uResp.body);
            driveId = uData['resource_drive_id'] ?? uData['default_drive_id'] ?? '';
          }
        }
        final parentId = (widget.currentPath == '/' || widget.currentPath.isEmpty) ? 'root' : widget.currentPath;
        final listUrl = 'https://api.aliyundrive.com/adrive/v2/file/list';
        final lResp = await http.post(
          Uri.parse(listUrl),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.aliyundrive.com/',
            'Origin': 'https://www.aliyundrive.com',
          },
          body: jsonEncode({
            'drive_id': driveId,
            'parent_file_id': parentId,
            'limit': 200,
            'order_by': 'name',
            'order_direction': 'ASC',
          }),
        );
        if (lResp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(lResp.bodyBytes));
          if (data['items'] != null) {
            final List<FileItem> res = [];
            for (var item in data['items']) {
              if (item['type'] == 'folder') {
                res.add(FileItem(
                  name: item['name'] ?? '',
                  path: item['file_id'] ?? '',
                  isDir: true,
                  size: 0,
                ));
              }
            }
            setState(() { _folders = res; _loading = false; });
            return;
          }
        }
      } catch (_) {}
    } else if (acc.type == 'quark') {
      try {
        var cookie = acc.extraToken;
        if (!cookie.contains('=')) {
          cookie = '__puus=$cookie';
        }
        final pdirFid = (widget.currentPath == '/' || widget.currentPath.isEmpty) ? '0' : widget.currentPath;
        final sortUrl = 'https://drive.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=$pdirFid&_page=1&_size=200&_sort=file_type:asc,updated_at:desc';
        final qResp = await http.get(
          Uri.parse(sortUrl),
          headers: {
            'Cookie': cookie,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://pan.quark.cn/',
            'Origin': 'https://pan.quark.cn',
            'Accept': 'application/json, text/plain, */*',
          },
        );
        if (qResp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(qResp.bodyBytes));
          if (data['code'] == 0 && data['data'] != null && data['data']['list'] != null) {
            final List<FileItem> res = [];
            for (var item in data['data']['list']) {
              if (item['file_type'] == 0) {
                res.add(FileItem(
                  name: item['file_name'] ?? '',
                  path: item['fid'] ?? '',
                  isDir: true,
                  size: 0,
                ));
              }
            }
            setState(() { _folders = res; _loading = false; });
            return;
          }
        }
      } catch (_) {}
    } else if (acc.type == 'baidu') {
      try {
        final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
        final dirParam = cleanPath.isEmpty ? '/' : '/$cleanPath';
        final encodedDir = Uri.encodeComponent(dirParam);
        final token = acc.password.isNotEmpty ? acc.password : acc.extraToken;

        var cookie = token;
        if (!cookie.contains('=')) {
          cookie = 'BDUSS=$token';
        }
        final webListUrl = 'https://pan.baidu.com/api/list?dir=$encodedDir&num=1000&order=name&desc=0&clienttype=0&showempty=0&web=1&page=1';
        final resp = await http.get(
          Uri.parse(webListUrl),
          headers: {
            'Cookie': cookie,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://pan.baidu.com/disk/main',
            'Origin': 'https://pan.baidu.com',
            'Accept': '*/*',
          },
        );
        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes));
          if (data['errno'] == 0 && data['list'] != null) {
            final List<FileItem> res = [];
            for (var item in data['list']) {
              if ((item['isdir'] ?? 0) == 1) {
                res.add(FileItem(
                  name: item['server_filename'] ?? '',
                  path: item['path'] ?? '',
                  isDir: true,
                  size: 0,
                ));
              }
            }
            res.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
            setState(() { _folders = res; _loading = false; });
            return;
          }
        }
      } catch (_) {}
    } else {
      // WebDAV
      final cleanServer = acc.serverUrl.replaceAll(RegExp(r'/+$'), '');
      final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
      final fullUrl = cleanPath.isEmpty ? '$cleanServer/' : '$cleanServer/$cleanPath/';
      try {
        final headers = <String, String>{'Depth': '1'};
        if (acc.username.isNotEmpty) {
          final token = base64Encode(utf8.encode('${acc.username}:${acc.password}'));
          headers['Authorization'] = 'Basic $token';
        }
        final request = http.Request('PROPFIND', Uri.parse(fullUrl));
        request.headers.addAll(headers);
        final streamed = await request.send();
        final body = await streamed.stream.bytesToString(utf8);
        final document = xml.XmlDocument.parse(body);
        final responses = document.findAllElements('response', namespace: '*');
        final List<FileItem> res = [];

        for (var resp in responses) {
          final hrefElem = resp.findElements('href', namespace: '*').firstOrNull;
          if (hrefElem == null) continue;
          var href = Uri.decodeFull(hrefElem.innerText.trim());
          if (href.startsWith('http://') || href.startsWith('https://')) {
            href = Uri.parse(href).path;
          }
          final serverBasePath = Uri.parse(acc.serverUrl).path.replaceAll(RegExp(r'/+$'), '');
          if (serverBasePath.isNotEmpty && href.startsWith(serverBasePath)) {
            href = href.substring(serverBasePath.length);
          }
          href = '/${href.replaceAll(RegExp(r'^/+|/+$'), '')}';
          final parentClean = '/$cleanPath';
          if (href == parentClean || (parentClean == '/' && href == '/')) continue;

          bool isDir = false;
          final propstats = resp.findAllElements('propstat', namespace: '*');
          for (var p in propstats) {
            if (p.findAllElements('collection', namespace: '*').isNotEmpty) isDir = true;
          }
          if (isDir) {
            final name = href.split('/').lastWhere((e) => e.isNotEmpty, orElse: () => '');
            if (name.isNotEmpty) res.add(FileItem(name: name, path: href, isDir: true, size: 0));
          }
        }
        res.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        setState(() { _folders = res; _loading = false; });
        return;
      } catch (_) {}
    }
    setState(() { _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('保存到 ${widget.account.name}'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.check, color: Color(0xFF0284C7)),
            label: const Text('就存在这', style: TextStyle(color: Color(0xFF0284C7), fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(context, widget.currentPath),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: Colors.white,
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Text('当前目录: ${widget.currentPath}', style: const TextStyle(fontSize: 13, color: Colors.blueGrey), overflow: TextOverflow.ellipsis),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7), foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context, widget.currentPath),
                child: const Text('选择此目录'),
              ),
            ],
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              itemCount: _folders.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, idx) {
                final item = _folders[idx];
                return ListTile(
                  leading: const Icon(Icons.folder, color: Color(0xFF0284C7)),
                  title: Text(item.name),
                  trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                  onTap: () async {
                    final chosen = await Navigator.push<String?>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CloudFolderPickerScreen(
                          account: widget.account,
                          currentPath: item.path,
                        ),
                      ),
                    );
                    if (chosen != null && mounted) {
                      Navigator.pop(context, chosen);
                    }
                  },
                );
              },
            ),
    );
  }
}

class LocalFolderPickerScreen extends StatefulWidget {
  final String currentPath;
  const LocalFolderPickerScreen({super.key, required this.currentPath});

  @override
  State<LocalFolderPickerScreen> createState() => _LocalFolderPickerScreenState();
}

class _LocalFolderPickerScreenState extends State<LocalFolderPickerScreen> {
  List<FileItem> _folders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    try {
      final dir = Directory(widget.currentPath);
      final List<FileItem> res = [];
      if (await dir.exists()) {
        final entities = dir.listSync();
        for (var e in entities) {
          final name = e.path.split('/').last;
          if (name.startsWith('.')) continue;
          if (e is Directory || FileSystemEntity.isDirectorySync(e.path)) {
            res.add(FileItem(name: name, path: e.path, isDir: true, size: 0));
          }
        }
      }
      res.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() { _folders = res; _loading = false; });
    } catch (_) {
      setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择保存位置'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.check, color: Color(0xFF0284C7)),
            label: const Text('就存在这', style: TextStyle(color: Color(0xFF0284C7), fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(context, widget.currentPath),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        color: Colors.white,
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '当前: ${widget.currentPath}',
                  style: const TextStyle(fontSize: 13, color: Colors.blueGrey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(context, widget.currentPath),
                child: const Text('选择此目录'),
              ),
            ],
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              itemCount: _folders.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, idx) {
                final item = _folders[idx];
                return ListTile(
                  leading: const Icon(Icons.folder, color: Color(0xFF0284C7)),
                  title: Text(item.name),
                  trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                  onTap: () async {
                    final chosen = await Navigator.push<String?>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LocalFolderPickerScreen(currentPath: item.path),
                      ),
                    );
                    if (chosen != null && mounted) {
                      Navigator.pop(context, chosen);
                    }
                  },
                );
              },
            ),
    );
  }
}

class LocalFilePickerScreen extends StatefulWidget {
  final String currentPath;
  const LocalFilePickerScreen({super.key, required this.currentPath});

  @override
  State<LocalFilePickerScreen> createState() => _LocalFilePickerScreenState();
}

class _LocalFilePickerScreenState extends State<LocalFilePickerScreen> {
  List<FileItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    try {
      final dir = Directory(widget.currentPath);
      final List<FileItem> res = [];
      if (await dir.exists()) {
        final entities = dir.listSync();
        for (var e in entities) {
          final name = e.path.split('/').last;
          if (name.startsWith('.')) continue;
          final isDir = e is Directory || FileSystemEntity.isDirectorySync(e.path);
          int size = 0;
          if (!isDir) {
            try {
              size = File(e.path).lengthSync();
            } catch (_) {}
          }
          res.add(FileItem(name: name, path: e.path, isDir: isDir, size: size));
        }
      }
      res.sort((a, b) {
        if (a.isDir && !b.isDir) return -1;
        if (!a.isDir && b.isDir) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      setState(() { _items = res; _loading = false; });
    } catch (err) {
      debugPrint('Load files error: $err');
      setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择要上传的本地文件'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, idx) {
                final item = _items[idx];
                return ListTile(
                  leading: Icon(
                    item.isDir ? Icons.folder : Icons.insert_drive_file,
                    color: item.isDir ? const Color(0xFF0284C7) : Colors.blueGrey,
                  ),
                  title: Text(item.name),
                  onTap: () {
                    if (item.isDir) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => LocalFilePickerScreen(currentPath: item.path),
                        ),
                      );
                    } else {
                      Navigator.pop(context, File(item.path));
                    }
                  },
                );
              },
            ),
    );
  }
}

class LocalFileBrowserScreen extends StatefulWidget {
  final String currentPath;
  const LocalFileBrowserScreen({super.key, required this.currentPath});

  @override
  State<LocalFileBrowserScreen> createState() => _LocalFileBrowserScreenState();
}

class _LocalFileBrowserScreenState extends State<LocalFileBrowserScreen> {
  List<FileItem> _items = [];
  bool _loading = true;
  String? _error;
  bool _isSelectionMode = false;
  final Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    _loadLocalFiles();
  }

  Future<void> _loadLocalFiles() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final dir = Directory(widget.currentPath);
      if (!await dir.exists()) {
        setState(() {
          _error = '路径不存在或没有访问权限';
          _loading = false;
        });
        return;
      }

      final entities = await dir.list().toList();
      final List<FileItem> result = [];

      for (var e in entities) {
        final name = e.path.split('/').last;
        if (name.startsWith('.')) continue; // 跳过隐藏文件
        final isDir = e is Directory;
        int size = 0;
        if (!isDir && e is File) {
          try {
            size = await e.length();
          } catch (_) {}
        }
        result.add(FileItem(name: name, path: e.path, isDir: isDir, size: size));
      }

      result.sort((a, b) {
        if (a.isDir && !b.isDir) return -1;
        if (!a.isDir && b.isDir) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      setState(() {
        _items = result;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // 本地批量删除
  Future<void> _deleteLocalSelected() async {
    final count = _selectedPaths.length;
    if (count == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要在手机中彻底删除选中的 $count 项内容吗？删除后不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    for (var p in _selectedPaths) {
      try {
        final f = File(p);
        if (f.existsSync()) {
          f.deleteSync();
        } else {
          final d = Directory(p);
          if (d.existsSync()) d.deleteSync(recursive: true);
        }
      } catch (e) {
        debugPrint('Delete error: $e');
      }
    }

    setState(() {
      _isSelectionMode = false;
      _selectedPaths.clear();
    });
    _loadLocalFiles();
  }

  // 本地批量上传至云盘
  Future<void> _uploadLocalSelected() async {
    final count = _selectedPaths.length;
    if (count == 0) return;

    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('storage_accounts');
    if (jsonStr == null || jsonStr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在首页添加至少一个云盘或 WebDAV 存储')),
      );
      return;
    }
    final List decoded = jsonDecode(jsonStr);
    final accounts = decoded.map((e) => StorageAccount.fromJson(e)).toList();
    if (accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在首页添加至少一个云盘或 WebDAV 存储')),
      );
      return;
    }

    final chosenAcc = await showDialog<StorageAccount?>(
      context: context,
      builder: (dCtx) => SimpleDialog(
        title: const Text('选择目标云盘'),
        children: accounts.map((acc) => SimpleDialogOption(
          onPressed: () => Navigator.pop(dCtx, acc),
          child: Row(
            children: [
              const Icon(Icons.cloud_done, color: Color(0xFF0284C7)),
              const SizedBox(width: 12),
              Text(acc.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        )).toList(),
      ),
    );
    if (chosenAcc == null) return;

    final targetFolder = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) => CloudFolderPickerScreen(
          account: chosenAcc,
          currentPath: '/',
        ),
      ),
    );
    if (targetFolder == null) return;

    double progress = 0.0;
    String currentName = '';
    StateSetter? setProgressState;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (pCtx) => StatefulBuilder(
        builder: (context, setS) {
          setProgressState = setS;
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('正在批量上传'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(currentName.isNotEmpty ? '当前: $currentName' : '准备上传...'),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress > 0 ? progress : null, color: const Color(0xFF0284C7)),
                const SizedBox(height: 8),
                Text(progress > 0 ? '${(progress * 100).toStringAsFixed(1)}%' : '正在传输...'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(pCtx),
                child: const Text('转入后台传输'),
              ),
            ],
          );
        },
      ),
    );

    BackgroundTransferManager.start('正在批量上传文件到 ${chosenAcc.name}...', 0);
    try {
      int idx = 0;
    for (var p in _selectedPaths) {
      final f = File(p);
      if (!f.existsSync()) continue;
      final fileName = p.split('/').last;
      idx++;
      if (setProgressState != null) {
        setProgressState!(() {
          currentName = '$fileName ($idx/$count)';
          progress = 0.0;
        });
      }

      if (chosenAcc.type == 'baidu') {
        var token = chosenAcc.password.isNotEmpty ? chosenAcc.password : chosenAcc.extraToken;
        final cleanPath = targetFolder.replaceAll(RegExp(r'^/+|/+$'), '');
        final targetPath = cleanPath.isEmpty ? '/$fileName' : '/$cleanPath/$fileName';

        await BaiduUploader.upload(
          file: f,
          targetPath: targetPath,
          token: token,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = p;
              });
            }
          },
        );
      } else if (chosenAcc.type == 'alipan') {
        await AlipanUploader.upload(
          file: f,
          targetFolder: targetFolder,
          account: chosenAcc,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = p;
              });
            }
          },
        );
      } else if (chosenAcc.type == 'quark') {
        var cookie = chosenAcc.extraToken;
        if (!cookie.contains('=')) cookie = '__puus=$cookie';
        final pdirFid = (targetFolder == '/' || targetFolder.isEmpty) ? '0' : targetFolder;
        await QuarkUploader.upload(
          file: f,
          pdirFid: pdirFid,
          cookie: cookie,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = p;
              });
            }
          },
        );
      } else {
        final cleanServer = chosenAcc.serverUrl.replaceAll(RegExp(r'/+$'), '');
        final cleanFolder = targetFolder.replaceAll(RegExp(r'^/+|/+$'), '');
        final fullUrl = cleanFolder.isEmpty ? '$cleanServer/$fileName' : '$cleanServer/$cleanFolder/$fileName';
        final headers = <String, String>{};
        if (chosenAcc.username.isNotEmpty) {
          final b64 = base64Encode(utf8.encode('${chosenAcc.username}:${chosenAcc.password}'));
          headers['Authorization'] = 'Basic $b64';
        }

        final fileSize = await f.length();
        final fileStream = f.openRead();
        int sentBytes = 0;
        final progressStream = fileStream.transform<List<int>>(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (List<int> data, EventSink<List<int>> sink) {
              sink.add(data);
              sentBytes += data.length;
              if (fileSize > 0 && setProgressState != null) {
                setProgressState!(() {
                  progress = sentBytes / fileSize;
                });
              }
            },
          ),
        );

        final req = http.StreamedRequest('PUT', Uri.parse(fullUrl));
        req.headers.addAll(headers);
        req.contentLength = fileSize;
        progressStream.listen(
          (data) => req.sink.add(data),
          onDone: () => req.sink.close(),
          onError: (e) => req.sink.addError(e),
        );
        await req.send();
      }
    }
    } finally {
      BackgroundTransferManager.stop();
    }

    if (mounted) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context); // 仅在弹窗未被用户转入后台时关闭
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('批量上传完成！')));
      setState(() {
        _isSelectionMode = false;
        _selectedPaths.clear();
      });
    }
  }

  // 本地新建文件夹
  Future<void> _createLocalFolder() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入文件夹名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
        ],
      ),
    );

    if (ok != true || ctrl.text.trim().isEmpty) return;
    final folderName = ctrl.text.trim();
    try {
      final newDir = Directory('${widget.currentPath}/$folderName');
      if (!await newDir.exists()) {
        await newDir.create(recursive: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件夹创建成功！')));
        }
        _loadLocalFiles();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件夹已存在')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败: $e')));
      }
    }
  }

  // 本地重命名
  Future<void> _renameLocalItem(FileItem item) async {
    final ctrl = TextEditingController(text: item.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );

    if (ok != true || ctrl.text.trim().isEmpty || ctrl.text.trim() == item.name) return;
    final newName = ctrl.text.trim();
    final parentDir = File(item.path).parent.path;
    final newPath = '$parentDir/$newName';

    try {
      if (item.isDir) {
        Directory(item.path).renameSync(newPath);
      } else {
        File(item.path).renameSync(newPath);
      }
      _loadLocalFiles();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重命名失败: $e')));
    }
  }

  void _showLocalFileActionMenu(FileItem item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.insert_drive_file, color: Color(0xFF0284C7), size: 36),
                title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(_formatSize(item.size)),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.open_in_new, color: Color(0xFF0284C7)),
                title: const Text('打开文件'),
                onTap: () {
                  Navigator.pop(ctx);
                  OpenFile.open(item.path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share, color: Color(0xFF0284C7)),
                title: const Text('发送到微信 / 其他应用'),
                subtitle: const Text('调起系统分享面板'),
                onTap: () {
                  Navigator.pop(ctx);
                  Share.shareXFiles([XFile(item.path)], text: item.name);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined, color: Color(0xFF0284C7)),
                title: const Text('上传到云盘 / NAS'),
                subtitle: const Text('选择已添加的云盘进行上传'),
                onTap: () async {
                  Navigator.pop(ctx);
                  _uploadLocalFileToCloud(item);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: Color(0xFF0284C7)),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.pop(ctx);
                  _renameLocalItem(item);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('删除本地文件', style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (dCtx) => AlertDialog(
                      title: const Text('确认删除'),
                      content: Text('确定要在手机中永久删除 ${item.name} 吗？'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('取消')),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                          onPressed: () => Navigator.pop(dCtx, true),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) {
                    try {
                      File(item.path).deleteSync();
                      _loadLocalFiles();
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e')));
                    }
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _uploadLocalFileToCloud(FileItem item) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('storage_accounts');
      if (jsonStr == null || jsonStr.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在首页添加至少一个云盘或 WebDAV 存储')),
        );
        return;
      }
      final List decoded = jsonDecode(jsonStr);
      final accounts = decoded.map((e) => StorageAccount.fromJson(e)).toList();
      if (accounts.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在首页添加至少一个云盘或 WebDAV 存储')),
        );
        return;
      }

      final chosenAcc = await showDialog<StorageAccount?>(
        context: context,
        builder: (dCtx) => SimpleDialog(
          title: const Text('选择目标云盘'),
          children: accounts.map((acc) => SimpleDialogOption(
            onPressed: () => Navigator.pop(dCtx, acc),
            child: Row(
              children: [
                const Icon(Icons.cloud_done, color: Color(0xFF0284C7)),
                const SizedBox(width: 12),
                Text(acc.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          )).toList(),
        ),
      );

      if (chosenAcc == null) return;

      // 让用户选择具体的目标子文件夹
      final targetFolder = await Navigator.push<String?>(
        context,
        MaterialPageRoute(
          builder: (_) => CloudFolderPickerScreen(
            account: chosenAcc,
            currentPath: '/',
          ),
        ),
      );
      if (targetFolder == null) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('正在将 ${item.name} 上传至 ${chosenAcc.name} 的 $targetFolder ...')),
      );

      // 弹窗展示实时上传进度条
      double progress = 0.0;
      StateSetter? setProgressState;
      BuildContext? progressDialogContext;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (pCtx) {
          progressDialogContext = pCtx;
          return StatefulBuilder(
            builder: (context, setS) {
              setProgressState = setS;
              return AlertDialog(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: const Text('正在上传文件'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('上传 ${item.name} 到 ${chosenAcc.name}...'),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: progress > 0 ? progress : null, color: const Color(0xFF0284C7)),
                    const SizedBox(height: 8),
                    Text(progress > 0 ? '${(progress * 100).toStringAsFixed(1)}%' : '正在传输...'),
                  ],
                ),
              );
            },
          );
        },
      );

      final localFile = File(item.path);
      final fileSize = await localFile.length();

      if (chosenAcc.type == 'baidu') {
        var token = chosenAcc.password.isNotEmpty ? chosenAcc.password : chosenAcc.extraToken;
        final cleanPath = targetFolder.replaceAll(RegExp(r'^/+|/+$'), '');
        final targetPath = cleanPath.isEmpty ? '/${item.name}' : '/$cleanPath/${item.name}';

        bool success = false;
        try {
          success = await BaiduUploader.upload(
            file: localFile,
            targetPath: targetPath,
            token: token,
            onProgress: (p) {
              if (setProgressState != null) {
                setProgressState!(() {
                  progress = p;
                });
              }
            },
          );
        } catch (e) {
          debugPrint('Baidu upload exception: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('百度上传异常: $e')),
            );
          }
        }
        if (progressDialogContext != null && Navigator.canPop(progressDialogContext!)) {
          Navigator.pop(progressDialogContext!);
        }

        if (success) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('上传百度网盘成功！')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('上传失败，请检查网络或授权')),
            );
          }
        }
      } else if (chosenAcc.type == 'alipan') {
        bool ok = false;
        try {
          ok = await AlipanUploader.upload(
            file: localFile,
            targetFolder: targetFolder,
            account: chosenAcc,
            onProgress: (p) {
              if (setProgressState != null) {
                setProgressState!(() {
                  progress = p;
                });
              }
            },
          );
        } catch (e) {
          debugPrint('Alipan upload error: $e');
        }
        if (progressDialogContext != null && Navigator.canPop(progressDialogContext!)) {
          Navigator.pop(progressDialogContext!);
        }
        if (mounted) {
          if (ok) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传阿里云盘成功！')));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('阿里云盘上传失败，请检查网络或授权')));
          }
        }
      } else if (chosenAcc.type == 'quark') {
        var cookie = chosenAcc.extraToken;
        if (!cookie.contains('=')) cookie = '__puus=$cookie';
        final pdirFid = (targetFolder == '/' || targetFolder.isEmpty) ? '0' : targetFolder;
        
        bool ok = false;
        try {
          ok = await QuarkUploader.upload(
            file: localFile,
            pdirFid: pdirFid,
            cookie: cookie,
            onProgress: (p) {
              if (setProgressState != null) {
                setProgressState!(() {
                  progress = p;
                });
              }
            },
          );
        } catch (e, stack) {
          debugPrint('Quark upload error: $e\n$stack');
        }

        debugPrint('Quark upload result: $ok');
        if (progressDialogContext != null && Navigator.canPop(progressDialogContext!)) {
          Navigator.pop(progressDialogContext!);
        }
        if (ok) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传夸克网盘成功！')));
        } else {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传夸克网盘失败')));
        }
      } else if (chosenAcc.type == 'webdav') {
        final cleanServer = chosenAcc.serverUrl.replaceAll(RegExp(r'/+$'), '');
        final cleanFolder = targetFolder.replaceAll(RegExp(r'^/+|/+$'), '');
        final fullUrl = cleanFolder.isEmpty
            ? '$cleanServer/${item.name}'
            : '$cleanServer/$cleanFolder/${item.name}';
        final headers = <String, String>{};
        if (chosenAcc.username.isNotEmpty) {
          final token = base64Encode(utf8.encode('${chosenAcc.username}:${chosenAcc.password}'));
          headers['Authorization'] = 'Basic $token';
        }

        final fileStream = localFile.openRead();
        int sentBytes = 0;
        final progressStream = fileStream.transform<List<int>>(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (List<int> data, EventSink<List<int>> sink) {
              sink.add(data);
              sentBytes += data.length;
              if (fileSize > 0 && setProgressState != null) {
                setProgressState!(() {
                  progress = sentBytes / fileSize;
                });
              }
            },
          ),
        );

        final req = http.StreamedRequest('PUT', Uri.parse(fullUrl));
        req.headers.addAll(headers);
        req.contentLength = fileSize;
        progressStream.listen(
          (data) => req.sink.add(data),
          onDone: () => req.sink.close(),
          onError: (e) => req.sink.addError(e),
        );

        final streamed = await req.send();
        if (progressDialogContext != null && Navigator.canPop(progressDialogContext!)) {
          Navigator.pop(progressDialogContext!);
        }

        if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('上传云端成功！')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('上传失败 HTTP ${streamed.statusCode}')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传异常: $e')),
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.currentPath == '/storage/emulated/0'
        ? '手机内部存储'
        : widget.currentPath.split('/').last;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isSelectionMode ? '已选择 ${_selectedPaths.length} 项' : title),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedPaths.clear();
                  });
                },
              )
            : null,
        actions: _isSelectionMode
            ? [
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selectedPaths.length == _items.length) {
                        _selectedPaths.clear();
                      } else {
                        _selectedPaths.addAll(_items.map((e) => e.path));
                      }
                    });
                  },
                  child: Text(
                    _selectedPaths.length == _items.length ? '全不选' : '全选',
                    style: const TextStyle(color: Color(0xFF0284C7), fontWeight: FontWeight.bold),
                  ),
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: '新建文件夹',
                  onPressed: _createLocalFolder,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadLocalFiles,
                ),
              ],
      ),
      bottomNavigationBar: _isSelectionMode
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, -3))
                ],
              ),
              child: SafeArea(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('上传所选'),
                      onPressed: _uploadLocalSelected,
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('删除所选'),
                      onPressed: _deleteLocalSelected,
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text('无法读取本地存储:\n$_error',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red)),
                  ),
                )
              : _items.isEmpty
                  ? const Center(
                      child: Text('文件夹为空', style: TextStyle(color: Colors.grey)))
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 64),
                      itemBuilder: (ctx, idx) {
                        final item = _items[idx];
                        final isSelected = _selectedPaths.contains(item.path);

                        return ListTile(
                          leading: _isSelectionMode
                              ? Checkbox(
                                  value: isSelected,
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        _selectedPaths.add(item.path);
                                      } else {
                                        _selectedPaths.remove(item.path);
                                      }
                                    });
                                  },
                                )
                              : Icon(
                                  item.isDir
                                      ? Icons.folder
                                      : Icons.insert_drive_file_outlined,
                                  color: item.isDir
                                      ? const Color(0xFF0284C7)
                                      : Colors.blueGrey,
                                  size: 32,
                                ),
                          title: Text(
                            item.name,
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: isSelected ? const Color(0xFF0284C7) : null,
                            ),
                          ),
                          subtitle: Text(
                              item.isDir ? '文件夹' : _formatSize(item.size)),
                          onLongPress: () {
                            if (!_isSelectionMode) {
                              setState(() {
                                _isSelectionMode = true;
                                _selectedPaths.add(item.path);
                              });
                            }
                          },
                          onTap: () {
                            if (_isSelectionMode) {
                              setState(() {
                                if (isSelected) {
                                  _selectedPaths.remove(item.path);
                                } else {
                                  _selectedPaths.add(item.path);
                                }
                              });
                            } else {
                              if (item.isDir) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => LocalFileBrowserScreen(
                                      currentPath: item.path,
                                    ),
                                  ),
                                );
                              } else {
                                // 本地文件点击：弹出专属操作菜单 (打开、上传到云端、删除)
                                _showLocalFileActionMenu(item);
                              }
                            }
                          },
                        );
                      },
                    ),
    );
  }
}

class FileBrowserScreen extends StatefulWidget {
  final StorageAccount account;
  final String currentPath;

  const FileBrowserScreen({
    super.key,
    required this.account,
    required this.currentPath,
  });

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  List<FileItem> _items = [];
  bool _loading = true;
  String? _error;
  bool _isSelectionMode = false;
  final Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    _fetchDirectory();
  }

  Map<String, String> _buildHeaders() {
    final headers = <String, String>{};
    if (widget.account.username.isNotEmpty) {
      final token = base64Encode(
          utf8.encode('${widget.account.username}:${widget.account.password}'));
      headers['Authorization'] = 'Basic $token';
    }
    return headers;
  }

  Future<void> _fetchDirectory() async {
    setState(() {
      _loading = true;
      _error = null;
      _isSelectionMode = false;
      _selectedPaths.clear();
    });

    final acc = widget.account;

    if (acc.type == 'webdav') {
      final cleanServer = acc.serverUrl.replaceAll(RegExp(r'/+$'), '');
      final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
      final fullUrl =
          cleanPath.isEmpty ? '$cleanServer/' : '$cleanServer/$cleanPath/';

      try {
        final headers = _buildHeaders();
        headers['Depth'] = '1';

        final request = http.Request('PROPFIND', Uri.parse(fullUrl));
        request.headers.addAll(headers);
        final streamedResponse =
            await request.send().timeout(const Duration(seconds: 10));
        // 显式以 UTF-8 解码响应文本，避免默认 latin-1 导致中文乱码
        final responseBody = await streamedResponse.stream.bytesToString(utf8);
        final statusCode = streamedResponse.statusCode;

        if (statusCode >= 200 && statusCode < 300) {
          final document = xml.XmlDocument.parse(responseBody);
          final responses = document.findAllElements('response', namespace: '*');
          final List<FileItem> result = [];

          for (var resp in responses) {
            final hrefElem =
                resp.findElements('href', namespace: '*').firstOrNull;
            if (hrefElem == null) continue;
            var rawHref = hrefElem.innerText.trim();
            var href = rawHref;
            try {
              href = Uri.decodeFull(rawHref);
            } catch (_) {
              try {
                href = Uri.decodeComponent(rawHref);
              } catch (_) {}
            }

            if (href.startsWith('http://') || href.startsWith('https://')) {
              href = Uri.parse(href).path;
            }
            final serverBasePath =
                Uri.parse(acc.serverUrl).path.replaceAll(RegExp(r'/+$'), '');
            if (serverBasePath.isNotEmpty && href.startsWith(serverBasePath)) {
              href = href.substring(serverBasePath.length);
            }
            href = '/${href.replaceAll(RegExp(r'^/+|/+$'), '')}';

            final parentClean = '/$cleanPath';
            if (href == parentClean || (parentClean == '/' && href == '/')) {
              continue;
            }

            bool isDir = false;
            int size = 0;
            // 广泛兼容各种 WebDAV 实现（支持多 propstat、不分大小写、支持各命名空间）
            final propstats = resp.findAllElements('propstat', namespace: '*');
            for (var propstat in propstats) {
              final resType = propstat.findAllElements('collection', namespace: '*');
              if (resType.isNotEmpty) isDir = true;

              for (var elem in propstat.descendants) {
                if (elem is xml.XmlElement) {
                  final local = elem.name.local.toLowerCase();
                  if (local == 'getcontentlength') {
                    final val = int.tryParse(elem.innerText.trim());
                    if (val != null && val > 0) size = val;
                  }
                }
              }
            }

            final name =
                href.split('/').lastWhere((e) => e.isNotEmpty, orElse: () => '');
            if (name.isNotEmpty) {
              result.add(
                  FileItem(name: name, path: href, isDir: isDir, size: size));
            }
          }

          result.sort((a, b) {
            if (a.isDir && !b.isDir) return -1;
            if (!a.isDir && b.isDir) return 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });

          setState(() {
            _items = result;
            _loading = false;
          });
        } else {
          setState(() {
            _error = 'HTTP $statusCode';
            _loading = false;
          });
        }
      } catch (e) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    } else if (acc.type == 'baidu') {
      try {
        final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
        final dirParam = cleanPath.isEmpty ? '/' : '/$cleanPath';
        final encodedDir = Uri.encodeComponent(dirParam);
        
        var token = acc.password.isNotEmpty ? acc.password : acc.extraToken;
        
        // 模式 A：如果是 Web 端 Cookie 登录 (含有 BDUSS)
        if (token.contains('BDUSS') || (!token.startsWith('121.') && !token.startsWith('122.') && token.length > 50)) {
          var cookie = token;
          if (!cookie.contains('=')) {
            cookie = 'BDUSS=$token';
          }
          final webListUrl = 'https://pan.baidu.com/api/list?dir=$encodedDir&num=1000&order=name&desc=0&clienttype=2&showempty=0&web=1&page=1';
          final resp = await http.get(
            Uri.parse(webListUrl),
            headers: {
              'Cookie': cookie,
              'User-Agent': 'netdisk;7.30.5;PC;PC-Windows;10.0.19041;WindowsBaiduYunGuanJia',
              'Referer': 'https://pan.baidu.com/disk/main',
              'Origin': 'https://pan.baidu.com',
              'Accept': '*/*',
            },
          );
          if (resp.statusCode == 200) {
            final data = jsonDecode(utf8.decode(resp.bodyBytes));
            if (data['errno'] == 0 && data['list'] != null) {
              final List<FileItem> res = [];
              for (var item in data['list']) {
                res.add(FileItem(
                  name: item['server_filename'] ?? '',
                  path: item['path'] ?? '',
                  isDir: (item['isdir'] ?? 0) == 1,
                  size: item['size'] ?? 0,
                  extra: {'fs_id': item['fs_id']},
                ));
              }
              res.sort((a, b) {
                if (a.isDir && !b.isDir) return -1;
                if (!a.isDir && b.isDir) return 1;
                return a.name.toLowerCase().compareTo(b.name.toLowerCase());
              });
              setState(() {
                _items = res;
                _loading = false;
              });
              return;
            } else {
              setState(() {
                _error = '百度网盘返回: ${data['errno']} (请检查登录状态或重新扫码)';
                _loading = false;
              });
              return;
            }
          }
        }

        // 模式 B：如果是 122. 开头的开放平台 Refresh Token，自动换取 121. 的 Access Token
        if (token.startsWith('122.')) {
          final refreshUrl =
              'https://openapi.baidu.com/oauth/2.0/token?grant_type=refresh_token&refresh_token=$token&client_id=hq9yQ9w9kR4YHj1kyYafLygVocobh7Sf&client_secret=YH2VpZcFJHYNnV6vLfHQXDBhcE7ZChyE';
          final rfResp = await http.get(Uri.parse(refreshUrl));
          if (rfResp.statusCode == 200) {
            final rfData = jsonDecode(rfResp.body);
            if (rfData['access_token'] != null) {
              token = rfData['access_token'];
              acc.password = token;
              try {
                final prefs = await SharedPreferences.getInstance();
                final jsonStr = prefs.getString('storage_accounts');
                if (jsonStr != null) {
                  final List dec = jsonDecode(jsonStr);
                  for (var item in dec) {
                    if (item['id'] == acc.id) {
                      item['password'] = token;
                    }
                  }
                  await prefs.setString('storage_accounts', jsonEncode(dec));
                }
              } catch (_) {}
            }
          }
        }

        final fullUrl =
            'https://pan.baidu.com/rest/2.0/xpan/file?method=list&dir=$encodedDir&access_token=$token&folder=0&start=0&limit=1000';

        final resp = await http.get(Uri.parse(fullUrl), headers: {'User-Agent': 'pan.baidu.com'});
        if (resp.statusCode == 200) {
          final data = jsonDecode(utf8.decode(resp.bodyBytes));
          if (data['errno'] == 0 && data['list'] != null) {
            final List<FileItem> res = [];
            for (var item in data['list']) {
              res.add(FileItem(
                name: item['server_filename'] ?? '',
                path: item['path'] ?? '',
                isDir: (item['isdir'] ?? 0) == 1,
                size: item['size'] ?? 0,
                extra: {'fs_id': item['fs_id']},
              ));
            }
            res.sort((a, b) {
              if (a.isDir && !b.isDir) return -1;
              if (!a.isDir && b.isDir) return 1;
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            });
            setState(() {
              _items = res;
              _loading = false;
            });
            return;
          } else {
            setState(() {
              _error = '百度返回错误码: ${data['errno']}';
              _loading = false;
            });
            return;
          }
        }
      } catch (e) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
        return;
      }
    } else if (acc.type == 'alipan') {
      try {
        var token = acc.password;
        // 端侧原生刷新 token (纯官方直连，不走任何第三方服务器)
        final refreshUrl = 'https://api.aliyundrive.com/token/refresh';
        final rResp = await http.post(
          Uri.parse(refreshUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': acc.extraToken}),
        );
        if (rResp.statusCode == 200) {
          final rData = jsonDecode(rResp.body);
          token = rData['access_token'] ?? '';
          acc.password = token;
          if (rData['refresh_token'] != null && (rData['refresh_token'] as String).isNotEmpty) {
            acc.extraToken = rData['refresh_token'];
          }
        }

        // 获取 drive_id (优先使用指定分区)
        var driveId = acc.username;
        if (token.isNotEmpty) {
          final userUrl = 'https://user.aliyundrive.com/v2/user/get';
          final uResp = await http.post(
            Uri.parse(userUrl),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({}),
          );
          if (uResp.statusCode == 200) {
            final uData = jsonDecode(uResp.body);
            if (acc.serverUrl == 'backup') {
              driveId = uData['backup_drive_id'] ?? uData['default_drive_id'] ?? '';
            } else {
              // 资源库：优先 resource_drive_id
              driveId = uData['resource_drive_id'] ?? uData['backup_drive_id'] ?? uData['default_drive_id'] ?? '';
            }
            acc.username = driveId;
          }
        }

        final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
        final parentId = cleanPath.isEmpty ? 'root' : cleanPath;

        // 官方原生端列目录接口 (支持普通用户网页端 refresh_token)
        final listUrl = 'https://api.aliyundrive.com/adrive/v2/file/list';
        final lResp = await http.post(
          Uri.parse(listUrl),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': 'https://www.aliyundrive.com/',
            'Origin': 'https://www.aliyundrive.com',
          },
          body: jsonEncode({
            'drive_id': driveId,
            'parent_file_id': parentId,
            'limit': 200,
            'order_by': 'name',
            'order_direction': 'ASC',
          }),
        );

        if (lResp.statusCode == 200) {
          final lData = jsonDecode(utf8.decode(lResp.bodyBytes));
          final items = lData['items'] as List? ?? [];
          final List<FileItem> res = [];
          for (var item in items) {
            final isDir = item['type'] == 'folder';
            res.add(FileItem(
              name: item['name'] ?? '',
              path: item['file_id'] ?? '',
              isDir: isDir,
              size: item['size'] ?? 0,
            ));
          }
          res.sort((a, b) {
            if (a.isDir && !b.isDir) return -1;
            if (!a.isDir && b.isDir) return 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
          setState(() {
            _items = res;
            _loading = false;
          });
          return;
        } else {
          setState(() {
            _error = '阿里云盘请求失败 (HTTP ${lResp.statusCode})';
            _loading = false;
          });
          return;
        }
      } catch (e) {
        setState(() {
          _error = '阿里云盘异常: $e';
          _loading = false;
        });
        return;
      }
    } else if (acc.type == 'quark') {
      try {
        final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
        final pdirFid = cleanPath.isEmpty ? '0' : cleanPath;

        var cookie = acc.extraToken;
        if (!cookie.contains('=')) {
          cookie = '__puus=$cookie';
        }

        final sortUrl = 'https://drive.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=$pdirFid&_page=1&_size=200&_sort=file_type:asc,updated_at:desc';
        final qResp = await http.get(
          Uri.parse(sortUrl),
          headers: {
            'Cookie': cookie,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': 'https://pan.quark.cn/',
            'Origin': 'https://pan.quark.cn',
            'Accept': 'application/json, text/plain, */*',
          },
        );

        if (qResp.statusCode == 200) {
          final qData = jsonDecode(utf8.decode(qResp.bodyBytes));
          if (qData['status'] == 200 && qData['data'] != null) {
            final list = qData['data']['list'] as List? ?? [];
            final List<FileItem> res = [];
            for (var item in list) {
              final isDir = (item['file_type'] ?? 0) == 0;
              res.add(FileItem(
                name: item['file_name'] ?? '',
                path: item['fid'] ?? '',
                isDir: isDir,
                size: item['size'] ?? 0,
              ));
            }
            res.sort((a, b) {
              if (a.isDir && !b.isDir) return -1;
              if (!a.isDir && b.isDir) return 1;
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            });
            setState(() {
              _items = res;
              _loading = false;
            });
            return;
          } else {
            setState(() {
              _error = '夸克返回错误: ${qData['message'] ?? qData['status']}';
              _loading = false;
            });
            return;
          }
        } else {
          setState(() {
            _error = '夸克 HTTP ${qResp.statusCode}';
            _loading = false;
          });
          return;
        }
      } catch (e) {
        setState(() {
          _error = '夸克网盘异常: $e';
          _loading = false;
        });
        return;
      }
    } else {
      setState(() {
        _items = [];
        _loading = false;
      });
    }
  }

  // 1. 上传文件 (支持 WebDAV 与 百度网盘 OpenAPI，带实时进度条)
  Future<void> _uploadFile() async {
    // 调起内部本地文件选择弹窗，干净无第三方依赖
    final pickedFile = await Navigator.push<File?>(
      context,
      MaterialPageRoute(
        builder: (_) => const LocalFilePickerScreen(currentPath: '/storage/emulated/0'),
      ),
    );
    if (pickedFile == null) return;

    final fileName = pickedFile.path.split('/').last;
    final acc = widget.account;
    final fileSize = await pickedFile.length();

    // 弹窗展示实时上传进度条
    double progress = 0.0;
    StateSetter? setProgressState;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (pCtx) => StatefulBuilder(
        builder: (context, setS) {
          setProgressState = setS;
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('正在上传文件'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('上传 $fileName 到云盘...'),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress > 0 ? progress : null, color: const Color(0xFF0284C7)),
                const SizedBox(height: 8),
                Text(progress > 0 ? '${(progress * 100).toStringAsFixed(1)}%' : '正在握手传输...'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(pCtx),
                child: const Text('转入后台传输'),
              ),
            ],
          );
        },
      ),
    );

    try {
      if (acc.type == 'baidu') {
        var token = acc.password.isNotEmpty ? acc.password : acc.extraToken;
        final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
        final targetPath = cleanPath.isEmpty ? '/$fileName' : '/$cleanPath/$fileName';

        final success = await BaiduUploader.upload(
          file: pickedFile,
          targetPath: targetPath,
          token: token,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = p;
              });
            }
          },
        );
        if (mounted && Navigator.canPop(context)) Navigator.pop(context);

        if (success) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('上传百度网盘成功！')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('上传失败，请检查网络或授权')),
            );
          }
        }
      } else if (acc.type == 'alipan') {
        final success = await AlipanUploader.upload(
          file: pickedFile,
          targetFolder: widget.currentPath,
          account: acc,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = p;
              });
            }
          },
        );
        if (mounted && Navigator.canPop(context)) Navigator.pop(context);
        if (mounted) {
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传阿里云盘成功！')));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传失败，请检查网络或授权')));
          }
        }
      } else if (acc.type == 'quark') {
        var cookie = acc.extraToken;
        if (!cookie.contains('=')) cookie = '__puus=$cookie';
        final pdirFid = (widget.currentPath == '/' || widget.currentPath.isEmpty) ? '0' : widget.currentPath;
        final success = await QuarkUploader.upload(
          file: pickedFile,
          pdirFid: pdirFid,
          cookie: cookie,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = p;
              });
            }
          },
        );
        if (mounted && Navigator.canPop(context)) Navigator.pop(context);
        if (mounted) {
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传夸克网盘成功！')));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传失败，请检查网络或授权')));
          }
        }
      } else {
        final cleanServer = acc.serverUrl.replaceAll(RegExp(r'/+$'), '');
        final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
        final fullUrl = cleanPath.isEmpty
            ? '$cleanServer/$fileName'
            : '$cleanServer/$cleanPath/$fileName';

        final fileStream = pickedFile.openRead();
        int sentBytes = 0;
        final progressStream = fileStream.transform<List<int>>(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (List<int> data, EventSink<List<int>> sink) {
              sink.add(data);
              sentBytes += data.length;
              if (fileSize > 0 && setProgressState != null) {
                setProgressState!(() {
                  progress = sentBytes / fileSize;
                });
              }
            },
          ),
        );

        final req = http.StreamedRequest('PUT', Uri.parse(fullUrl));
        req.headers.addAll(_buildHeaders());
        req.contentLength = fileSize;
        progressStream.listen(
          (data) => req.sink.add(data),
          onDone: () => req.sink.close(),
          onError: (e) => req.sink.addError(e),
        );

        final streamed = await req.send();
        if (mounted && Navigator.canPop(context)) Navigator.pop(context); // 仅在弹窗未被用户转入后台时关闭

        if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('上传成功！')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('上传失败 HTTP ${streamed.statusCode}')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      debugPrint('Upload error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传发生异常: $e')),
        );
      }
    }

    _fetchDirectory();
  }

  // 2. 新建文件夹 (支持 WebDAV MKCOL 与 百度网盘 OpenAPI create)
  Future<void> _createFolder() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入文件夹名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
        ],
      ),
    );

    if (ok != true || ctrl.text.trim().isEmpty) return;
    final folderName = ctrl.text.trim();
    final acc = widget.account;

    if (acc.type == 'baidu') {
      var token = acc.password.isNotEmpty ? acc.password : acc.extraToken;
      var cookie = token;
      if (!cookie.contains('=')) cookie = 'BDUSS=$token';
      final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
      final targetFolderPath = cleanPath.isEmpty ? '/$folderName' : '/$cleanPath/$folderName';
      
      // 客户端模式 clienttype=2 (支持纯 BDUSS Cookie 直接免验证码创建文件夹)
      final createUrl = 'https://pan.baidu.com/api/create?a=commit&clienttype=2';

      try {
        final resp = await http.post(
          Uri.parse(createUrl),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Cookie': cookie,
            'Referer': 'https://pan.baidu.com/disk/main',
            'Origin': 'https://pan.baidu.com',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': '*/*',
          },
          body: {
            'path': targetFolderPath,
            'isdir': '1',
            'size': '',
            'block_list': '[]',
          },
        );
        final dec = jsonDecode(resp.body);
        if (dec['errno'] == 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件夹创建成功！')));
          }
          _fetchDirectory();
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败: ${dec['errno']}')));
          }
        }
      } catch (e) {
        debugPrint('Baidu create folder error: $e');
      }
    } else if (acc.type == 'quark') {
      try {
        var cookie = acc.extraToken;
        if (!cookie.contains('=')) cookie = '__puus=$cookie';
        final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
        final pdirFid = cleanPath.isEmpty ? '0' : cleanPath;
        final cUrl = 'https://drive.quark.cn/1/clouddrive/file?pr=ucpro&fr=pc';
        final resp = await http.post(
          Uri.parse(cUrl),
          headers: {
            'Cookie': cookie,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': 'https://pan.quark.cn/',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'pdir_fid': pdirFid,
            'file_name': folderName,
            'file_type': 0,
          }),
        );
        final dec = jsonDecode(resp.body);
        if (dec['status'] == 200) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件夹创建成功！')));
          }
          _fetchDirectory();
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('夸克创建失败: ${dec['message'] ?? dec['status']}')));
          }
        }
      } catch (e) {
        debugPrint('Quark create folder error: $e');
      }
    } else if (acc.type == 'alipan') {
      try {
        final token = acc.password;
        final driveId = acc.username;
        final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
        final parentId = cleanPath.isEmpty ? 'root' : cleanPath;
        final cUrl = 'https://api.aliyundrive.com/adrive/v2/file/createWithFolders';
        final resp = await http.post(
          Uri.parse(cUrl),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'drive_id': driveId,
            'parent_file_id': parentId,
            'name': folderName,
            'type': 'folder',
            'check_name_mode': 'refuse',
          }),
        );
        if (resp.statusCode == 200 || resp.statusCode == 201) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件夹创建成功！')));
          }
          _fetchDirectory();
        }
      } catch (e) {
        debugPrint('Alipan create folder error: $e');
      }
    } else {
      final cleanServer = acc.serverUrl.replaceAll(RegExp(r'/+$'), '');
      final cleanPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
      final fullUrl = cleanPath.isEmpty
          ? '$cleanServer/$folderName/'
          : '$cleanServer/$cleanPath/$folderName/';

      try {
        final req = http.Request('MKCOL', Uri.parse(fullUrl));
        req.headers.addAll(_buildHeaders());
        await req.send();
        _fetchDirectory();
      } catch (e) {
        debugPrint('MKCOL error: $e');
      }
    }
  }

  // 3. 删除选中的文件或文件夹 (支持 WebDAV DELETE 与 百度网盘 filemanager delete)
  Future<void> _deleteSelected() async {
    final count = _selectedPaths.length;
    if (count == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除选中的 $count 项内容吗？删除后不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    final acc = widget.account;

    if (acc.type == 'baidu') {
      var token = acc.password.isNotEmpty ? acc.password : acc.extraToken;
      var cookie = token;
      if (!cookie.contains('=')) cookie = 'BDUSS=$token';

      // 客户端模式 clienttype=2 (支持纯 BDUSS Cookie 直接免验证码彻底删除)
      final delUrl = 'https://pan.baidu.com/api/filemanager?opera=delete&clienttype=2';
      try {
        final resp = await http.post(
          Uri.parse(delUrl),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Cookie': cookie,
            'Referer': 'https://pan.baidu.com/disk/main',
            'Origin': 'https://pan.baidu.com',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': '*/*',
          },
          body: {
            'filelist': jsonEncode(_selectedPaths.toList()),
          },
        );
        final dec = jsonDecode(resp.body);
        if (dec['errno'] == 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除成功！')));
          }
          _selectedPaths.clear();
          _fetchDirectory();
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('百度删除失败: ${dec['errno']}')));
          }
        }
      } catch (e) {
        debugPrint('Baidu delete error: $e');
      }
    } else if (acc.type == 'quark') {
      try {
        var cookie = acc.extraToken;
        if (!cookie.contains('=')) cookie = '__puus=$cookie';
        final delUrl = 'https://drive.quark.cn/1/clouddrive/file/delete?pr=ucpro&fr=pc';
        final resp = await http.post(
          Uri.parse(delUrl),
          headers: {
            'Cookie': cookie,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': 'https://pan.quark.cn/',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'fids': _selectedPaths.toList()}),
        );
        final dec = jsonDecode(resp.body);
        if (dec['status'] == 200) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除成功！')));
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('夸克删除失败: ${dec['message'] ?? dec['status']}')));
          }
        }
      } catch (e) {
        debugPrint('Quark delete error: $e');
      }
    } else if (acc.type == 'alipan') {
      try {
        final token = acc.password;
        final driveId = acc.username;
        final batchUrl = 'https://api.aliyundrive.com/v3/batch';
        final requests = _selectedPaths.map((p) => {
          'body': {'drive_id': driveId, 'file_id': p},
          'headers': {'Content-Type': 'application/json'},
          'id': p,
          'method': 'POST',
          'url': '/file/delete'
        }).toList();

        final resp = await http.post(
          Uri.parse(batchUrl),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'requests': requests, 'resource': 'file'}),
        );
        if (resp.statusCode == 200) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除成功！')));
          }
        }
      } catch (e) {
        debugPrint('Alipan delete error: $e');
      }
    } else {
      final cleanServer = acc.serverUrl.replaceAll(RegExp(r'/+$'), '');
      for (var p in _selectedPaths) {
        final cleanItemPath = p.replaceAll(RegExp(r'^/+|/+$'), '');
        final fullUrl = '$cleanServer/$cleanItemPath';
        try {
          final req = http.Request('DELETE', Uri.parse(fullUrl));
          req.headers.addAll(_buildHeaders());
          await req.send();
        } catch (e) {
          debugPrint('Delete error: $e');
        }
      }
    }

    _fetchDirectory();
  }

  // 4. 下载选中的文件到用户自选的手机目录
  Future<void> _downloadSelected() async {
    final count = _selectedPaths.length;
    if (count == 0) return;

    // 允许用户直接选择手机内部存储的任何位置（默认从手机根目录 /storage/emulated/0 开始选）
    final selectedDir = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) => const LocalFolderPickerScreen(currentPath: '/storage/emulated/0'),
      ),
    );
    if (selectedDir == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('正在下载选中的 $count 项文件至 $selectedDir ...')),
    );

    final cleanServer = widget.account.serverUrl.replaceAll(RegExp(r'/+$'), '');
    // 启动系统前台免杀保活服务
    BackgroundTransferManager.start('正在下载选中的 $count 项文件...', 0);

    // 弹窗展示下载实时进度
    double progress = 0.0;
    String currentFileName = '';
    StateSetter? setProgressState;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dCtx) => StatefulBuilder(
        builder: (context, setS) {
          setProgressState = setS;
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('正在下载文件'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(currentFileName.isNotEmpty ? '当前: $currentFileName' : '准备下载...'),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress > 0 ? progress : null, color: const Color(0xFF0284C7)),
                const SizedBox(height: 8),
                Text(progress > 0 ? '${(progress * 100).toStringAsFixed(1)}%' : '连接中...'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dCtx),
                child: const Text('转入后台下载'),
              ),
            ],
          );
        },
      ),
    );

    final downloadDir = Directory(selectedDir);
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }

    try {
      int fileIdx = 0;
    final acc = widget.account;

    for (var p in _selectedPaths) {
      final item = _items.firstWhere((e) => e.path == p, orElse: () => FileItem(name: '', path: '', isDir: false, size: 0));
      if (item.isDir) continue;

      fileIdx++;
      if (setProgressState != null) {
        setProgressState!(() {
          currentFileName = '${item.name} ($fileIdx/$count)';
          progress = 0.0;
        });
      }

      if (acc.type == 'baidu') {
        var token = acc.password.isNotEmpty ? acc.password : acc.extraToken;
        var cookie = token;
        if (!cookie.contains('=')) cookie = 'BDUSS=$token';

        String? downloadUrl;
        if (token.startsWith('121.') || !token.contains('=')) {
          final fsId = item.extra?['fs_id'] ?? item.path;
          final metaUrl = 'https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&fsids=[$fsId]&dlink=1&access_token=$token';
          final mResp = await http.get(Uri.parse(metaUrl), headers: {'User-Agent': 'pan.baidu.com'});
          if (mResp.statusCode == 200) {
            final mData = jsonDecode(mResp.body);
            if (mData['errno'] == 0 && (mData['list'] as List).isNotEmpty) {
              final rawDlink = mData['list'][0]['dlink'];
              if (rawDlink != null) {
                downloadUrl = '$rawDlink&access_token=$token';
              }
            }
          }
        }
        if (downloadUrl == null) {
          final cleanPath = p.replaceAll(RegExp(r'^/+|/+$'), '');
          final targetPath = cleanPath.isEmpty ? '/${item.name}' : (cleanPath.startsWith('/') ? cleanPath : '/$cleanPath');
          final locateUrl = 'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload&app_id=250528&ver=4.0&path=${Uri.encodeComponent(targetPath)}';
          final lResp = await http.get(Uri.parse(locateUrl), headers: {
            'Cookie': cookie,
            'User-Agent': 'netdisk;P2SP;2.2.60.26',
          });
          if (lResp.statusCode == 200) {
            final lData = jsonDecode(lResp.body);
            final urls = lData['urls'] as List?;
            downloadUrl = (urls != null && urls.isNotEmpty) ? urls[0]['url'] : null;
          }
          if (downloadUrl == null) {
            final fsId = item.extra?['fs_id'] ?? item.path;
            final metaUrl = 'https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&fsids=[$fsId]&dlink=1';
            final mResp = await http.get(Uri.parse(metaUrl), headers: {
              'Cookie': cookie,
              'User-Agent': 'pan.baidu.com',
            });
            if (mResp.statusCode == 200) {
              final mData = jsonDecode(mResp.body);
              if (mData['errno'] == 0 && (mData['list'] as List).isNotEmpty) {
                downloadUrl = mData['list'][0]['dlink'];
              }
            }
          }
        }
        if (downloadUrl != null) {
          final client = http.Client();
          final req = http.Request('GET', Uri.parse(downloadUrl));
          req.headers['User-Agent'] = 'pan.baidu.com';
          if (cookie.isNotEmpty) req.headers['Cookie'] = cookie;
          final streamed = await client.send(req);
          if (streamed.statusCode == 200) {
            final localFile = File('${downloadDir.path}/${item.name}');
            final sink = localFile.openWrite();
            int received = 0;
            final total = streamed.contentLength ?? item.size;
            await streamed.stream.listen((chunk) {
              sink.add(chunk);
              received += chunk.length;
              if (total > 0 && setProgressState != null) {
                setProgressState!(() {
                  progress = received / total;
                });
              }
            }).asFuture();
            await sink.close();
          }
        }
      } else if (acc.type == 'alipan') {
        try {
          var token = acc.password.isNotEmpty ? acc.password : acc.extraToken;
          if (token.length == 32) {
            final rResp = await http.post(
              Uri.parse('https://api.aliyundrive.com/token/refresh'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'refresh_token': token}),
            );
            if (rResp.statusCode == 200) token = jsonDecode(rResp.body)['access_token'];
          }
          var driveId = acc.serverUrl;
          if (driveId == 'resource' || driveId.isEmpty) {
            final uResp = await http.post(
              Uri.parse('https://user.aliyundrive.com/v2/user/get'),
              headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
              body: '{}',
            );
            if (uResp.statusCode == 200) {
              final uData = jsonDecode(uResp.body);
              driveId = uData['resource_drive_id'] ?? uData['default_drive_id'] ?? '';
            }
          }
          final fileId = p;
          final dUrl = 'https://bj29.api.aliyunpds.com/v2/file/get_download_url';
          final dResp = await http.post(
            Uri.parse(dUrl),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json', 'Referer': 'https://www.aliyundrive.com/'},
            body: jsonEncode({'drive_id': driveId, 'file_id': fileId, 'expire_sec': 14400}),
          );
          if (dResp.statusCode == 200) {
            final dData = jsonDecode(dResp.body);
            final downloadUrl = dData['url'] ?? dData['cdn_url'] ?? '';
            if (downloadUrl.isNotEmpty) {
              final client = http.Client();
              final req = http.Request('GET', Uri.parse(downloadUrl));
              req.headers['User-Agent'] = 'Mozilla/5.0';
              req.headers['Referer'] = 'https://www.aliyundrive.com/';
              final streamed = await client.send(req);
              if (streamed.statusCode == 200) {
                final localFile = File('${downloadDir.path}/${item.name}');
                final sink = localFile.openWrite();
                int received = 0;
                final total = streamed.contentLength ?? item.size;
                await streamed.stream.listen((chunk) {
                  sink.add(chunk);
                  received += chunk.length;
                  if (total > 0 && setProgressState != null) {
                    setProgressState!(() {
                      progress = received / total;
                    });
                  }
                }).asFuture();
                await sink.close();
              }
            }
          }
        } catch (e) {
          debugPrint('Alipan download error: $e');
        }
      } else if (acc.type == 'quark') {
        try {
          var cookie = acc.extraToken;
          if (!cookie.contains('=')) cookie = '__puus=$cookie';
          final dUrl = 'https://drive.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc';
          const quarkUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
          final dResp = await http.post(
            Uri.parse(dUrl),
            headers: {
              'Cookie': cookie,
              'User-Agent': quarkUa,
              'Referer': 'https://pan.quark.cn/',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'fids': [p]}),
          );
          if (dResp.statusCode == 200) {
            final dData = jsonDecode(dResp.body);
            if (dData['data'] != null && (dData['data'] as List).isNotEmpty) {
              final downloadUrl = dData['data'][0]['download_url'] ?? '';
              if (downloadUrl.isNotEmpty) {
                final localFile = File('${downloadDir.path}/${item.name}');
                final sink = localFile.openWrite();
                final total = item.size > 0 ? item.size : (dData['data'][0]['size'] as num? ?? 1).toInt();
                int received = 0;
                final chunkSize = 10 * 1024 * 1024; // AList 10MB 分片下载策略
                for (int start = 0; start < total; start += chunkSize) {
                  int end = start + chunkSize - 1;
                  if (end >= total) end = total - 1;
                  final partReq = http.Request('GET', Uri.parse(downloadUrl));
                  partReq.headers['User-Agent'] = quarkUa;
                  partReq.headers['Cookie'] = cookie;
                  partReq.headers['Referer'] = 'https://pan.quark.cn/';
                  partReq.headers['Range'] = 'bytes=$start-$end';
                  final streamed = await http.Client().send(partReq);
                  await streamed.stream.listen((chunk) {
                    sink.add(chunk);
                    received += chunk.length;
                    if (total > 0 && setProgressState != null) {
                      setProgressState!(() {
                        progress = received / total;
                      });
                    }
                  }).asFuture();
                }
                await sink.close();
              }
            }
          }
        } catch (e) {
          debugPrint('Quark download error: $e');
        }
      } else {
        final cleanItemPath = p.replaceAll(RegExp(r'^/+|/+$'), '');
        final fullUrl = '$cleanServer/$cleanItemPath';
        try {
          final client = http.Client();
          final req = http.Request('GET', Uri.parse(fullUrl));
          req.headers.addAll(_buildHeaders());
          final streamed = await client.send(req);
          if (streamed.statusCode == 200) {
            final localFile = File('${downloadDir.path}/${item.name}');
            final sink = localFile.openWrite();
            int received = 0;
            final total = streamed.contentLength ?? item.size;
            await streamed.stream.listen((chunk) {
              sink.add(chunk);
              received += chunk.length;
              if (total > 0 && setProgressState != null) {
                setProgressState!(() {
                  progress = received / total;
                });
              }
            }).asFuture();
            await sink.close();
          }
        } catch (e) {
          debugPrint('Download error: $e');
        }
      }
    }
    } finally {
      BackgroundTransferManager.stop();
    }

    if (mounted) {
      if (mounted && Navigator.canPop(context)) Navigator.pop(context); // 仅在弹窗未被用户转入后台时关闭
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载已完成，保存在: $selectedDir')),
      );
      setState(() {
        _isSelectionMode = false;
        _selectedPaths.clear();
      });
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // 弹出单个文件的操作菜单 (点击触发: 打开、下载、重命名、删除)
  void _showFileActionMenu(FileItem item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  item.isDir ? Icons.folder : Icons.insert_drive_file,
                  color: const Color(0xFF0284C7),
                  size: 36,
                ),
                title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(item.isDir ? '文件夹' : _formatSize(item.size)),
              ),
              const Divider(),
              if (!item.isDir) ...[
                ListTile(
                  leading: const Icon(Icons.open_in_new, color: Color(0xFF0284C7)),
                  title: const Text('打开文件'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openRemoteFile(item);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share, color: Color(0xFF0284C7)),
                  title: const Text('发送到微信 / 其他应用'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _shareRemoteFile(item);
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.download, color: Color(0xFF0284C7)),
                title: const Text('下载到指定目录'),
                onTap: () {
                  Navigator.pop(ctx);
                  _selectedPaths.clear();
                  _selectedPaths.add(item.path);
                  _downloadSelected();
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined, color: Color(0xFF0284C7)),
                title: const Text('转存到其他网盘 / 存储'),
                onTap: () {
                  Navigator.pop(ctx);
                  _transferRemoteFileToOtherStorage(item);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline, color: Colors.blueGrey),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.pop(ctx);
                  _renameItem(item);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('删除', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _selectedPaths.clear();
                  _selectedPaths.add(item.path);
                  _deleteSelected();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 将当前网盘/NAS文件直接转存到另一个网盘 (例如 NAS -> 百度网盘)
  Future<void> _transferRemoteFileToOtherStorage(FileItem item) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('storage_accounts');
      if (jsonStr == null || jsonStr.isEmpty) return;
      final List dec = jsonDecode(jsonStr);
      final accounts = dec.map((e) => StorageAccount.fromJson(e)).where((e) => e.id != widget.account.id).toList();
      if (accounts.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先添加另一个目标云盘或 NAS')));
        return;
      }

      final chosenAcc = await showDialog<StorageAccount?>(
        context: context,
        builder: (dCtx) => SimpleDialog(
          title: const Text('选择转存目标'),
          children: accounts.map((acc) => SimpleDialogOption(
            onPressed: () => Navigator.pop(dCtx, acc),
            child: Row(
              children: [
                const Icon(Icons.cloud_done, color: Color(0xFF0284C7)),
                const SizedBox(width: 12),
                Text(acc.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          )).toList(),
        ),
      );
      if (chosenAcc == null) return;

      final targetFolder = await Navigator.push<String?>(
        context,
        MaterialPageRoute(
          builder: (_) => CloudFolderPickerScreen(
            account: chosenAcc,
            currentPath: '/',
          ),
        ),
      );
      if (targetFolder == null) return;

      // 弹窗显示传输进度
      double progress = 0.0;
      StateSetter? setProgressState;
      BuildContext? progressDialogContext;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (pCtx) {
          progressDialogContext = pCtx;
          return StatefulBuilder(
            builder: (context, setS) {
              setProgressState = setS;
              return AlertDialog(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: const Text('正在跨云传输'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('正在将 ${item.name} 传输至 ${chosenAcc.name}...'),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: progress > 0 ? progress : null, color: const Color(0xFF0284C7)),
                    const SizedBox(height: 8),
                    Text(progress > 0 ? '${(progress * 100).toStringAsFixed(1)}%' : '准备中...'),
                    const SizedBox(height: 6),
                    Text(
                      progress < 0.5 ? '阶段 1/2: 正在从源网盘拉取文件...' : '阶段 2/2: 正在写入目标存储...',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );

      BackgroundTransferManager.start('正在转存 ${item.name} 到 ${chosenAcc.name}...', 0);

      // 1. 从当前源下载到临时文件
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/${item.name}');

      if (widget.account.type == 'baidu') {
        var token = widget.account.password.isNotEmpty ? widget.account.password : widget.account.extraToken;
        var cookie = token;
        if (!cookie.contains('=')) cookie = 'BDUSS=$token';

        String? downloadUrl;
        if (token.startsWith('121.') || !token.contains('=')) {
          // 官方 OpenAPI AccessToken 下载机制
          final fsId = item.extra?['fs_id'] ?? item.path;
          final metaUrl = 'https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&fsids=[$fsId]&dlink=1&access_token=$token';
          final mResp = await http.get(Uri.parse(metaUrl), headers: {'User-Agent': 'pan.baidu.com'});
          if (mResp.statusCode == 200) {
            final mData = jsonDecode(mResp.body);
            if (mData['errno'] == 0 && (mData['list'] as List).isNotEmpty) {
              final rawDlink = mData['list'][0]['dlink'];
              if (rawDlink != null) {
                downloadUrl = '$rawDlink&access_token=$token';
              }
            }
          }
        }
        if (downloadUrl == null) {
          final cleanPath = item.path.replaceAll(RegExp(r'^/+|/+$'), '');
          final targetPath = cleanPath.isEmpty ? '/${item.name}' : (cleanPath.startsWith('/') ? cleanPath : '/$cleanPath');
          final locateUrl = 'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload&app_id=250528&ver=4.0&path=${Uri.encodeComponent(targetPath)}';
          final lResp = await http.get(Uri.parse(locateUrl), headers: {
            'Cookie': cookie,
            'User-Agent': 'netdisk;P2SP;2.2.60.26',
          });
          if (lResp.statusCode == 200) {
            final lData = jsonDecode(lResp.body);
            final urls = lData['urls'] as List?;
            downloadUrl = (urls != null && urls.isNotEmpty) ? urls[0]['url'] : null;
          }
          if (downloadUrl == null) {
            final fsId = item.extra?['fs_id'] ?? item.path;
            final metaUrl = 'https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&fsids=[$fsId]&dlink=1';
            final mResp = await http.get(Uri.parse(metaUrl), headers: {
              'Cookie': cookie,
              'User-Agent': 'pan.baidu.com',
            });
            if (mResp.statusCode == 200) {
              final mData = jsonDecode(mResp.body);
              if (mData['errno'] == 0 && (mData['list'] as List).isNotEmpty) {
                downloadUrl = mData['list'][0]['dlink'];
              }
            }
          }
        }
        if (downloadUrl != null) {
          final client = http.Client();
          final req = http.Request('GET', Uri.parse(downloadUrl));
          req.headers['User-Agent'] = 'pan.baidu.com';
          if (cookie.isNotEmpty) req.headers['Cookie'] = cookie;
          final streamed = await client.send(req);
          int received = 0;
          final total = streamed.contentLength ?? (item.size > 0 ? item.size : 1);
          final sink = tempFile.openWrite();
          await streamed.stream.listen((chunk) {
            sink.add(chunk);
            received += chunk.length;
            if (setProgressState != null) {
              setProgressState!(() {
                progress = (received / total) * 0.5;
              });
            }
          }).asFuture();
          await sink.close();
        }
      } else if (widget.account.type == 'alipan') {
        var token = widget.account.password.isNotEmpty ? widget.account.password : widget.account.extraToken;
        if (token.length == 32) {
          final rResp = await http.post(
            Uri.parse('https://api.aliyundrive.com/token/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': token}),
          );
          if (rResp.statusCode == 200) token = jsonDecode(rResp.body)['access_token'];
        }
        var driveId = widget.account.serverUrl;
        if (driveId == 'resource' || driveId.isEmpty) {
          final uResp = await http.post(
            Uri.parse('https://user.aliyundrive.com/v2/user/get'),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: '{}',
          );
          if (uResp.statusCode == 200) {
            final uData = jsonDecode(uResp.body);
            driveId = uData['resource_drive_id'] ?? uData['default_drive_id'] ?? '';
          }
        }
        final dResp = await http.post(
          Uri.parse('https://bj29.api.aliyunpds.com/v2/file/get_download_url'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json', 'Referer': 'https://www.aliyundrive.com/'},
          body: jsonEncode({'drive_id': driveId, 'file_id': item.path, 'expire_sec': 14400}),
        );
        if (dResp.statusCode == 200) {
          final downloadUrl = jsonDecode(dResp.body)['url'] ?? jsonDecode(dResp.body)['cdn_url'] ?? '';
          final client = http.Client();
          final req = http.Request('GET', Uri.parse(downloadUrl));
          req.headers['User-Agent'] = 'Mozilla/5.0';
          req.headers['Referer'] = 'https://www.aliyundrive.com/';
          final streamed = await client.send(req);
          int received = 0;
          final total = streamed.contentLength ?? (item.size > 0 ? item.size : 1);
          final sink = tempFile.openWrite();
          await streamed.stream.listen((chunk) {
            sink.add(chunk);
            received += chunk.length;
            if (setProgressState != null) {
              setProgressState!(() {
                progress = (received / total) * 0.5;
              });
            }
          }).asFuture();
          await sink.close();
        }
      } else if (widget.account.type == 'quark') {
        var cookie = widget.account.extraToken;
        if (!cookie.contains('=')) cookie = '__puus=$cookie';
        final dResp = await http.post(
          Uri.parse('https://drive.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc'),
          headers: {
            'Cookie': cookie,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch',
            'Referer': 'https://pan.quark.cn/',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'fids': [item.path]}),
        );
        if (dResp.statusCode == 200) {
          final dData = jsonDecode(dResp.body);
          final downloadUrl = dData['data']?[0]?['download_url'] ?? '';
          if (downloadUrl.isNotEmpty) {
            final total = item.size > 0 ? item.size : (dData['data']?[0]?['size'] as num? ?? 1).toInt();
            int received = 0;
            final chunkSize = 10 * 1024 * 1024;
            const quarkUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
            final sink = tempFile.openWrite();
            for (int start = 0; start < total; start += chunkSize) {
              int end = start + chunkSize - 1;
              if (end >= total) end = total - 1;
              final partReq = http.Request('GET', Uri.parse(downloadUrl));
              partReq.headers['User-Agent'] = quarkUa;
              partReq.headers['Cookie'] = cookie;
              partReq.headers['Referer'] = 'https://pan.quark.cn/';
              partReq.headers['Range'] = 'bytes=$start-$end';
              final streamed = await http.Client().send(partReq);
              await streamed.stream.listen((chunk) {
                sink.add(chunk);
                received += chunk.length;
                if (setProgressState != null) {
                  setProgressState!(() {
                    progress = (received / total) * 0.5;
                  });
                }
              }).asFuture();
            }
            await sink.close();
          }
        }
      } else {
        final cleanSrcServer = widget.account.serverUrl.replaceAll(RegExp(r'/+$'), '');
        final cleanSrcItemPath = item.path.replaceAll(RegExp(r'^/+|/+$'), '');
        final srcFullUrl = '$cleanSrcServer/$cleanSrcItemPath';

        final client = http.Client();
        final getReq = http.Request('GET', Uri.parse(srcFullUrl));
        getReq.headers.addAll(_buildHeaders());
        final streamedGet = await client.send(getReq);

        int received = 0;
        final total = streamedGet.contentLength ?? (item.size > 0 ? item.size : 1);
        final sink = tempFile.openWrite();
        await streamedGet.stream.listen((chunk) {
          sink.add(chunk);
          received += chunk.length;
          if (setProgressState != null) {
            setProgressState!(() {
              progress = (received / total) * 0.5; // 下载占 50%
            });
          }
        }).asFuture();
        await sink.close();
      }

      // 2. 上传到目标云盘 (占后半段 50% ~ 100%)
      if (chosenAcc.type == 'baidu') {
        var token = chosenAcc.password.isNotEmpty ? chosenAcc.password : chosenAcc.extraToken;
        final cleanPath = targetFolder.replaceAll(RegExp(r'^/+|/+$'), '');
        final targetPath = cleanPath.isEmpty ? '/${item.name}' : '/$cleanPath/${item.name}';

        await BaiduUploader.upload(
          file: tempFile,
          targetPath: targetPath,
          token: token,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = 0.5 + p * 0.5; // 上传平滑过渡 50% -> 100%
              });
            }
          },
        );
      } else if (chosenAcc.type == 'quark') {
        var cookie = chosenAcc.extraToken;
        if (!cookie.contains('=')) cookie = '__puus=$cookie';
        final pdirFid = (targetFolder == '/' || targetFolder.isEmpty) ? '0' : targetFolder;
        
        await QuarkUploader.upload(
          file: tempFile,
          pdirFid: pdirFid,
          cookie: cookie,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = 0.5 + p * 0.5;
              });
            }
          },
        );
      } else if (chosenAcc.type == 'alipan') {
        await AlipanUploader.upload(
          file: tempFile,
          targetFolder: targetFolder,
          account: chosenAcc,
          onProgress: (p) {
            if (setProgressState != null) {
              setProgressState!(() {
                progress = 0.5 + p * 0.5;
              });
            }
          },
        );
      } else if (chosenAcc.type == 'webdav') {
        final cleanServer = chosenAcc.serverUrl.replaceAll(RegExp(r'/+$'), '');
        final cleanDest = targetFolder.replaceAll(RegExp(r'^/+|/+$'), '');
        final fullDestUrl = cleanDest.isEmpty
            ? '$cleanServer/${item.name}'
            : '$cleanServer/$cleanDest/${item.name}';

        final client = http.Client();
        var authStr = '${chosenAcc.username}:${chosenAcc.password}';
        var basicAuth = 'Basic ${base64Encode(utf8.encode(authStr))}';
        final fileSize = await tempFile.length();
        final putReq = ProgressStreamRequest(
          'PUT',
          Uri.parse(fullDestUrl),
          tempFile.openRead(),
          fileSize,
          onProgress: (sent, _) {
            if (fileSize > 0 && setProgressState != null) {
              setProgressState!(() {
                progress = 0.5 + (sent / fileSize) * 0.5;
              });
            }
          },
        );
        putReq.headers['Authorization'] = basicAuth;
        putReq.headers['Content-Type'] = 'application/octet-stream';
        await client.send(putReq);
      } else {
        final cleanDstServer = chosenAcc.serverUrl.replaceAll(RegExp(r'/+$'), '');
        final cleanFolder = targetFolder.replaceAll(RegExp(r'^/+|/+$'), '');
        final dstUrl = cleanFolder.isEmpty ? '$cleanDstServer/${item.name}' : '$cleanDstServer/$cleanFolder/${item.name}';
        final headers = <String, String>{};
        if (chosenAcc.username.isNotEmpty) {
          final b64 = base64Encode(utf8.encode('${chosenAcc.username}:${chosenAcc.password}'));
          headers['Authorization'] = 'Basic $b64';
        }

        final uploadStream = tempFile.openRead();
        int upSent = 0;
        final fileSize = await tempFile.length();
        final progressStream = uploadStream.transform<List<int>>(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (List<int> data, EventSink<List<int>> sink) {
              sink.add(data);
              upSent += data.length;
              if (fileSize > 0 && setProgressState != null) {
                setProgressState!(() {
                  progress = 0.5 + (upSent / fileSize) * 0.5;
                });
              }
            },
          ),
        );

        final req = http.StreamedRequest('PUT', Uri.parse(dstUrl));
        req.headers.addAll(headers);
        req.contentLength = fileSize;
        progressStream.listen(
          (data) => req.sink.add(data),
          onDone: () => req.sink.close(),
          onError: (e) => req.sink.addError(e),
        );
        await req.send();
      }

      if (mounted) {
        if (setProgressState != null) {
          setProgressState!(() {
            progress = 1.0;
          });
        }
        await Future.delayed(const Duration(milliseconds: 300));
        if (progressDialogContext != null && Navigator.canPop(progressDialogContext!)) {
          Navigator.pop(progressDialogContext!);
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('成功转存 ${item.name} 到 ${chosenAcc.name}！')));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('转存失败: $e')));
      }
    } finally {
      BackgroundTransferManager.stop();
    }
  }

  // 临时下载并调用系统底层 Intent 分享到微信或其他应用
  Future<void> _shareRemoteFile(FileItem item) async {
    // 弹窗展示下载缓冲进度
    double progress = 0.0;
    StateSetter? setProgressState;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (pCtx) => StatefulBuilder(
        builder: (context, setS) {
          setProgressState = setS;
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('正在准备发送'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('正在缓冲 ${item.name}...'),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress > 0 ? progress : null, color: const Color(0xFF0284C7)),
                const SizedBox(height: 8),
                Text(progress > 0 ? '${(progress * 100).toStringAsFixed(1)}%' : '连接中...'),
              ],
            ),
          );
        },
      ),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final shareFolder = Directory('${tempDir.path}/share');
      if (!await shareFolder.exists()) await shareFolder.create(recursive: true);
      final tempFile = File('${shareFolder.path}/${item.name}');

      final cleanServer = widget.account.serverUrl.replaceAll(RegExp(r'/+$'), '');
      final cleanItemPath = item.path.replaceAll(RegExp(r'^/+|/+$'), '');
      final fullUrl = '$cleanServer/$cleanItemPath';

      final client = http.Client();
      final req = http.Request('GET', Uri.parse(fullUrl));
      req.headers.addAll(_buildHeaders());
      final streamed = await client.send(req);

      int received = 0;
      final total = streamed.contentLength ?? item.size;
      final sink = tempFile.openWrite();
      await streamed.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && setProgressState != null) {
          setProgressState!(() {
            progress = received / total;
          });
        }
      }).asFuture();
      await sink.close();

      if (mounted) Navigator.pop(context); // 关闭缓冲框

      // 调起系统原生分享器，直接选择微信发送
      await Share.shareXFiles([XFile(tempFile.path)], text: item.name);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      debugPrint('Share error: $e');
    }
  }

  // 临时下载并调用系统关联应用直接打开
  Future<void> _openRemoteFile(FileItem item) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('正在缓冲 ${item.name}...')),
    );
    try {
      final cleanServer = widget.account.serverUrl.replaceAll(RegExp(r'/+$'), '');
      final cleanItemPath = item.path.replaceAll(RegExp(r'^/+|/+$'), '');
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/${item.name}');

      if (widget.account.type == 'baidu') {
        var token = widget.account.password.isNotEmpty ? widget.account.password : widget.account.extraToken;
        if (token.startsWith('122.')) {
          try {
            final refreshUrl = 'https://openapi.baidu.com/oauth/2.0/token?grant_type=refresh_token&refresh_token=$token&client_id=[REDACTED]&client_secret=[REDACTED]';
            final rResp = await http.get(Uri.parse(refreshUrl));
            final rDec = jsonDecode(rResp.body);
            if (rDec['access_token'] != null) {
              token = rDec['access_token'];
            }
          } catch (_) {}
        }
        final dlinkUrl = 'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=download&access_token=$token&path=${Uri.encodeComponent(item.path)}';
        final client = http.Client();
        final req = http.Request('GET', Uri.parse(dlinkUrl));
        req.headers['User-Agent'] = 'netdisk';
        final streamed = await client.send(req);
        if (streamed.statusCode == 200 || streamed.statusCode == 302) {
          final sink = tempFile.openWrite();
          await streamed.stream.pipe(sink);
          await OpenFile.open(tempFile.path);
        }
      } else {
        final fullUrl = '$cleanServer/$cleanItemPath';
        final resp = await http.get(Uri.parse(fullUrl), headers: _buildHeaders());
        if (resp.statusCode == 200) {
          await tempFile.writeAsBytes(resp.bodyBytes);
          await OpenFile.open(tempFile.path);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('加载失败 HTTP ${resp.statusCode}')),
          );
        }
      }
    } catch (e) {
      debugPrint('Open error: $e');
    }
  }

  // 重命名
  Future<void> _renameItem(FileItem item) async {
    final ctrl = TextEditingController(text: item.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty || ctrl.text.trim() == item.name) return;

    final newName = ctrl.text.trim();
    final acc = widget.account;

    if (acc.type == 'baidu') {
      var token = acc.password.isNotEmpty ? acc.password : acc.extraToken;
      var cookie = token;
      if (!cookie.contains('=')) cookie = 'BDUSS=$token';
      
      // 客户端模式 clienttype=2 重命名
      final renameUrl = 'https://pan.baidu.com/api/filemanager?opera=rename&clienttype=2';
      try {
        final resp = await http.post(
          Uri.parse(renameUrl),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Cookie': cookie,
            'Referer': 'https://pan.baidu.com/disk/main',
            'Origin': 'https://pan.baidu.com',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': '*/*',
          },
          body: {
            'filelist': jsonEncode([
              {'path': item.path, 'newname': newName}
            ]),
          },
        );
        final dec = jsonDecode(resp.body);
        if (dec['errno'] == 0) {
          _fetchDirectory();
        }
      } catch (e) {
        debugPrint('Baidu rename error: $e');
      }
    } else if (acc.type == 'quark') {
      try {
        var cookie = acc.extraToken;
        if (!cookie.contains('=')) cookie = '__puus=$cookie';
        final renUrl = 'https://drive.quark.cn/1/clouddrive/file/rename?pr=ucpro&fr=pc';
        final resp = await http.post(
          Uri.parse(renUrl),
          headers: {
            'Cookie': cookie,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': 'https://pan.quark.cn/',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'fid': item.path, 'file_name': newName}),
        );
        final dec = jsonDecode(resp.body);
        if (dec['status'] == 200) {
          _fetchDirectory();
        }
      } catch (e) {
        debugPrint('Quark rename error: $e');
      }
    } else if (acc.type == 'alipan') {
      try {
        final token = acc.password;
        final driveId = acc.username;
        final renUrl = 'https://api.aliyundrive.com/v3/file/update';
        final resp = await http.post(
          Uri.parse(renUrl),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'drive_id': driveId,
            'file_id': item.path,
            'name': newName,
            'check_name_mode': 'refuse',
          }),
        );
        if (resp.statusCode == 200) {
          _fetchDirectory();
        }
      } catch (e) {
        debugPrint('Alipan rename error: $e');
      }
    } else {
      final cleanServer = widget.account.serverUrl.replaceAll(RegExp(r'/+$'), '');
      final cleanOldPath = item.path.replaceAll(RegExp(r'^/+|/+$'), '');
      final parentPath = widget.currentPath.replaceAll(RegExp(r'^/+|/+$'), '');
      final cleanNewPath = parentPath.isEmpty ? newName : '$parentPath/$newName';

      final fullOldUrl = '$cleanServer/$cleanOldPath';
      final fullNewUrl = '$cleanServer/$cleanNewPath';

      try {
        final req = http.Request('MOVE', Uri.parse(fullOldUrl));
        req.headers.addAll(_buildHeaders());
        req.headers['Destination'] = fullNewUrl;
        final res = await req.send();
        if (res.statusCode >= 200 && res.statusCode < 300) {
          _fetchDirectory();
        }
      } catch (e) {
        debugPrint('Rename error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.currentPath == '/'
        ? widget.account.name
        : widget.currentPath.split('/').last;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isSelectionMode ? '已选择 ${_selectedPaths.length} 项' : title),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedPaths.clear();
                  });
                },
              )
            : null,
        actions: _isSelectionMode
            ? [
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selectedPaths.length == _items.length) {
                        _selectedPaths.clear();
                      } else {
                        _selectedPaths.addAll(_items.map((e) => e.path));
                      }
                    });
                  },
                  child: Text(
                    _selectedPaths.length == _items.length ? '全不选' : '全选',
                    style: const TextStyle(color: Color(0xFF0284C7), fontWeight: FontWeight.bold),
                  ),
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: '新建文件夹',
                  onPressed: _createFolder,
                ),
                IconButton(
                  icon: const Icon(Icons.upload_file_outlined),
                  tooltip: '上传文件',
                  onPressed: _uploadFile,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _fetchDirectory,
                ),
              ],
      ),
      bottomNavigationBar: _isSelectionMode
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, -3))
                ],
              ),
              child: SafeArea(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _downloadSelected,
                      icon: const Icon(Icons.download),
                      label: const Text('下载'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _deleteSelected,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('删除'),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 48, color: Colors.redAccent),
                        const SizedBox(height: 12),
                        Text('无法连接到服务器:\n$_error',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red)),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _fetchDirectory,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : _items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.folder_open_outlined, size: 64, color: Colors.grey.shade400),
                          const SizedBox(height: 12),
                          const Text('当前文件夹为空', style: TextStyle(color: Colors.grey)),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0284C7),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _uploadFile,
                            icon: const Icon(Icons.upload_file),
                            label: const Text('立即上传文件'),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 64),
                      itemBuilder: (ctx, idx) {
                        final item = _items[idx];
                        final isSelected = _selectedPaths.contains(item.path);

                        return ListTile(
                          leading: _isSelectionMode
                              ? Checkbox(
                                  value: isSelected,
                                  activeColor: const Color(0xFF0284C7),
                                  onChanged: (val) {
                                    setState(() {
                                      if (val == true) {
                                        _selectedPaths.add(item.path);
                                      } else {
                                        _selectedPaths.remove(item.path);
                                      }
                                    });
                                  },
                                )
                              : Icon(
                                  item.isDir
                                      ? Icons.folder
                                      : Icons.insert_drive_file_outlined,
                                  color: item.isDir
                                      ? const Color(0xFF0284C7)
                                      : Colors.blueGrey,
                                  size: 32,
                                ),
                          title: Text(
                            item.name,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                              item.isDir ? '文件夹' : _formatSize(item.size)),
                          selected: isSelected,
                          selectedTileColor: const Color(0xFFE0F2FE).withOpacity(0.4),
                          onLongPress: () {
                            setState(() {
                              _isSelectionMode = true;
                              _selectedPaths.add(item.path);
                            });
                          },
                          onTap: () {
                            if (_isSelectionMode) {
                              setState(() {
                                if (isSelected) {
                                  _selectedPaths.remove(item.path);
                                } else {
                                  _selectedPaths.add(item.path);
                                }
                              });
                            } else {
                              if (item.isDir) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => FileBrowserScreen(
                                      account: widget.account,
                                      currentPath: item.path,
                                    ),
                                  ),
                                );
                              } else {
                                // 普通点击文件：弹出下载、打开、重命名、删除操作面板
                                _showFileActionMenu(item);
                              }
                            }
                          },
                        );
                      },
                    ),
    );
  }
}


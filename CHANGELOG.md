# Changelog (更新日志)

All notable changes to the **FineFiles (初晴文件)** project will be documented in this file.

---

## [v1.1.0] - 2026-11-20

### 🛡️ 安全与漏洞修复 (Security & Vulnerability Fixes)
- **彻底消除全局 SSL 中间人安全漏洞 (MITM)**：
  - 移除了原先在原生 `DocumentsProvider` 初始化时对全进程 JVM `HttpsURLConnection.setDefaultSSLSocketFactory` 的强行覆盖；
  - 改为使用按需注入的专用 WebDAV `SSLSocketFactory`，在无缝兼容家庭局域网 NAS、Lucky/Nginx 泛域名私有自签证书的同时，全面恢复系统底层与三方网盘 API 的标准 SSL/TLS 证书校验链。
- **WebDAV XML 解析防 XXE 注入防护**：
  - 在 `DocumentBuilderFactory` 解析 WebDAV `PROPFIND` 返回值时全面启用了 `disallow-doctype-decl`，并禁止加载外部通用实体和参数实体，抵御潜在恶意服务器发起的 XXE / SSRF 攻击。
- **存储访问框架 (SAF) 权限状态一致性与防数据丢失保护**：
  - 将 SAF 原生文档 Flags 统一声明为只读浏览规范，杜绝第三方 App（如微信、WPS）因误认支持远程写入而调用未实现方法导致的异常崩溃；
  - 在 `openDocument` 写入模式下明确拦截并返回友好安全警告，避免远程文件在未上传回写时静默丢数据。

### ⚡ 稳定性与性能优化 (Performance & Stability)
- **大文件流式哈希计算 (解决 OOM 内存爆炸)**：
  - 重写了夸克网盘分片上传哈希计算器，彻底废弃一次性读取全文件字节的 `readAsBytes()` 机制；
  - 引入 `_DigestAccumulator` 流式逐块累积计算 MD5 与 SHA-1，即使计算 10GB 以上超大文件也仅消耗微量流缓冲区内存，彻底根除 OOM 闪退隐患。
- **全局 HTTP 连接池与客户端泄露修复**：
  - 修复了夸克网盘分片上传、百度网盘下载、阿里云盘下载流中反复实例化 `http.Client()` 导致的底层 Socket 资源泄露问题；
  - 统一重构为分块复用 Client，并严格在 `try / finally` 块中执行连接释放与连接池清理。
- **下载流与本地文件写入安全性**：
  - 所有网络文件下载管道在 `sink.close()` 之前严格追加 `await sink.flush()`，确保网络数据完整落盘；
  - 修复了跨目录同名文件在本地缓存中相互覆盖的缺陷，采用 `accId + MD5(path)[0..8] + filename` 保证本地缓存文件唯一性，并增加了 300MB LRU 缓存自动清理机制。

### ✨ 新特性与体验改进 (Features & UI Improvements)
- **全网盘远程文件系统级直开与直接分享**：
  - 抽象并实现了统一的 `_fetchRemoteFileToTemp` 跨协议调度器；
  - 现在不仅支持 WebDAV，**阿里云盘、夸克网盘、百度网盘**的所有远程文件均支持点击直接调用系统应用打开或调起原生分享菜单发送至微信。
- **静态资源声明修复**：
  - 在 `pubspec.yaml` 中完整注册 `icon_512.png` 资产，修复关于关于页面图标加载回退的缺陷。
- **版本标识与构建信息更新**：
  - 同步升级底层版本规范至 `1.1.0+2`。

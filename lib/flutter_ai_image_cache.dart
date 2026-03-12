import 'dart:async';
import "package:crypto/crypto.dart";
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// ============================================================
// Flutter AI Image Cache - 高性能图片缓存库
/// ============================================================

/// 全局配置
class FlutterImageCacheConfig {
  /// 是否启用原生缓存兼容
  static bool enableNativeCompat = true;
  
  /// 是否启用纹理零拷贝（需要原生配合）
  static bool enableTextureShare = false;
  
  /// 内存缓存大小 (bytes) 默认100MB
  static int maxMemoryCacheSize = 100 * 1024 * 1024;
  
  /// 磁盘缓存大小 (bytes) 默认500MB
  static int maxDiskCacheSize = 500 * 1024 * 1024;
  
  /// 默认超时时间
  static Duration timeout = const Duration(seconds: 30);
  
  /// 最大并发下载数
  static int maxConcurrentDownloads = 6;
}

/// 图片结果
class ImageResult {
  final Uint8List? data;
  final TextureData? textureData;
  final ImageSource source;
  
  const ImageResult({
    this.data,
    this.textureData,
    required this.source,
  });
  
  bool get isTexture => textureData != null;
  Uint8List? get bytes => data;
}

/// 图片来源
enum ImageSource { memory, disk, native, texture, network }

/// 纹理数据
class TextureData {
  final int textureId;
  final int width;
  final int height;
  final String url;
  
  const TextureData({
    required this.textureId,
    required this.width,
    required this.height,
    required this.url,
  });
}

// ============================================================
// LRU 内存缓存
// ============================================================
class MemoryCache<K, V> {
  final int maxSize;
  final Map<K, V> _cache = Map<K, V>();
  int _currentSize = 0;
  final int Function(V)? _sizeCalculator;
  final void Function(K key, V value)? _onEvict;
  
  MemoryCache({
    required this.maxSize,
    int Function(V)? sizeCalculator,
    void Function(K key, V value)? onEvict,
  }) : _sizeCalculator = sizeCalculator, _onEvict = onEvict;
  
  V? get(K key) {
    if (!_cache.containsKey(key)) return null;
    // 移动到末尾 (MRU)
    final value = _cache.remove(key);
    if (value != null) {
      _cache[key] = value;
    }
    return value;
  }
  
  void set(K key, V value) {
    final size = _sizeCalculator?.call(value) ?? 1;
    
    // 如果已存在，先移除
    if (_cache.containsKey(key)) {
      _currentSize -= _sizeCalculator?.call(_cache[key]!) ?? 1;
      _cache.remove(key);
    }
    
    // 超过容量时淘汰最老的
    while (_currentSize + size > maxSize && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final oldestValue = _cache.remove(oldestKey);
      if (oldestValue != null) {
        _currentSize -= _sizeCalculator?.call(oldestValue) ?? 1;
        _onEvict?.call(oldestKey, oldestValue);
      }
    }
    
    _cache[key] = value;
    _currentSize += size;
  }
  
  V? remove(K key) {
    final value = _cache.remove(key);
    if (value != null) {
      _currentSize -= _sizeCalculator?.call(value) ?? 1;
    }
    return value;
  }
  
  void clear() {
    _cache.clear();
    _currentSize = 0;
  }
  
  bool containsKey(K key) => _cache.containsKey(key);
  int get length => _cache.length;
  int get size => _currentSize;
}

// ============================================================
// 磁盘缓存
// ============================================================
class DiskCache {
  final Directory _cacheDir;
  final int maxSizeBytes;
  final Duration expiration;
  final Map<String, _CacheEntry> _index = {};
  
  DiskCache._({
    required Directory cacheDir,
    this.maxSizeBytes = 500 * 1024 * 1024,
    this.expiration = const Duration(days: 7),
  }) : _cacheDir = cacheDir;
  
  static Future<DiskCache> create({
    required String cachePath,
    int maxSizeBytes = 500 * 1024 * 1024,
    Duration expiration = const Duration(days: 7),
  }) async {
    final dir = Directory(cachePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return DiskCache._(
      cacheDir: dir,
      maxSizeBytes: maxSizeBytes,
      expiration: expiration,
    );
  }
  
  String _hashKey(String url) {
    return md5.convert(utf8.encode(url)).toString();
  }
  
  String _filePath(String key) => '${_cacheDir.path}/$key';
  
  Future<Uint8List?> get(String url) async {
    final key = _hashKey(url);
    final file = File(_filePath(key));
    if (!await file.exists()) return null;
    
    final entry = _index[key];
    if (entry != null && DateTime.now().isAfter(entry.expiresAt)) {
      await file.delete();
      _index.remove(key);
      return null;
    }
    
    return await file.readAsBytes();
  }
  
  Future<void> set(String url, Uint8List data) async {
    final key = _hashKey(url);
    final file = File(_filePath(key));
    await file.writeAsBytes(data);
    
    _index[key] = _CacheEntry(
      key: key,
      size: data.length,
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(expiration),
    );
    
    await _trimToSize();
  }
  
  Future<void> _trimToSize() async {
    int currentSize = _index.values.fold(0, (sum, e) => sum + e.size);
    while (currentSize > maxSizeBytes && _index.isNotEmpty) {
      final oldestKey = _index.keys.first;
      final entry = _index.remove(oldestKey);
      if (entry != null) {
        await File(_filePath(oldestKey)).delete();
        currentSize -= entry.size;
      }
    }
  }
  
  Future<void> clear() async {
    for (final key in _index.keys) {
      await File(_filePath(key)).delete();
    }
    _index.clear();
  }
}

class _CacheEntry {
  final String key;
  final int size;
  final DateTime createdAt;
  final DateTime expiresAt;
  
  _CacheEntry({
    required this.key,
    required this.size,
    required this.createdAt,
    required this.expiresAt,
  });
}

// ============================================================
// 图片加载器
// ============================================================
class ImageLoader {
  Future<Uint8List?> download(String url, {Duration? timeout}) async {
    try {
      final response = await http.get(
        Uri.parse(url),
      ).timeout(timeout ?? FlutterImageCacheConfig.timeout);
      
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}

// ============================================================
// 主缓存类
// ============================================================
class FlutterImageCache {
  static final FlutterImageCache _instance = FlutterImageCache._internal();
  factory FlutterImageCache() => _instance;
  FlutterImageCache._internal();
  
  late MemoryCache<String, Uint8List> _memoryCache;
  DiskCache? _diskCache;
  final _imageLoader = ImageLoader();
  bool _initialized = false;
  
  Future<void> init({
    int? maxMemorySize,
    int? maxDiskSize,
    bool enableNativeCompat = true,
    bool enableTextureShare = false,
  }) async {
    if (_initialized) return;
    
    _memoryCache = MemoryCache<String, Uint8List>(
      maxSize: maxMemorySize ?? FlutterImageCacheConfig.maxMemoryCacheSize,
      sizeCalculator: (data) => data.length,
    );
    
    if (enableNativeCompat) {
      final cacheDir = await _getCacheDirectory();
      _diskCache = await DiskCache.create(
        cachePath: cacheDir.path,
        maxSizeBytes: maxDiskSize ?? FlutterImageCacheConfig.maxDiskCacheSize,
      );
    }
    
    _initialized = true;
  }
  
  Future<Directory> _getCacheDirectory() async {
    if (Platform.isAndroid) {
      return Directory('/data/data/com.example/flutter_cache');
    } else if (Platform.isIOS) {
      return Directory('/Users/user/Library/Caches/flutter_cache');
    }
    return Directory('/tmp/flutter_cache');
  }
  
  /// 获取图片 - 智能多级缓存
  Future<ImageResult?> getImage(String url) async {
    if (!_initialized) await init();
    
    // 1. 内存缓存
    final memData = _memoryCache.get(url);
    if (memData != null) {
      return ImageResult(data: memData, source: ImageSource.memory);
    }
    
    // 2. 磁盘缓存
    if (_diskCache != null) {
      final diskData = await _diskCache!.get(url);
      if (diskData != null) {
        _memoryCache.set(url, diskData);
        return ImageResult(data: diskData, source: ImageSource.disk);
      }
    }
    
    // 3. 网络下载
    final networkData = await _imageLoader.download(url);
    if (networkData != null) {
      _memoryCache.set(url, networkData);
      await _diskCache?.set(url, networkData);
      return ImageResult(data: networkData, source: ImageSource.network);
    }
    
    return null;
  }
  
  /// 预加载图片
  Future<void> preload(List<String> urls) async {
    for (final url in urls) {
      getImage(url); // 忽略结果，只为缓存
    }
  }
  
  /// 清除所有缓存
  Future<void> clearAll() async {
    _memoryCache.clear();
    await _diskCache?.clear();
  }
  
  /// 清除内存缓存
  void clearMemory() => _memoryCache.clear();
}

// ============================================================
// Widget
// ============================================================
class SmartCachedImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final bool fadeIn;
  final Duration fadeDuration;
  
  const SmartCachedImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.fadeIn = true,
    this.fadeDuration = const Duration(milliseconds: 300),
  });

  @override
  State<SmartCachedImage> createState() => _SmartCachedImageState();
}

class _SmartCachedImageState extends State<SmartCachedImage> {
  Uint8List? _imageData;
  bool _loading = true;
  bool _error = false;
  
  @override
  void initState() {
    super.initState();
    _loadImage();
  }
  
  @override
  void didUpdateWidget(SmartCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _loadImage();
    }
  }
  
  Future<void> _loadImage() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    
    try {
      final cache = FlutterImageCache();
      final result = await cache.getImage(widget.url);
      
      if (mounted) {
        setState(() {
          _imageData = result?.bytes;
          _loading = false;
          _error = result == null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    Widget child;
    
    if (_loading) {
      child = widget.placeholder ?? _defaultPlaceholder();
    } else if (_error) {
      child = widget.errorWidget ?? _defaultError();
    } else if (_imageData != null) {
      child = Image.memory(
        _imageData!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        frameBuilder: widget.fadeIn 
          ? (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: widget.fadeDuration,
                child: child,
              );
            }
          : null,
      );
    } else {
      child = widget.errorWidget ?? _defaultError();
    }
    
    if (widget.borderRadius != null) {
      child = ClipRRect(
        borderRadius: widget.borderRadius!,
        child: child,
      );
    }
    
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: child,
    );
  }
  
  Widget _defaultPlaceholder() => Container(
    color: Colors.grey[200],
    child: const Center(
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
  
  Widget _defaultError() => Container(
    color: Colors.grey[200],
    child: const Center(
      child: Icon(Icons.broken_image, color: Colors.grey),
    ),
  );
}
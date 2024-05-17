import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart';
import 'package:http/retry.dart';
import 'package:p_limit/p_limit.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart'
    hide TileLayer, Logger;
import 'package:vector_tile_renderer/vector_tile_renderer.dart'
    as vector_tile_renderer;

import 'cache.dart';
import 'style.dart';

class TileProviderConfig {
  final String uri;
  final String? apiKey;
  final Directory? cacheDir;

  TileProviderConfig({
    required this.uri,
    required this.apiKey,
    this.cacheDir,
  });

  static TileProviderConfig fromJson(Map<String, dynamic> json) =>
      TileProviderConfig(
        uri: json['uri'],
        apiKey: json['api_key'],
        cacheDir:
            json.containsKey('cache_dir') ? Directory(json['cache_dir']) : null,
      );

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'api_key': apiKey,
        'cache_dir': cacheDir?.path,
      };

  Future<TilesetProvider> buildTilesetProvider() async {
    final style = await fetchAndDecodeMapboxStyle(uri, apiKey: apiKey);

    final dir = cacheDir;
    final cache = dir != null && !kIsWeb
        ? FileSystemByteStorage(
            ttl: const Duration(days: 14),
            maxSizeInBytes: 1024 * 1024 * 100,
            path: dir,
          )
        : null;
    return TilesetProvider(style, cache);
  }
}

class TilesetProvider {
  static const maxConcurrency = 8;

  final Style style;

  final _limit = PLimit<Tileset>(maxConcurrency);
  final _cache = _TilesetCache();
  final ByteStorage? _fsCache;

  TilesetProvider(this.style, ByteStorage? fsCache) : _fsCache = fsCache;

  // TODO: Naively the style should be part of the cache key.
  Future<Tileset> provide(TileCoordinates c, Future<void> cancelLoading) {
    return _cache[c] ??= _limit(() => _build(c, cancelLoading));
  }

  Future<Tileset> _build(TileCoordinates c, Future<void> cancelLoading) async {
    bool canceled = false;
    cancelLoading.whenComplete(() => canceled = true);

    try {
      final sourceId = style.sources.isEmpty ? 'composite' : style.sources[0];
      final tileBytes = await _getTileBytes(sourceId, c);
      if (canceled) throw Error.tileLoadingCancelled;

      final vectorTile = VectorTileReader().read(tileBytes);
      if (canceled) throw Error.tileLoadingCancelled;

      var tileData = TileFactory(
        style.theme,
        const vector_tile_renderer.Logger.noop(),
      ).createTileData(vectorTile);
      if (canceled) throw Error.tileLoadingCancelled;

      final tile = tileData.toTile();
      if (canceled) throw Error.tileLoadingCancelled;

      // NOTE: Preprocess is intended to remove expensive stuff.
      final tileset = TilesetPreprocessor(style.theme)
          .preprocess(Tileset({sourceId: tile}), zoom: c.z.toDouble());

      return tileset;
    } catch (err) {
      _cache.remove(c);
      rethrow;
    }
  }

  Future<Uint8List> _getTileBytes(String sourceId, TileCoordinates c) async {
    String filename() => 'cached_tile_${sourceId}_${c.x}_${c.y}_${c.z}.blob';
    final cacheBytes = await _fsCache?.read(filename());
    if (cacheBytes != null) {
      return cacheBytes;
    }

    final tileProvider = style.tileProviderBySource[sourceId];
    if (tileProvider == null) {
      throw Exception(
          'Missing TileProvider for: $sourceId (${style.tileProviderBySource.keys})');
    }
    final downloadedBytes = await tileProvider.provide(c);

    if (_fsCache != null) {
      Future(() async {
        await _fsCache.write(filename(), downloadedBytes);
      }).ignore();
    }

    return downloadedBytes;
  }
}

class _TilesetCache {
  static const maxSize = 120;

  final _cache = HashMap<TileCoordinates, (DateTime, Future<Tileset>)>();
  Future<void>? _cleaning;

  Future<Tileset>? operator [](TileCoordinates c) {
    final entry = _cache[c];
    if (entry == null) {
      return null;
    }
    _cache[c] = (DateTime.now(), entry.$2);
    return entry.$2;
  }

  void operator []=(TileCoordinates c, Future<Tileset> fetch) {
    _cache[c] = (DateTime.now(), fetch);

    // Enforce size.
    if (_cache.length > maxSize && _cleaning == null) {
      _cleaning = Future(() {
        // Sort by timestamp;
        final entries =
            _cache.entries.map((entry) => (entry.value.$1, entry.key)).toList();
        entries.sort((a, b) => a.$1.compareTo(b.$1));

        for (final entry in entries.take((entries.length * 0.2).floor())) {
          _cache.remove(entry.$2);
        }

        _cleaning = null;
      });
    }
  }

  void remove(TileCoordinates c) => _cache.remove(c);
}

enum Error {
  tileLoadingCancelled,
}

extension Check on TileCoordinates {
  void check({int? zoomMin, int? zoomMax}) {
    if (z > (zoomMax ?? 20) || z < (zoomMin ?? 0)) {
      throw Exception('Invalid zoom ($zoomMin, $zoomMax): $this');
    }
    if (x < 0 || y < 0) {
      throw Exception('Negative X/Y: $this');
    }
    final max = math.pow(2, z).toInt();
    if (x > max || y > max) {
      throw Exception('X/Y too large for zoom: $this');
    }
  }
}

enum TileType { vector, raster }

abstract class EncodedTileProvider {
  /// provides a tile as a `pbf` or `mvt` format
  Future<Uint8List> provide(TileCoordinates tile);

  int get maxZoom;
  int get minZoom;

  TileType get type;
  String? get template => null;

  static EncodedTileProvider network({
    required TileType type,
    required String urlTemplate,
    Map<String, String>? httpHeaders,
    required int maxZoom,
    required int minZoom,
  }) =>
      _EncodedTileNetworkProvider(
        type: type,
        urlTemplate: urlTemplate,
        httpHeaders: httpHeaders,
        maxZoom: maxZoom,
        minZoom: minZoom,
      );
}

class _EncodedTileNetworkProvider extends EncodedTileProvider {
  @override
  final TileType type;
  final String urlTemplate;
  final Map<String, String>? httpHeaders;

  @override
  final int maxZoom;

  @override
  final int minZoom;

  @override
  String? get template => urlTemplate;

  /// [urlTemplate], e.g. `'https://tiles.stadiamaps.com/data/openmaptiles/{z}/{x}/{y}.pbf?api_key=<prefilled>'`
  _EncodedTileNetworkProvider({
    required this.urlTemplate,
    required this.type,
    this.httpHeaders,
    required this.maxZoom,
    required this.minZoom,
  });

  @override
  Future<Uint8List> provide(TileCoordinates tile) async {
    tile.check(zoomMin: minZoom, zoomMax: maxZoom);

    final uri = _getUri(tile);
    final client = RetryClient(Client());

    try {
      final response = await client.get(uri, headers: httpHeaders);
      if (response.statusCode != 200) {
        final logSafeUri = uri.toString().split(RegExp(r'\?')).first;
        throw Exception(
            'Cannot retrieve tile: HTTP ${response.statusCode}: $logSafeUri ${response.body}');
      }

      return response.bodyBytes;
    } finally {
      client.close();
    }
  }

  static final regex = RegExp(r'\{(x|y|z)\}');
  Uri _getUri(TileCoordinates identity) => Uri.parse(
        urlTemplate.replaceAllMapped(regex, (match) {
          return switch (match.group(1)) {
            'x' => identity.x.toString(),
            'y' => identity.y.toString(),
            'z' => identity.z.toString(),
            _ => throw Exception('Failed to fill x/y/z for: $urlTemplate'),
          };
        }),
      );
}

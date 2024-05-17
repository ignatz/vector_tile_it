// Style specs:
//
// * Mapbox Style spec: https://docs.mapbox.com/style-spec/reference/
// * TileJSON: https://github.com/mapbox/tilejson-spec/tree/master/3.0.0
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:logging/logging.dart';
import 'package:http/http.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' hide Logger;

import 'tileset_provider.dart';

class SpriteStyle {
  final ui.Image spriteAtlas;
  final SpriteIndex index;

  const SpriteStyle({
    required this.spriteAtlas,
    required this.index,
  });

  @override
  String toString() => 'SpriteStyle(${index.spriteByName.keys})';
}

class Style {
  final String name;
  final Theme theme;

  /// Vector tile providers by source, where sources are defined by the theme above.
  final Map<String, EncodedTileProvider> tileProviderBySource;

  // Sprite index and spite atlas provider.
  final SpriteStyle? sprites;

  Style({
    required this.name,
    required this.theme,
    required this.tileProviderBySource,
    this.sprites,
  });

  List<String>? _sources;
  List<String> get sources {
    return _sources ??= () {
      final s = theme.layers.map((l) => l.tileSource).toSet();
      return s.whereType<String>().toList();
    }();
  }

  @override
  String toString() {
    final providers = tileProviderBySource.entries.map((entry) => (entry.key, entry.value.template)).toList();
    return 'Style(name=$name, tileProviders=$providers, sprites=$sprites)';
  }
}

class SpriteUri {
  final Uri base;
  final String suffix;

  SpriteUri({required this.base, required this.suffix});

  Uri get json => base.replace(path: '${base.path}$suffix.json');
  Uri get image => base.replace(path: '${base.path}$suffix.png');

  @override
  String toString() => 'SpriteUri($json, $image)';
}

Uri _decodeMapboxUri(String uri, String? apiKey) {
  final parsed = Uri.parse(_replaceKey(uri, apiKey));
  if (parsed.scheme != 'mapbox') {
    return parsed;
  }

  final segments = parsed.pathSegments;
  assert(segments.length >= 2, '$uri ${segments.toList()}');
  final username = segments[0];
  final style = segments[1];
  return Uri.https(
    'api.mapbox.com',
    '/styles/v1/$username/$style',
    parsed.queryParameters,
  );
}

Uri _decodeMapboxSourceUri(
  final String sourceUri,
  String? apiKey,
) {
  final parsed = Uri.parse(_replaceKey(sourceUri, apiKey));
  if (parsed.scheme != 'mapbox') {
    return parsed;
  }

  final style = parsed.host;
  return Uri.https('api.mapbox.com', '/v4/$style.json', {
    'secure': '',
    if (apiKey != null) 'access_token': apiKey,
  });
}

List<SpriteUri> _decodeMapboxSpriteUri(
  String spriteUri,
  String? apiKey,
) {
  const suffixes = ['@2x', ''];
  final parsed = Uri.parse(spriteUri);
  if (parsed.scheme == 'mapbox') {
    final Map<String, String> parameters = {
      'secure': '',
      if (apiKey != null) 'access_token': apiKey,
    };

    // https://docs.mapbox.com/style-spec/reference/sprite/
    return suffixes
        .map((s) => SpriteUri(
              suffix: s,
              base: Uri.https('api.mapbox.com',
                  'styles/v1${parsed.path}/sprite', parameters),
            ))
        .toList();
  }

  if (parsed.host.endsWith('maptiler.com')) {
    final Map<String, String> parameters = {
      if (apiKey != null) 'key': apiKey,
    };

    return suffixes
        .map((s) => SpriteUri(
              suffix: s,
              base: parsed.replace(queryParameters: parameters),
            ))
        .toList();
  }

  return suffixes.map((s) => SpriteUri(suffix: s, base: parsed)).toList();
}

Future<Style> fetchAndDecodeMapboxStyle(
  String uri, {
  String? apiKey,
}) async {
  final json = await _getHttpString(_decodeMapboxUri(uri, apiKey));

  return await MapboxStyle.toStyle(
    uri.toString(),
    apiKey,
    jsonDecode(json),
  );
}

class MapboxStyle {
  final int version;
  final String name;
  final String id;
  final String? owner;

  final Map<String, dynamic>? metadata;
  final Map<String, Map<String, dynamic>> sources;
  final List<dynamic> layers;

  final List<num> center;
  final num? zoom;
  final String sprite;
  final String glyphs;

  final DateTime? created;
  final DateTime? modified;

  MapboxStyle._({
    required this.version,
    required this.name,
    required this.id,
    required this.owner,
    required this.metadata,
    required this.sources,
    required this.layers,
    required this.center,
    required this.zoom,
    required this.sprite,
    required this.glyphs,
    required this.created,
    required this.modified,
  });

  static MapboxStyle fromJson(Map<String, dynamic> json) {
    final String? created = json['created'];
    final String? modified = json['modified'];
    return MapboxStyle._(
      version: json['version'],
      name: json['name'],
      id: json['id'],
      owner: json['owner'],
      metadata: json['metadata'] as Map<String, dynamic>?,
      sources: (json['sources'] as Map).cast<String, Map<String, dynamic>>(),
      layers: json['layers'] as List,
      center: (json['center'] as List?)?.cast<num>() ?? [],
      zoom: json['zoom'],
      sprite: json['sprite'],
      glyphs: json['glyphs'],
      created: created != null ? DateTime.parse(created) : null,
      modified: modified != null ? DateTime.parse(modified) : null,
    );
  }

  static Future<Style> toStyle(
    final String styleUri,
    String? apiKey,
    Map<String, dynamic> styleJson,
  ) async {
    final style = MapboxStyle.fromJson(styleJson);
    final providers = await _readProviderByName(
      style.sources,
      apiKey,
      styleUri,
    );

    // A sprite is a single image that contains all the icon and pattern images included in a style.
    SpriteStyle? sprites;
    if (style.sprite.trim().isNotEmpty) {
      final spriteUris = _decodeMapboxSpriteUri(style.sprite, apiKey);

      for (final uris in spriteUris) {
        try {
          final indexJson = await _getHttpString(uris.json);
          final codec =
              await ui.instantiateImageCodec(await _getHttp(uris.image));
          final atlas = (await codec.getNextFrame()).image;

          _logger.finest('Sprite atlas\' wxh=${atlas.width}x${atlas.height}px');

          sprites = SpriteStyle(
            spriteAtlas: atlas,
            index: SpriteIndexReader().read(jsonDecode(indexJson)),
          );
          break;
        } catch (e) {
          _logger.info(() => 'error reading sprite uri: ${uris.json}');
          continue;
        }
      }
    }

    return Style(
      theme: ThemeReader().read(styleJson),
      tileProviderBySource: providers,
      sprites: sprites,
      name: style.name,
    );
  }

  static Future<Map<String, EncodedTileProvider>> _readProviderByName(
    Map<String, Map<String, dynamic>> sources,
    String? apiKey,
    String uri,
  ) async {
    final providers = <String, EncodedTileProvider>{};

    for (final MapEntry(key: name, value: values) in sources.entries) {
      final String typeName = values['type'];
      final index = TileType.values.indexWhere((t) => t.name == typeName);
      if (index == -1) {
        continue;
      }
      final type = TileType.values[index];

      final Map<String, dynamic> source = values.containsKey('url')
          ? await () async {
              final uri = _decodeMapboxSourceUri(values['url'], apiKey);
              final resp = await get(uri);
              if (resp.statusCode != 200) {
                throw Exception('Http status ${resp.statusCode}: ${resp.body}');
              }

              try {
                return jsonDecode(resp.body);
              } catch (err) {
                _logger.warning('Could not parse $uri: $err');
                rethrow;
              }
            }()
          : values;

      final entryTiles = source['tiles'] as List?;
      if (entryTiles != null && entryTiles.isNotEmpty) {
        // NOTE: If there are multiple sources (e.g. a., b., c.), just pick the first one.
        // Otherwise [NetworkEncodedTileProvider] would have to support multiple sources.
        providers[name] = EncodedTileProvider.network(
          type: type,
          urlTemplate: _replaceKey(entryTiles[0], apiKey),
          maxZoom: source['maxzoom'] ?? 14,
          minZoom: source['minzoom'] ?? 1,
        );
      }
    }

    return providers;
  }
}

String _replaceKey(String url, String? key) => url.replaceAll(
      RegExp(RegExp.escape('{key}')),
      Uri.encodeQueryComponent(key ?? ''),
    );

Future<Uint8List> _getHttp(Uri uri) async {
  final r = await get(uri);
  return switch (r.statusCode) {
    200 => r.bodyBytes,
    _ => throw Exception('Http(${r.statusCode}): ${r.body}'),
  };
}

Future<String> _getHttpString(Uri uri) async {
  final r = await get(uri);
  return switch (r.statusCode) {
    200 => r.body,
    _ => throw Exception('Http(${r.statusCode}): ${r.body}'),
  };
}

final _logger = Logger('style');

import 'dart:async';
import 'dart:math' as math;
import 'dart:collection';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart' hide TileBuilder;
import 'package:vector_tile_renderer/vector_tile_renderer.dart'
    hide TileLayer, Logger;

import 'style.dart';
import 'tile_builder.dart';
import 'vector_tile_painter.dart';
import 'tileset_provider.dart';

class SymbolLayer extends StatefulWidget {
  final TileProviderConfig tileProviderConfig;

  const SymbolLayer({
    super.key,
    required this.tileProviderConfig,
  });

  @override
  State<SymbolLayer> createState() => _SymbolLayerState();
}

class _SymbolLayerState extends State<SymbolLayer> {
  final _cancelLoading = Completer();

  Future<(Theme, TilesetProvider)> buildTilesetProvider() async {
    final provider = await widget.tileProviderConfig.buildTilesetProvider();
    // NOTE: This is what causes only symbols/text to be drawn.
    final theme =
        provider.style.theme.copyWith(types: const {ThemeLayerType.symbol});
    return (theme, provider);
  }

  late final Future<(Theme, TilesetProvider)> _cached = buildTilesetProvider();

  @override
  void dispose() {
    _cancelLoading.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TileBuilder(
      key: const Key('symbollayer'),
      builder: (BuildContext context, TileCoordinates tile) {
        final key = ValueKey(tile);
        final tilesetFuture = _cached.then((t) async {
          final (theme, tilesetProvider) = t;
          final tileset = await tilesetProvider.provide(
            tile,
            _cancelLoading.future,
          );
          return (tilesetProvider.style, theme, tileset);
        });

        return FutureBuilder<(Style, Theme, Tileset)>(
          key: key,
          future: tilesetFuture,
          builder: (BuildContext context, AsyncSnapshot data) {
            if (!data.hasData) {
              return const SizedBox.shrink();
            }

            final (style, theme, tileset) = data.data!;
            return SymbolTile(
              key: key,
              tile: tile,
              theme: theme,
              style: style,
              tileset: tileset,
            );
          },
        );
      },
    );
  }
}

class SymbolTile extends StatefulWidget {
  final Theme theme;
  final Style style;
  final Tileset tileset;
  final TileCoordinates tile;
  final bool debugColors;

  const SymbolTile({
    super.key,
    required this.theme,
    required this.style,
    required this.tileset,
    required this.tile,
    this.debugColors = false,
  });

  @override
  State<SymbolTile> createState() => _SymbolTileState();
}

class _SymbolTileState extends State<SymbolTile> {
  final int jitter = _random.nextInt(25);
  late final key = ValueKey(widget.tile);
  late final color = widget.debugColors
      ? _checkerboardColors(widget.tile).withOpacity(0.6)
      : null;
  late final textPainterProvider = _ColoredTextPainterProvider(color);

  bool firstBuild = true;
  double prevZoom = 0;
  double prevRotation = 0;
  bool timeout = false;
  Timer? redrawTimeout;

  @override
  void dispose() {
    redrawTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.maybeOf(context)!;
    final zoom = camera.zoom;
    final rotation = camera.rotation;

    if (firstBuild ||
        (!timeout && (prevZoom != zoom) || prevRotation != rotation)) {
      firstBuild = false;
      prevZoom = zoom;
      prevRotation = rotation;
      redrawTimeout?.cancel();
      // If frames are drawn at 60 FPS, it only helps to jitter them in at
      // least 1/60s or ~17ms intervals.
      redrawTimeout = Timer(Duration(milliseconds: 120 + jitter * 17), () {
        if (mounted) {
          setState(() => timeout = true);
        }
      });
      return const SizedBox.shrink();
    }
    timeout = false;
    prevZoom = zoom;
    prevRotation = rotation;

    return RepaintBoundary(
      key: key,
      child: CustomPaint(
        painter: VectorTilePainter(
          tileset: widget.tileset,
          theme: widget.theme,
          textPainterProvider: textPainterProvider,
          zoom: zoom,
          tileZoom: widget.tile.z,
          rotation: camera.rotationRad,
          color: color?.withOpacity(0.2),
          spriteIndex: widget.style.sprites?.index,
          spriteAtlas: widget.style.sprites?.spriteAtlas,
        ),
        isComplex: true,
      ),
    );
  }
}

class _ColoredTextPainterProvider extends TextPainterProvider {
  final Color? color;
  final _cache = HashMap<StyledSymbol, TextPainter>();

  _ColoredTextPainterProvider(this.color);

  @override
  TextPainter provide(StyledSymbol symbol) {
    return _cache[symbol] ??= TextPainter(
      text: TextSpan(
        style: color != null
            ? symbol.style.textStyle.copyWith(backgroundColor: color)
            : symbol.style.textStyle,
        text: symbol.text,
      ),
      textAlign: symbol.style.textAlign,
      textDirection: TextDirection.ltr,
    )..layout();
  }
}

Color _checkerboardColors(TileCoordinates tile) =>
    switch ((tile.x.isEven, tile.y.isEven)) {
      (true, true) => Colors.red,
      (true, false) => Colors.green,
      (false, true) => Colors.blue,
      (false, false) => Colors.orange,
    };

final _random = math.Random();

import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/widgets.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' hide TileLayer;

import 'util.dart';

class VectorTilePainter extends CustomPainter {
  final Theme theme;
  final Tileset tileset;
  final TextPainterProvider textPainterProvider;
  final double scale;
  final double zoom;
  final int tileZoom;
  final double rotation;

  final RasterTileset? rasterTileset = null;
  final SpriteIndex? spriteIndex;
  final ui.Image? spriteAtlas;

  // Debug color to highlight tile boundaries.
  Color? color;

  VectorTilePainter({
    required this.theme,
    required this.tileset,
    required this.textPainterProvider,
    this.scale = 1.0,
    required this.zoom,
    required this.tileZoom,
    required this.rotation,
    this.color,
    this.spriteIndex,
    this.spriteAtlas,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (color != null) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = color!,
      );
    }

    final stretchFactor = stretch(zoom, tileZoom);
    if (stretchFactor != 1) {
      canvas.save();
      canvas.scale(stretchFactor);
    }

    Renderer(
      theme: theme,
      painterProvider: textPainterProvider,
    ).render(
      canvas,
      TileSource(
        tileset: tileset,
        rasterTileset: rasterTileset ?? const RasterTileset(tiles: {}),
        spriteAtlas: spriteAtlas,
        spriteIndex: spriteIndex,
      ),
      clip: null,
      zoomScaleFactor: stretchFactor,
      zoom: zoom,
      rotation: rotation,
    );

    if (stretchFactor != 1) {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(VectorTilePainter oldDelegate) =>
      oldDelegate.zoom != zoom || oldDelegate.rotation != rotation;
}

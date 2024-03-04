import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_map/src/layer/tile_layer/tile_range_calculator.dart';
import 'package:flutter_map/src/layer/tile_layer/tile_bounds/tile_bounds.dart';
import 'package:flutter_map/flutter_map.dart'
    show TileCoordinates, MapCamera, MobileLayerTransformer;

import 'util.dart';

class TileBuilder extends StatelessWidget {
  static const tileSize = 256.0;

  final Widget Function(BuildContext, TileCoordinates) builder;

  const TileBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    final mapCamera = MapCamera.maybeOf(context)!;
    final pixelOrigin = mapCamera.pixelOrigin;
    final zoom = mapCamera.zoom;

    final tileBounds = TileBounds(
      crs: mapCamera.crs,
      tileSize: tileSize,
      latLngBounds: mapCamera.visibleBounds,
    );
    // TODO: Should be (min, max) native zoom from map layer.
    final tileZoom = zoom.round().clamp(3, 15);
    final tileBoundsAtZoom = tileBounds.atZoom(tileZoom);
    const tileRangeCalculator = TileRangeCalculator(tileSize: tileSize);
    final visibleTileRange = tileRangeCalculator.calculate(
      camera: mapCamera,
      tileZoom: tileZoom,
    );

    final tileWidgets = <Widget>[];
    for (final tile in tileBoundsAtZoom.validCoordinatesIn(visibleTileRange)) {
      final scaledTileSize = tileSize * stretch(zoom, tile.z);

      tileWidgets.add(
        Positioned(
          key: ValueKey(tile),
          left: tile.x * scaledTileSize - pixelOrigin.x,
          top: tile.y * scaledTileSize - pixelOrigin.y,
          width: scaledTileSize,
          height: scaledTileSize,
          child: builder(context, tile),
        ),
      );
    }

    return MobileLayerTransformer(child: Stack(children: tileWidgets));
  }
}

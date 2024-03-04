import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dart_ui_isolate/dart_ui_isolate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:logging/logging.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart'
    hide Logger, TileLayer;

import 'tileset_provider.dart';

enum Resolution {
  pixel256x256,
  pixel512x512,
}

@pragma('vm:entry-point')
void _isolateMain(Map<String, dynamic> args) async {
  final sendPort = args['port'] as SendPort;
  final resolution = Resolution.values[args['resolution'] as int];
  final tileProviderConfig = TileProviderConfig.fromJson(args);

  final tilesetProvider = await tileProviderConfig.buildTilesetProvider();
  final style = tilesetProvider.style;
  final theme = style.theme;

  final recvPort = ReceivePort();
  sendPort.send(recvPort.sendPort);

  recvPort.listen((data) async {
    if (data is Map<String, dynamic>) {
      final reply = data['reply'] as SendPort;
      final coordinates = TileCoordinates(data['x'], data['y'], data['z']);

      final completer = Completer();
      try {
        final image = await _rasterize(
          tilesetProvider,
          coordinates,
          theme,
          completer.future,
          1.0,
          resolution,
        );

        // FIXME: Ideally we wouldn't encode here. Ideally we'd just pass a handle or at least just send raw bytes.
        // I tried passing ImageDescriptor as an native image handle, however it's not serializable. As passing bytes
        // is very overheady in general. The images are kept on the native side, so you end up copying into Dart
        // isolate, send it to the other dart isolate, move it back to native and then decode it :sigh:.
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))
            ?.buffer
            .asUint8List();
        if (bytes != null) {
          reply.send(bytes);
        } else {
          reply.send(Exception('failed to serialize image'));
        }
      } catch (err) {
        reply.send(err);
      }
    }
  });
}

Future<ui.Image> _rasterize(
  TilesetProvider tilesetProvider,
  TileCoordinates coordinates,
  Theme theme,
  Future<void> cancelLoading,
  double scale,
  Resolution resolution,
) async {
  bool canceled = false;
  cancelLoading.whenComplete(() => canceled = true);

  final tileset = await tilesetProvider.provide(coordinates, cancelLoading);
  if (canceled) throw Error.tileLoadingCancelled;

  // Remove symbol layers. Draw them later on top.
  final layers = theme.layers
      .where((e) => e.type != ThemeLayerType.symbol)
      .map((e) => e.type)
      .toSet();

  final zoom = coordinates.z.toDouble();
  return await ImageRenderer(
    theme: theme.copyWith(types: layers),
    // Determines the resolution, i.e. 1=255x256 and 2=512x512.
    scale: switch (resolution) {
      Resolution.pixel256x256 => 1,
      Resolution.pixel512x512 => 2,
    },
    // Note: we could have some caching text paint provider to reduce the
    // number of redundant layouts.
    textPainterProvider: const DefaultTextPainterProvider(),
  ).render(
    TileSource(tileset: tileset),
    zoom: zoom,
    zoomScaleFactor: math.pow(2, scale).toDouble(),
  );
}

class IsolateManager {
  static final _ports = List<(SendPort, ReceivePort)?>.filled(4, null);

  static Future<ui.Image> rasterize(
    TileProviderConfig tileProviderConfig,
    TileCoordinates c,
    Resolution resolution,
  ) async {
    final index = (c.y % 2) << 1 | (c.x % 2);
    final (port, _) = _ports[index] ??= await () async {
      final recvPort = ReceivePort();
      DartUiIsolate.spawn(
        _isolateMain,
        <String, dynamic>{
          'port': recvPort.sendPort,
          'resolution': resolution.index,
          ...tileProviderConfig.toJson(),
        },
      );
      return ((await recvPort.first) as SendPort, recvPort);
    }();

    final recvPort = ReceivePort();
    port.send(<String, dynamic>{
      'reply': recvPort.sendPort,
      'x': c.x,
      'y': c.y,
      'z': c.z,
    });
    try {
      final resp = await recvPort.first;
      if (resp is! Uint8List) {
        throw Exception('Got non byte response: $resp');
      }

      final codec = await ui.instantiateImageCodec(resp);
      return (await codec.getNextFrame()).image;
    } finally {
      recvPort.close();
    }
  }
}

class RenderConfig {
  final Resolution resolution;
  final bool rasterizeOnUiIsolate;

  const RenderConfig({
    this.resolution = Resolution.pixel256x256,
    this.rasterizeOnUiIsolate = true,
  });

  bool get useUiIsolates {
    if (!rasterizeOnUiIsolate) return false;

    // NOTE: At this point only iOS, Android and OSX support ui isolates.
    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) {
      return true;
    }

    _logger.warning('Ui Isolate rasterization has been disable due to '
        'unsupported platform. Only Android, iOS, and OS X are supported.');
    return false;
  }
}

class FlutterMapVectorTileProvider extends TileProvider {
  final TileProviderConfig tileProviderConfig;
  final RenderConfig renderConfig;
  final bool useUiIsolates;

  TilesetProvider? _cached;

  FlutterMapVectorTileProvider({
    super.headers,
    required this.tileProviderConfig,
    this.renderConfig = const RenderConfig(),
  }) : useUiIsolates = renderConfig.useUiIsolates;

  @override
  bool get supportsCancelLoading => true;

  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates coordinates,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    if (useUiIsolates) {
      return UiIsolateImage(
        tileProviderConfig,
        renderConfig.resolution,
        coordinates,
      );
    }
    return UiImage(
      () async => _cached ??= await tileProviderConfig.buildTilesetProvider(),
      renderConfig.resolution,
      coordinates,
      cancelLoading: cancelLoading,
    );
  }
}

class UiImage extends ImageProvider<UiImage> {
  final Future<TilesetProvider> Function() tilesetProviderBuilder;
  final Resolution resolution;
  final TileCoordinates coordinates;
  final double scale;

  final Future<void> cancelLoading;

  const UiImage(
    this.tilesetProviderBuilder,
    this.resolution,
    this.coordinates, {
    this.scale = 1.0,
    required this.cancelLoading,
  });

  @override
  Future<UiImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<UiImage>(this);

  @override
  ImageStreamCompleter loadImage(UiImage key, ImageDecoderCallback decode) =>
      MyOneFrameImageStreamCompleter(_loadAsync(key));

  Future<ImageInfo> _loadAsync(UiImage key) async {
    final tilesetProvider = await tilesetProviderBuilder();
    final image = await _rasterize(
      tilesetProvider,
      coordinates,
      tilesetProvider.style.theme,
      cancelLoading,
      scale,
      resolution,
    );
    return ImageInfo(image: image);
  }

  @override
  String toString() => 'UiImage($coordinates}, scale: $scale)';
}

class UiIsolateImage extends ImageProvider<UiIsolateImage> {
  final TileProviderConfig tileProviderConfig;
  final Resolution resolution;
  final TileCoordinates coordinates;

  const UiIsolateImage(
    this.tileProviderConfig,
    this.resolution,
    this.coordinates,
  );

  @override
  Future<UiIsolateImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<UiIsolateImage>(this);

  @override
  ImageStreamCompleter loadImage(
          UiIsolateImage key, ImageDecoderCallback decode) =>
      MyOneFrameImageStreamCompleter(_loadAsync(key));

  Future<ImageInfo> _loadAsync(UiIsolateImage key) async {
    final image = await IsolateManager.rasterize(
      tileProviderConfig,
      coordinates,
      resolution,
    );
    return ImageInfo(image: image);
  }

  @override
  String toString() => 'UiIsolateImage($coordinates)';
}

// Ripped straight from dart:ui, specifically [OneFrameImageStreamCompleter].
class MyOneFrameImageStreamCompleter extends ImageStreamCompleter {
  MyOneFrameImageStreamCompleter(
    Future<ImageInfo> image, {
    InformationCollector? informationCollector,
  }) {
    image.then<void>(
      setImage,
      onError: (Object error, StackTrace stack) {
        if (error is Error && error == Error.tileLoadingCancelled) {
          return;
        }

        reportError(
          context: ErrorDescription('resolving a single-frame image stream'),
          exception: error,
          stack: stack,
          informationCollector: informationCollector,
          silent: true,
        );
      },
    );
  }
}

final _logger = Logger('tile_provider');

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'api_key.dart';
import 'package:vector_tile_it/vector_tile_it.dart';

Future<void> main() async {
  Logger.root.level = kDebugMode ? Level.FINE : Level.INFO;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print(
        '${record.level.name}: ${record.time}  ${record.loggerName}: ${record.message}');
  });

  WidgetsFlutterBinding.ensureInitialized();

  final cacheDir = await () async {
    if (kIsWeb) {
      return null;
    }
    final tmpDir = await getTemporaryDirectory();
    return Directory('${tmpDir.path}/vectorit');
  }();

  runApp(MyApp(cacheDir: cacheDir));
}

class MyApp extends StatelessWidget {
  final Directory? cacheDir;

  const MyApp({super.key, this.cacheDir});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: MyHomePage(cacheDir: cacheDir),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final Directory? cacheDir;

  const MyHomePage({super.key, this.cacheDir});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final config = TileProviderConfig(
      uri: 'mapbox://styles/mapbox/streets-v12?access_token={key}',
      apiKey: mapboxApiKey,
      cacheDir: widget.cacheDir,
    );

    return Scaffold(
      body: FlutterMap(
        options: MapOptions(
          initialCenter: const LatLng(49.398750, 8.672434),
          initialZoom: 10,
          cameraConstraint: CameraConstraint.contain(
            bounds: LatLngBounds(
              const LatLng(-90, -180),
              const LatLng(90, 180),
            ),
          ),
        ),
        children: [
          TileLayer(
            panBuffer: 1,
            keepBuffer: 2,
            tileProvider: FlutterMapVectorTileProvider(
              tileProviderConfig: config,
              renderConfig: const RenderConfig(),
            ),
          ),
          SymbolLayer(
            key: const Key('symbollayer'),
            tileProviderConfig: config,
          ),
        ],
      ),
    );
  }
}

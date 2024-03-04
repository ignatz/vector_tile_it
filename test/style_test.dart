import 'dart:io';

import 'dart:convert';
import 'package:test/test.dart';

import 'package:vector_tile_it/src/style.dart';

void main() {
  test('Mapbox style json', () {
    final style = MapboxStyle.fromJson(jsonDecode(foo));
    expect(style.version, equals(8));
  });

  test('Mapbox style to style', () {
    // TODO: requires mocking of the http.Client.
  });
}

const foo = """
{
  "version": 8,
  "name": "Meteorites",
  "metadata": {
    "mapbox:origin": "basic-template-v1",
    "mapbox:autocomposite": true,
    "mapbox:type": "template",
    "mapbox:sdk-support": {
      "js": "0.45.0",
      "android": "6.0.0",
      "ios": "4.0.0"
    }
  },
  "center": [
    74.24426803763072,
    -2.2507114487818853
  ],
  "zoom": 0.6851443156248076,
  "bearing": 0,
  "pitch": 0,
  "sources": {
    "composite": {
      "url": "mapbox://mapbox.mapbox-streets-v8,examples.0fr72zt8",
      "type": "vector"
    }
  },
  "sprite": "mapbox://sprites/examples/cjikt35x83t1z2rnxpdmjs7y7",
  "glyphs": "mapbox://fonts/{username}/{fontstack}/{range}.pbf",
  "layers": [
    {
      "id": "background",
      "type": "background",
      "layout": {},
      "paint": {
        "background-color": [
          "interpolate"
        ]
      }
    }
  ],
  "created": "2015-10-30T22:18:31.111Z",
  "id": "cjikt35x83t1z2rnxpdmjs7y7",
  "modified": "2015-10-30T22:22:06.077Z",
  "owner": "examples",
  "visibility": "public",
  "draft": false
}
""";

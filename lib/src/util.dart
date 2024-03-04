import 'dart:math' as math;

// Assuming that the currentZoom is in [tileZoom, timeZoom+1), the stretch will be in [1, 2].
double stretch(double currentZoom, int tileZoom) {
  return _crsScale(currentZoom) / _crsScale(tileZoom.toDouble());
}

/// Zoom to Scale function.
double _crsScale(double zoom) => 256.0 * math.pow(2, zoom);

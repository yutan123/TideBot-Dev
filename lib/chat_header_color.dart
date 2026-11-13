import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// An opaque surface that keeps the wallpaper hue with a quieter saturation
/// and a distinct brightness, rather than showing the image through the bar.
Color chatHeaderSurface(Color sample, {required bool dark}) {
  final hsl = HSLColor.fromColor(sample);
  return hsl
      .withSaturation((hsl.saturation * .55).clamp(0.0, .45))
      .withLightness(
        dark ? .14 + hsl.lightness * .10 : .80 + hsl.lightness * .12,
      )
      .toColor()
      .withValues(alpha: 1);
}

Future<Color?> sampleChatHeaderColor(String path) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      await File(path).readAsBytes(),
      targetWidth: 48,
      targetHeight: 48,
      allowUpscaling: false,
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    double red = 0, green = 0, blue = 0, weight = 0;
    // Use the upper third, where the wallpaper meets the toolbar. Alpha is
    // weighted so transparent pixels do not turn the sampled color black.
    final rows = (image.height / 3).ceil();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < image.width; x++) {
        final offset = (y * image.width + x) * 4;
        final alpha = data.getUint8(offset + 3) / 255;
        red += data.getUint8(offset) * alpha;
        green += data.getUint8(offset + 1) * alpha;
        blue += data.getUint8(offset + 2) * alpha;
        weight += alpha;
      }
    }
    if (weight == 0) return null;
    return Color.fromARGB(
      255,
      (red / weight).round(),
      (green / weight).round(),
      (blue / weight).round(),
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

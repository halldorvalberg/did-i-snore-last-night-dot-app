/// On-device YAMNet classifier — int8-quantized variant.
///
/// Second line of defense after the spectral pre-filter. Turns an event PCM
/// blob into a curated-label confidence map using max-over-frames
/// aggregation with a precision floor (see [LabelCfg.frameFloorConfidence]
/// and [LabelCfg.minFrameFractionAboveFloor]).
///
/// The classifier is intentionally synchronous on the calling thread; the
/// recorder is responsible for not blocking the mic loop. Reject policy
/// lives in `recorder_service.dart`, NOT here, so future tuning lives at
/// one well-known spot and the classifier stays test-friendly.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../config/constants.dart';
import 'label_map.dart';

class Yamnet {
  static const String _modelAsset = 'assets/models/yamnet.tflite';
  static const String _classMapAsset = 'assets/models/yamnet_class_map.csv';
  static const int _numClasses = 521;

  /// Minimum YAMNet input — 0.975 s at 16 kHz. Shorter inputs are zero-padded.
  static const int _minSamples = 15600;

  Interpreter? _interp;
  List<String>? _classNames;

  /// Output tensor dtype captured at load. The bundled MediaPipe int8
  /// YAMNet emits int8-quantized scores (TensorType.int8), which we
  /// dequantize on each [classify] call via [_outputScale] /
  /// [_outputZeroPoint]. If a future model variant ships with float32 or
  /// uint8 output, [classify] handles those branches too — but this build
  /// has been observed to use the int8 path on this specific asset.
  TensorType? _outputType;
  double _outputScale = 1.0;
  int _outputZeroPoint = 0;

  bool get isLoaded => _interp != null && _classNames != null;

  /// Idempotent. Loads the TFLite interpreter and parses the canonical
  /// 3-column class map CSV (`index,mid,display_name`, header skipped).
  /// Quoted display names like `"Burping, eructation"` are unquoted to
  /// match [LabelMap.yamnetToCurated] keys.
  Future<void> load() async {
    if (isLoaded) return;

    _interp = await Interpreter.fromAsset(_modelAsset);

    final csv = await rootBundle.loadString(_classMapAsset);
    _classNames = csv
        .split('\n')
        .skip(1)
        .where((l) => l.trim().isNotEmpty)
        .map(displayNameFromCsvRow)
        .toList(growable: false);

    if (_classNames!.length != _numClasses) {
      throw StateError(
        'yamnet_class_map.csv yielded ${_classNames!.length} rows, '
        'expected $_numClasses',
      );
    }

    final outTensor = _interp!.getOutputTensor(0);
    _outputType = outTensor.type;
    final params = outTensor.params;
    _outputScale = params.scale;
    _outputZeroPoint = params.zeroPoint;
  }

  /// Run inference and return the curated label → confidence map.
  ///
  /// May return an empty map when YAMNet emits zero frames (pathologically
  /// short input) or when every per-class max gets zeroed by the precision
  /// floor (no class survives in ≥ 25% of frames above 0.3). The recorder's
  /// reject policy reads scores via `?? 0` and treats absent keys as zero,
  /// so an empty map is equivalent to "max_curated == 0, Other == 0".
  Map<String, double> classify(Int16List pcm) {
    final interp = _interp;
    final classNames = _classNames;
    if (interp == null || classNames == null) {
      throw StateError('Yamnet.load() must complete before classify()');
    }

    // Pad to YAMNet's minimum window. Shorter events shouldn't reach here
    // (Phase 4 enforces minEventDurationMs), but zero-extending is the
    // defined fallback per spec §5.2.
    Int16List padded = pcm;
    if (padded.length < _minSamples) {
      padded = Int16List(_minSamples)..setRange(0, pcm.length, pcm);
    }

    final waveform = Float32List(padded.length);
    for (var i = 0; i < padded.length; i++) {
      waveform[i] = padded[i] / 32768.0;
    }

    // Resize input + allocate tensors so the dynamic output shape (frames)
    // is known before we allocate the output buffer.
    interp.resizeInputTensor(0, [waveform.length]);
    interp.allocateTensors();

    final outTensor = interp.getOutputTensor(0);
    final outShape = outTensor.shape; // [frames, 521]
    if (outShape.length != 2 || outShape[1] != _numClasses) {
      throw StateError(
        'Unexpected YAMNet output shape: $outShape '
        '(expected [frames, $_numClasses])',
      );
    }
    final frames = outShape[0];
    if (frames <= 0) return const {};

    // Run inference into a typed buffer matching the model's output dtype,
    // then dequantize to [0, 1] floats. Treating int8 bytes as floats
    // would yield garbage; treating float32 bytes as int8 would too. The
    // [_outputType] captured at load() picks the correct branch.
    final List<List<double>> scores;
    switch (_outputType) {
      case TensorType.float32:
        final buf = List.generate(
          frames,
          (_) => List<double>.filled(_numClasses, 0.0),
          growable: false,
        );
        interp.run(waveform, buf);
        scores = buf;
        break;
      case TensorType.int8:
      case TensorType.uint8:
        final buf = List.generate(
          frames,
          (_) => List<int>.filled(_numClasses, 0),
          growable: false,
        );
        interp.run(waveform, buf);
        scores = List.generate(frames, (f) {
          final row = List<double>.filled(_numClasses, 0.0);
          for (var c = 0; c < _numClasses; c++) {
            row[c] = (buf[f][c] - _outputZeroPoint) * _outputScale;
          }
          return row;
        }, growable: false);
        break;
      default:
        throw StateError(
          'Unsupported YAMNet output dtype: $_outputType',
        );
    }

    // Max-over-frames + precision floor. See spec §5.2.
    final maxPerClass = List<double>.filled(_numClasses, 0.0);
    final framesAboveFloor = List<int>.filled(_numClasses, 0);
    for (final frame in scores) {
      for (var c = 0; c < _numClasses; c++) {
        final v = frame[c];
        if (v > maxPerClass[c]) maxPerClass[c] = v;
        if (v >= LabelCfg.frameFloorConfidence) framesAboveFloor[c]++;
      }
    }
    final minFrames =
        (frames * LabelCfg.minFrameFractionAboveFloor).ceil();
    for (var c = 0; c < _numClasses; c++) {
      if (framesAboveFloor[c] < minFrames) maxPerClass[c] = 0.0;
    }

    return LabelMap.aggregate(maxPerClass, classNames);
  }

  /// Release the native interpreter. Safe to call multiple times.
  void close() {
    _interp?.close();
    _interp = null;
    _classNames = null;
    _outputType = null;
  }

  /// Parse one CSV data row's display_name. The canonical class map quotes
  /// names containing commas (`5,/m/.../,"Burping, eructation"`), so naive
  /// `split(',')[2]` would yield `"Burping`. We split on the second comma
  /// boundary and strip the surrounding double-quotes.
  ///
  /// Exposed for testing because the integration tests in `yamnet_test.dart`
  /// skip on Linux (no native tflite), and this is the one place a
  /// quoted-comma regression would silently route `"Burping, eructation"`
  /// to `Other` instead of `Belch` — the row count check in [load] does NOT
  /// catch it.
  @visibleForTesting
  static String displayNameFromCsvRow(String row) {
    // Find the first two commas that delimit index and mid; everything
    // after the second comma is the display_name (which may contain its
    // own commas inside double-quotes).
    final firstComma = row.indexOf(',');
    final secondComma = row.indexOf(',', firstComma + 1);
    if (firstComma < 0 || secondComma < 0) {
      throw FormatException('malformed class-map row: $row');
    }
    var name = row.substring(secondComma + 1).trim();
    // Strip wrapping double-quotes if present.
    if (name.startsWith('"') && name.endsWith('"')) {
      name = name.substring(1, name.length - 1);
    }
    return name.replaceAll('"', '');
  }
}

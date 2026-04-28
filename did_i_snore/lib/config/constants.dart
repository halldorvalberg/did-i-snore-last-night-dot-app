/// Canonical numbers for did-i-snore-last-night.app.
///
/// Single source of truth — never inline literals for sample rates, frame
/// sizes, durations, or thresholds. spec-reviewer fails on inline magic
/// numbers anywhere except this file.
library;

class AudioCfg {
  static const int sampleRateHz = 16000;
  static const int channels = 1;
  static const int frameMs = 20;
  static const int frameBytes = sampleRateHz * 2 * frameMs ~/ 1000;
  static const int preRollMs = 2000;
  static const int tailMs = 1000;
  static const int gateHoldMs = 300;
  static const int eventMergeGapMs = 4000;
  static const int classifierFrameMs = 960;
  static const int minEventDurationMs = 500;
  static const int calibrationSeconds = 30;
}

class GateCfg {
  static const double tHighMargin = 9.0;
  static const double tLowMargin = 5.0;
  static const double madK = 5.0;
}

class SpectralCfg {
  static const double minSnoreBandFraction = 0.18;
  static const double maxFlatness = 0.65;
  static const double maxAmbientMadForFilter = 4.0;
  static const double snoreBandLowHz = 50.0;
  static const double snoreBandHighHz = 500.0;
}

class LabelCfg {
  static const double minDisplayConfidence = 0.4;
  static const double minTopCuratedForKeep = 0.3;
  static const double maxOtherForKeep = 0.5;
  static const double frameFloorConfidence = 0.3;
  static const double minFrameFractionAboveFloor = 0.25;
}

class RetentionCfg {
  static const int defaultDays = 14;
  static const int minFreeDiskMb = 200;
  static const int janitorIntervalHours = 6;
  static const int hardDeleteAfterDays = 1;
}

class EncoderCfg {
  static const int opusBitrateKbps = 24;
  static const int encodeQueueMaxDepth = 8;
}

class DebugCfg {
  static const int logMaxBytes = 2 * 1024 * 1024;
  static const int logFlushIntervalSec = 5;
  static const int logBufferLineLimit = 200;
}

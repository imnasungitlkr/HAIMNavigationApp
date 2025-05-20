import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:uuid/uuid.dart';

class NavigationAssistant {
  final FlutterTts _tts = FlutterTts();
  bool _isTtsInitialized = false;
  bool _isSpeaking = false;
  String? _lastSpokenText;
  DateTime? _lastSpokenTime;
  final Map<String, DateTime> _lastAnnouncementTimes = {};
  final Duration _debounceDuration = Duration(seconds: 6);
  final Uuid _uuid = Uuid();
  String? _currentUtteranceId;
  Completer<void>? _currentSpeechCompleter;

  NavigationAssistant() {
    _initializeTts();
  }

  Future<void> _initializeTts() async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      _tts.setStartHandler(() {
        _isSpeaking = true;
        _currentSpeechCompleter?.complete();
        _currentSpeechCompleter = Completer<void>();
        print('TTS: Utterance ID $_currentUtteranceId started');
      });

      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        _currentUtteranceId = null;
        _currentSpeechCompleter?.complete();
        _currentSpeechCompleter = null;
        print('TTS: Utterance ID $_currentUtteranceId completed');
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
        _currentUtteranceId = null;
        _currentSpeechCompleter?.completeError(Exception(msg));
        _currentSpeechCompleter = null;
        print('TTS Error: $msg');
      });

      _tts.setCancelHandler(() {
        _isSpeaking = false;
        _currentUtteranceId = null;
        _currentSpeechCompleter?.complete();
        _currentSpeechCompleter = null;
        print('TTS: Utterance ID $_currentUtteranceId stopped. Interrupted: true');
      });

      _isTtsInitialized = true;
      print('TTS Initialized: true');
    } catch (e) {
      _isTtsInitialized = false;
      print('TTS Initialization failed: $e');
    }
  }

  Future<void> updateSpeechRate(double rate) async {
    await _tts.setSpeechRate(rate);
  }

  Future<void> speakAnnouncement(
      String text, {
        bool isCritical = false,
        bool isManualQrScan = false,
        bool priority = false,
        Completer<void>? completer,
      }) async {
    if (!_isTtsInitialized) {
      print("TTS not initialized in NavigationAssistant, cannot speak: $text");
      completer?.completeError(Exception("TTS not initialized"));
      return;
    }

    final utteranceId = _uuid.v4();
    final now = DateTime.now();
    final isRedundant = _lastSpokenText == text &&
        _lastSpokenTime != null &&
        now.difference(_lastSpokenTime!).inSeconds < _debounceDuration.inSeconds &&
        !isCritical &&
        !isManualQrScan &&
        !priority;

    if (isRedundant) {
      print("TTS: Suppressing redundant announcement: $text");
      completer?.complete();
      return;
    }

    // Discard non-priority announcements if TTS is busy
    if (!priority && !isCritical && !isManualQrScan && _isSpeaking) {
      print("TTS: Discarding non-priority announcement: $text");
      completer?.complete();
      return;
    }

    // For priority, critical, or manual QR scan announcements, stop ongoing speech
    if (priority || isCritical || isManualQrScan) {
      await _tts.stop();
      _isSpeaking = false;
      print("TTS: Stopped previous speech for critical/priority/manual QR");
    }

    try {
      _currentUtteranceId = utteranceId;
      _currentSpeechCompleter = Completer<void>();
      print("TTS: Speaking '$text' with utterance ID $utteranceId");
      await _tts.speak(text);
      _lastSpokenText = text;
      _lastSpokenTime = now;
      await waitForCompletion();
      completer?.complete();
    } catch (e) {
      print("TTS: Error speaking '$text': $e");
      _isSpeaking = false;
      _currentUtteranceId = null;
      _currentSpeechCompleter?.completeError(e);
      _currentSpeechCompleter = null;
      completer?.completeError(e);
    }
  }

  Future<void> waitForCompletion() async {
    if (_currentSpeechCompleter != null) {
      await _currentSpeechCompleter!.future;
    }
  }

  Future<void> stop() async {
    await _tts.stop();
    _isSpeaking = false;
    _currentUtteranceId = null;
    _lastSpokenText = null;
    _lastSpokenTime = null;
    _lastAnnouncementTimes.clear();
    _currentSpeechCompleter?.complete();
    _currentSpeechCompleter = null;
  }

  Future<void> dispose() async {
    await stop();
    _lastAnnouncementTimes.clear();
  }

  bool get isSpeaking => _isSpeaking;
  bool get isInitialized => _isTtsInitialized;
}
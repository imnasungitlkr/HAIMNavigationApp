import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:collection';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:vibration/vibration.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:porcupine_flutter/porcupine_manager.dart'; // Added for Porcupine
import 'admin_panel.dart';
import 'config.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_compass/flutter_compass.dart'; // Replace sensors_plus

// Global notifier for QR data changes
final ValueNotifier<bool> qrDataChangedNotifier = ValueNotifier(false);

class ThemeProvider extends ChangeNotifier {
  bool _isDarkMode = false;
  double _distanceThreshold = 75.0;
  double _speechRate = 0.5;
  int _vibrationDuration = 500;
  int _announcementInterval = 5;

  bool get isDarkMode => _isDarkMode;
  double get distanceThreshold => _distanceThreshold;
  double get speechRate => _speechRate;
  int get vibrationDuration => _vibrationDuration;
  int get announcementInterval => _announcementInterval;

  Future<void> loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool('isDarkMode') ?? false;
    _distanceThreshold = prefs.getDouble('distanceThreshold') ?? 75.0;
    _speechRate = prefs.getDouble('speechRate') ?? 0.5;
    _vibrationDuration = prefs.getInt('vibrationDuration') ?? 500;
    _announcementInterval = prefs.getInt('announcementInterval') ?? 5;
  }

  Future<void> toggleTheme() async {
    _isDarkMode = !_isDarkMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', _isDarkMode);
    notifyListeners();
  }

  Future<void> setDistanceThreshold(double value) async {
    _distanceThreshold = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('distanceThreshold', _distanceThreshold);
    notifyListeners();
  }

  Future<void> setSpeechRate(double value) async {
    _speechRate = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('speechRate', _speechRate);
    notifyListeners();
  }

  Future<void> setVibrationDuration(int value) async {
    _vibrationDuration = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('vibrationDuration', _vibrationDuration);
    notifyListeners();
  }

  Future<void> setAnnouncementInterval(int value) async {
    _announcementInterval = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('announcementInterval', _announcementInterval);
    notifyListeners();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  final themeProvider = ThemeProvider();
  await themeProvider.loadTheme();
  runApp(
    ChangeNotifierProvider(
      create: (_) => themeProvider,
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          home: const BlindNavigationApp(),
        );
      },
    );
  }
}

class Landmark {
  final String name;
  final LatLng position;

  Landmark(this.name, this.position);
}

class BlindNavigationApp extends StatefulWidget {
  const BlindNavigationApp({super.key});

  @override
  State<BlindNavigationApp> createState() => _BlindNavigationAppState();
}

class _BlindNavigationAppState extends State<BlindNavigationApp> {
  final LatLng _initialPosition = const LatLng(23.761616649702475, 91.2621314819549);
  MapType _currentMapType = MapType.normal;
  bool _isTrafficEnabled = false;
  bool _isNavigating = false;
  LatLng? _destination;
  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  Position? _currentPosition;
  final FlutterTts _flutterTts = FlutterTts();
  late BitmapDescriptor qrPinIcon;
  BitmapDescriptor destinationIcon = BitmapDescriptor.defaultMarker;
  Timer? _locationTimer;
  final Map<String, Map<String, dynamic>> _directionsCache = {};
  List<LatLng> _polylinePoints = [];
  double? _distanceFromSensor;
  Timer? _distanceTimer;
  List<String> _detectedObjects = [];
  final Set<String> _visitedLandmarks = {};
  Map<String, LatLng> qrLocations = {};
  bool _qrDetected = false;
  String? _lastDetectedQrId;
  Map<String, dynamic> _qrData = {};
  Timer? _qrDisplayTimer;
  Map<String, List<String>> qrGraph = {};
  String? _destinationQrId;
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechInitialized = false;
  bool _isListening = false;
  bool _awaitingDestination = false;
  final Queue<String> _ttsQueue = Queue();
  bool _isTtsSpeaking = false;
  LatLng? _initialQrPosition;
  String _recognizedText = '';
  bool _ttsInitialized = false;
  DateTime _lastDirectionFetch = DateTime.now();
  final Duration _debounceDuration = Duration(seconds: 10);
  bool _awaitingGpsSwitchResponse = false;
  bool _lastAnnouncedBelowThreshold = false;
  DateTime? _lastObjectAnnouncementTime;
  PorcupineManager? _porcupineManager;
  bool _isPorcupineActive = false;
  bool _motionDetected = false;
  String _motionDirection = "";
  String _movingObjectName = ''; // Simplified from Map if confidence isn't needed
  DateTime? _lastMotionAnnouncement; // Renamed for clarity
  bool _isMotionAnnouncementInProgress = false;
  List<int> _motionCentroid = [0, 0]; // Only if used elsewhere (e.g., ServerDataScreen)
  String? _interruptedText; // For resuming interrupted TTS
  double? _interruptedProgress; // For resuming interrupted TTS
  final ValueNotifier<bool> qrDataChangedNotifier = ValueNotifier(false);
  double? _userHeading; // User's current heading in degrees (0-360)
  StreamSubscription<CompassEvent>? _compassSubscription; // Updated for flutter_compass
  bool _justStoppedNavigation = false;
  bool _isStopping = false;
  bool _isTtsSuppressed = false; // New flag to suppress TTS during voice interaction
  DateTime? _lastVibrationTime;

  final List<Landmark> landmarks = [];


  @override
  void initState() {
    super.initState();
    _initializeApp();
    _startDistanceUpdates();
    _compassSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading != null) {
        setState(() {
          _userHeading = event.heading!; // Pre-calculated heading from flutter_compass
        });
      }
    });
  }

  Future<void> _initializeApp() async {
    // Step 1: Initialize TTS and speak welcome message
    await _initializeTts();
    await _speak("Welcome to the Blind Navigation App. Say 'Hey Coco' or press the microphone button to begin.");

    // Step 2: Load QR data and other setup
    await _loadQrData();
    await _setCustomMarkers();
    _addMarkers();
    _startLocationUpdates();
    _startDistanceUpdates();

    // Step 4: Initialize Porcupine for wake word detection
    await _initializePorcupine();

    // Step 5: Initialize speech recognition without starting it
    await _initializeSpeech();

    _flutterTts.setCompletionHandler(() {
      print("TTS Speech Completed");
    });
    qrDataChangedNotifier.addListener(_reloadQrData);
  }

  // Initialize Porcupine for wake word detection
  Future<void> _initializePorcupine() async {
    try {
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
        "7tWk5dPHECjbjqu9XalqySvx/CgIIoBw6AtPCt57CesqALrWg9fF5Q==",
        ["assets/hey-coco_en_android_v3_0_0.ppn"],
            (int keywordIndex) {
          if (keywordIndex == 0) { // "Hey Coco" detected
            print("Wake word 'Hey Coco' detected");
            _handleWakeWordDetection(); // New handler for wake word
          }
        },
      );
      await _porcupineManager?.start();
      _isPorcupineActive = true;
      print("Porcupine wake word detection started");
    } catch (e) {
      print("Error initializing Porcupine: $e");
      await _speak("Failed to initialize wake word detection.");
    }
  }

  Future<void> _handleWakeWordDetection() async {
    if (_isPorcupineActive) {
      await _porcupineManager?.stop();
      _isPorcupineActive = false;
      print("Porcupine stopped for command input");

      // Stop current TTS and suppress new TTS
      await _flutterTts.stop();
      await _flutterTts.awaitSpeakCompletion(true);
      _isTtsSpeaking = false;
      setState(() => _isTtsSuppressed = true); // Suppress TTS from processes
      print("TTS stopped and suppressed due to wake word detection");

      // Start voice interaction
      await _startVoiceInteraction();

      // Resume TTS after interaction (handled in _startVoiceInteraction)
    }
  }

  Future<void> _initializeTts() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(Provider.of<ThemeProvider>(context, listen: false).speechRate);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    _ttsInitialized = true;
    print("TTS Initialized");
  }

  Future<void> _initializeSpeech() async {
    if (await Permission.microphone.request().isGranted) {
      _speechInitialized = await _speech.initialize(
        onStatus: (status) {
          print('Speech status: $status');
          if (status == 'done' && _isListening) {
            _stopListeningWithFeedback();
          }
        },
        onError: (error) => print('Speech error: $error'),
      );
      print("Speech initialized: $_speechInitialized");
      if (!_speechInitialized) {
        await _speak("Speech recognition could not be initialized.");
      }
    } else {
      await _speak("Microphone permission denied. Voice commands won’t work.");
      print("Microphone permission denied");
    }
    // Removed: await _startVoiceInteraction(); // No immediate mic activation
  }

  void _stopListeningWithFeedback() async {
    if (_isListening) {
      _speech.stop();
      if (_recognizedText.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _speak("No voice input detected. Please try again.");
      }
      setState(() {
        _isListening = false;
        _recognizedText = '';
      });
      _restartPorcupine(); // Restart Porcupine after feedback
    }
  }

  Future<void> _restartPorcupine() async {
    if (!_isPorcupineActive) {
      try {
        await _porcupineManager?.start();
        _isPorcupineActive = true;
        print("Porcupine restarted after command");
      } catch (e) {
        print("Error restarting Porcupine: $e");
        await _speak("Failed to restart wake word detection.");
      }
    }
  }

  void _stopListening() {
    if (_isListening) {
      _speech.stop();
      setState(() {
        _isListening = false;
        _recognizedText = '';
      });
      print("Stopped listening");

      // Restart Porcupine
      Future.delayed(const Duration(seconds: 1), _restartPorcupine);
    }
  }

  Future<void> _handleGpsSwitchResponse(String response) async {
    _awaitingGpsSwitchResponse = false;
    String normalizedResponse = response.toLowerCase().trim();

    if (normalizedResponse == "yes" && _currentPosition != null && _destination != null) {
      await _speak("Switching to GPS navigation.");
      setState(() {
        _destinationQrId = null;
      });
      await _fetchAndSpeakDirections(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        _destination!,
      );
    } else if (normalizedResponse == "no" && _lastDetectedQrId != null) {
      await _speak("Guiding you back to the QR path.");
      LatLng lastQrPos = LatLng(
        _qrData[_lastDetectedQrId]['current_location'][0],
        _qrData[_lastDetectedQrId]['current_location'][1],
      );
      if (_currentPosition != null) {
        await _fetchAndSpeakDirections(
          LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          lastQrPos,
        );
      }
    } else {
      await _speak("I didn’t catch that. Please say 'yes' to switch to GPS or 'no' to return to the QR path.");
      _awaitingGpsSwitchResponse = true;
      await _startVoiceInteraction();
    }
  }

  Future<void> _processVoiceCommand(String command) async {
    print("Processing voice command: '$command', AwaitingDestination: $_awaitingDestination, IsNavigating: $_isNavigating, Listening: $_isListening");
    if (command.isEmpty || _isStopping) {
      print("Ignoring command '$command' during stop or empty");
      _stopListening();
      return;
    }

    command = command.toLowerCase().trim();

    if (_awaitingDestination) {
      print("Awaiting destination, handling: '$command'");
      await _handleDestinationCommand(command);
    } else if (_awaitingGpsSwitchResponse) {
      print("Awaiting GPS switch response, handling: '$command'");
      await _handleGpsSwitchResponse(command);
    } else {
      print("Passing to processCommand: '$command'");
      await _processCommand(command);
    }

    // Resume TTS queue if suppressed
    if (_isTtsSuppressed) {
      setState(() => _isTtsSuppressed = false);
      if (_ttsQueue.isNotEmpty && !_isTtsSpeaking) {
        _speakNextInQueue();
      }
      print("TTS suppression lifted after command: ${_ttsQueue.length} items");
    }

    _stopListening();
  }

  Future<void> _startVoiceInteraction() async {
    print("Starting voice interaction, IsNavigating: $_isNavigating");
    if (_speechInitialized && _ttsInitialized) {
      // Stop current TTS and suppress new TTS
      await _flutterTts.stop();
      await _flutterTts.awaitSpeakCompletion(true);
      _isTtsSpeaking = false;
      setState(() => _isTtsSuppressed = true); // Suppress TTS from processes
      print("TTS stopped and suppressed for voice interaction");

      if (_isListening) {
        print("Stopping existing listening session...");
        _stopListening();
        await Future.delayed(const Duration(milliseconds: 200));
      }

      if (_isPorcupineActive) {
        await _porcupineManager?.stop();
        _isPorcupineActive = false;
        print("Porcupine stopped for manual microphone activation");
      }

      await _speak("How may I help you?", priority: true); // Priority to bypass suppression
      await Future.delayed(const Duration(milliseconds: 300));

      _speech.listen(
        onResult: (result) {
          setState(() {
            _recognizedText = result.recognizedWords;
          });
          if (result.finalResult && result.confidence > 0.7) {
            String text = result.recognizedWords.toLowerCase().trim();
            if (text.length > 2) {
              print("Recognized (final): $text, Confidence: ${result.confidence}");
              _processVoiceCommand(text);
            } else {
              print("Short input ignored: $text");
              _stopListening();
            }
          }
        },
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
      );
      setState(() => _isListening = true);
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [0, 200, 100, 200]);
      }

      // Wait for listening to complete
      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 100));
        return _isListening;
      });

      // Resume TTS after interaction
      setState(() => _isTtsSuppressed = false);
      if (_ttsQueue.isNotEmpty && !_isTtsSpeaking) {
        _speakNextInQueue();
      }
      print("TTS suppression lifted, resumed queue: ${_ttsQueue.length} items");
    } else {
      if (!_speechInitialized) {
        await _speak("Speech recognition is not initialized. Please check permissions.");
      }
      if (!_isPorcupineActive) {
        await _restartPorcupine();
      }
    }
  }

  Future<void> _speakNextInQueue() async {
    while (_ttsQueue.isNotEmpty && !_isTtsSpeaking && !_isStopping) {
      _isTtsSpeaking = true;
      String next = _ttsQueue.removeFirst();
      print("Speaking from resumed queue: $next");
      Completer<void> completer = Completer<void>();
      _flutterTts.setCompletionHandler(() {
        print("TTS completed: $next");
        _isTtsSpeaking = false;
        completer.complete();
      });
      _flutterTts.setErrorHandler((msg) {
        print("TTS error: $msg");
        _isTtsSpeaking = false;
        completer.completeError(Exception(msg));
      });
      await _flutterTts.speak(next);
      await completer.future.catchError((e) => print("TTS failed: $e"));
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> _processCommand(String command) async {
    final locationCommands = [
      'where am i',
      'location',
      'my position',
      'where am i at',
      'where’s my location',
      'tell me my location',
      'what’s my position',
      'where am i now',
      'current location',
      'my current position',
      'where am i standing',
      'give me my location',
    ];
    final destCommands = [
      'set destination',
      'i want to go to',
      'go to',
      'navigate to',
      'take me to',
      'head to',
      'direct me to',
      'guide me to',
      'bring me to',
      'set my destination to',
      'i’d like to go to',
      'travel to',
      'point me to',
    ];
    final stopCommands = [
      'stop navigation',
      'end navigation',
      'stop',
      'quit navigation',
      'cancel navigation',
      'halt navigation',
      'stop guiding',
      'end trip',
      'cease navigation',
      'pause navigation',
      'finish navigation',
      'stop directions',
    ];
    final objectCommands = [
      'what is in front of me',
      'what’s in front of me',
      'what’s ahead of me',
      'what is ahead',
      'what’s up ahead',
      'tell me what’s in front',
      'what objects are in front',
      'what’s blocking me',
      'what’s in my way',
      'what do i see ahead',
      'what’s out there',
      'list objects in front',
    ];

    if (locationCommands.any((cmd) => command.contains(cmd))) {
      print("Matched location command: '$command'");
      await _handleWhereAmI();
    } else if (destCommands.any((cmd) => command.contains(cmd))) {
      print("Matched destination command: '$command'");
      String dest = command.replaceAll(RegExp(destCommands.join('|'), caseSensitive: false), '').trim();
      if (dest.isNotEmpty) {
        await _handleDestinationCommand(dest);
      } else {
        await _speak("Where to? Say a place like 'Library' or 'Cafeteria.'");
        _awaitingDestination = true;
      }
    } else if (_isNavigating && stopCommands.any((cmd) => command.contains(cmd))) {
      print("Matched stop command: '$command'");
      await _stopNavigation();
      await _speak("Navigation stopped.");
    } else if (objectCommands.any((cmd) => command.contains(cmd))) {
      print("Matched object command: '$command'");
      if (_detectedObjects.isNotEmpty) {
        await _speak("${_detectedObjects.join(", ")} detected");
      } else {
        await _speak("No objects detected in front of you.");
      }
    } else {
      print("Unrecognized command: '$command'");
      await _speak("I didn’t understand that. Please try again with commands like 'where am I', 'set destination to Library', or 'what is in front of me'.");
    }
    setState(() => _recognizedText = '');
  }

  Future<void> _handleWhereAmI() async {
    if (_currentPosition != null) {
      LatLng current = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
      String nearestLandmark = _findNearestLandmark(current);
      if (nearestLandmark.isNotEmpty) {
        await _speak("You are near $nearestLandmark.");
      } else {
        await _speak("You are at latitude ${_currentPosition!.latitude.toStringAsFixed(4)}, "
            "longitude ${_currentPosition!.longitude.toStringAsFixed(4)}.");
      }
    } else {
      await _speak("I can’t determine your location yet. Please wait.");
      await _fetchCurrentLocation();
    }
  }

  String _findNearestLandmark(LatLng position) {
    const double proximityThreshold = 50;
    String nearest = '';
    double minDistance = double.infinity;

    _qrData.forEach((qrId, qrInfo) {
      LatLng qrPosition = LatLng(qrInfo['current_location'][0], qrInfo['current_location'][1]);
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        qrPosition.latitude,
        qrPosition.longitude,
      );
      if (distance < proximityThreshold && distance < minDistance) {
        minDistance = distance;
        nearest = qrInfo['name'];
      }
    });
    return nearest;
  }

  String _findNearestQr(LatLng position) {
    String nearestQrId = _qrData.keys.first;
    double minDistance = double.infinity;
    for (String qrId in _qrData.keys) {
      LatLng qrPos = LatLng(_qrData[qrId]['current_location'][0], _qrData[qrId]['current_location'][1]);
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        qrPos.latitude,
        qrPos.longitude,
      );
      if (distance < minDistance) {
        minDistance = distance;
        nearestQrId = qrId;
      }
    }
    return nearestQrId;
  }

  Future<void> _handleDestinationCommand(String destination) async {
    print("Handling destination command: '$destination', IsNavigating: $_isNavigating, IsStopping: $_isStopping");
    _awaitingDestination = false;

    if (destination.contains('nearest qr code')) {
      LatLng? currentPos = _currentPosition != null
          ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
          : null;
      String nearestQr = currentPos != null ? _findNearestQr(currentPos) : '';
      if (nearestQr.isNotEmpty) {
        await _setDestination(qrId: nearestQr);
        await _speak("Destination set to nearest QR code: ${_qrData[nearestQr]['name']}");
      } else {
        await _speak("No nearby QR codes found or location unavailable. Please specify a destination or enable GPS.");
        _awaitingDestination = true;
      }
      return;
    }

    String normalizedInput = destination.toLowerCase().trim();
    String? matchedQrId;

    _qrData.forEach((qrId, qrInfo) {
      String qrName = qrInfo['name'].toLowerCase();
      if (normalizedInput.contains(qrName)) {
        matchedQrId = qrId;
      }
    });

    if (matchedQrId != null) {
      print("Setting destination to QR ID: $matchedQrId");
      await _setDestination(qrId: matchedQrId);
      await _speak("Destination set to ${_qrData[matchedQrId]['name']}. Follow the QR path.");
    } else {
      await _speak("Destination not found. Please press the microphone button and try again with a valid location, like 'Library' or 'Cafeteria.'");
      _awaitingDestination = true;
    }
  }

  Future<void> _speak(String text, {bool priority = false}) async {
    print("Speaking: $text, Priority: $priority, TTS Initialized: $_ttsInitialized, Speaking: $_isTtsSpeaking, Queue: ${_ttsQueue.length}, Suppressed: $_isTtsSuppressed");
    if (!_ttsInitialized) {
      print("TTS not initialized, queuing: $text");
      _ttsQueue.add(text);
      return;
    }

    // Ignore TTS if suppressed, unless it’s the voice interaction prompt or response
    if (_isTtsSuppressed && !priority) {
      print("TTS suppressed, queuing non-priority: $text");
      _ttsQueue.add(text); // Still queue it for later
      return;
    }

    // Block non-priority destination messages if not navigating
    if (!priority && !_isNavigating && text.contains("Destination set to")) {
      print("Ignoring outdated destination message: $text (not navigating)");
      return;
    }

    if (_isStopping && !priority) {
      print("Ignoring non-priority speech '$text' during navigation stop");
      return;
    }

    if (priority && _isTtsSpeaking) {
      await _flutterTts.stop();
      if (_ttsQueue.isNotEmpty) {
        _interruptedText = _ttsQueue.removeFirst();
        _interruptedProgress = 0.0;
        print("Interrupted TTS: $_interruptedText");
      }
      _isTtsSpeaking = false;
    } else if (!priority && _isTtsSpeaking) {
      _ttsQueue.add(text);
      print("TTS busy, queued: $text");
      return;
    }

    if (priority) {
      _ttsQueue.clear();
      _isTtsSpeaking = true;
      Completer<void> completer = Completer<void>();
      _flutterTts.setCompletionHandler(() {
        print("TTS completed: $text");
        _isTtsSpeaking = false;
        completer.complete();
        if (_interruptedText != null) {
          print("Resuming: $_interruptedText");
          _speak(_interruptedText!);
          _interruptedText = null;
          _interruptedProgress = null;
        }
      });
      _flutterTts.setErrorHandler((msg) {
        print("TTS error: $msg");
        _isTtsSpeaking = false;
        completer.completeError(Exception(msg));
      });
      await _flutterTts.speak(text);
      await completer.future.catchError((e) => print("TTS failed: $e"));
    } else {
      _ttsQueue.add(text);
      while (_ttsQueue.isNotEmpty && !_isTtsSpeaking && !_isStopping) {
        _isTtsSpeaking = true;
        String next = _ttsQueue.removeFirst();
        print("Speaking from queue: $next");
        Completer<void> completer = Completer<void>();
        _flutterTts.setCompletionHandler(() {
          print("TTS completed: $next");
          _isTtsSpeaking = false;
          completer.complete();
        });
        _flutterTts.setErrorHandler((msg) {
          print("TTS error: $msg");
          _isTtsSpeaking = false;
          completer.completeError(Exception(msg));
        });
        await _flutterTts.speak(next);
        await completer.future.catchError((e) => print("TTS failed: $e"));
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Future<void> _loadQrData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final firestore = FirebaseFirestore.instance;

      // Fetch from Firestore
      QuerySnapshot snapshot = await firestore.collection('qr_codes').get();
      Map<String, dynamic> cloudData = {};
      for (var doc in snapshot.docs) {
        var data = doc.data() as Map<String, dynamic>;
        cloudData[doc['id']] = {
          'name': data['name'] ?? '',
          'current_location': (data['current_location'] is List)
              ? List<double>.from(data['current_location'].map((e) => e is num ? e.toDouble() : 0.0))
              : [0.0, 0.0],
          'context': data['context'] ?? '',
          'neighbours': data['neighbours'] ?? [],
        };
      }
      print('Loaded from Firestore: $cloudData'); // Debug: Confirm cloud data

      // Load local data
      String? savedQrData = prefs.getString('qrData');
      Map<String, dynamic> localData = savedQrData != null ? jsonDecode(savedQrData) : {};
      print('Loaded from SharedPreferences: $localData'); // Debug: Confirm local data

      // Compare and update if different
      if (!_areMapsEqual(localData, cloudData)) {
        setState(() {
          _qrData = cloudData;
        });
        await prefs.setString('qrData', jsonEncode(_qrData));
        buildQrGraph();
        await _speak("QR data updated from cloud.");
        print('Synced _qrData with cloud: $_qrData');
      } else {
        setState(() {
          _qrData = localData.isNotEmpty ? localData : cloudData;
        });
        buildQrGraph();
        print('Using existing _qrData: $_qrData');
      }
    } catch (e) {
      print('Error loading QR data from cloud: $e');
      await _speak("Failed to load QR data from cloud. Using local data if available.");
      final prefs = await SharedPreferences.getInstance();
      String? savedQrData = prefs.getString('qrData');
      if (savedQrData != null) {
        setState(() {
          _qrData = jsonDecode(savedQrData);
          buildQrGraph();
        });
        print('Fallback to local data: $_qrData');
      } else {
        String jsonString = await rootBundle.loadString('assets/qrdata.json');
        setState(() {
          _qrData = jsonDecode(jsonString);
          buildQrGraph();
        });
        await prefs.setString('qrData', jsonString);
        print('Fallback to asset data: $_qrData');
      }
    }
  }

  bool _areMapsEqual(Map<String, dynamic> local, Map<String, dynamic> cloud) {
    if (local.length != cloud.length) return false;
    for (String key in local.keys) {
      if (!cloud.containsKey(key)) return false;
      var localVal = local[key];
      var cloudVal = cloud[key];
      if (localVal['name'] != cloudVal['name'] ||
          !listEquals(localVal['current_location'], cloudVal['current_location']) ||
          localVal['context'] != cloudVal['context'] ||
          !listEquals(localVal['neighbours'], cloudVal['neighbours'])) {
        return false;
      }
    }
    return true;
  }

  void buildQrGraph() {
    qrGraph.clear();
    _qrData.forEach((key, value) {
      qrGraph[key] = List<String>.from(value['neighbours']);
    });
  }

  List<String> findShortestPath(String start, String end) {
    Map<String, double> distances = {};
    Map<String, String?> previous = {};
    Set<String> unvisited = {};

    _qrData.forEach((qrId, _) {
      distances[qrId] = double.infinity;
      previous[qrId] = null;
      unvisited.add(qrId);
    });

    distances[start] = 0;

    while (unvisited.isNotEmpty) {
      String current = unvisited.reduce((a, b) => distances[a]! < distances[b]! ? a : b);

      if (current == end) break;

      unvisited.remove(current);

      for (String neighbor in qrGraph[current] ?? []) {
        if (!unvisited.contains(neighbor)) continue;

        LatLng currentPos = LatLng(_qrData[current]['current_location'][0], _qrData[current]['current_location'][1]);
        LatLng neighborPos = LatLng(_qrData[neighbor]['current_location'][0], _qrData[neighbor]['current_location'][1]);
        double distance = Geolocator.distanceBetween(
          currentPos.latitude,
          currentPos.longitude,
          neighborPos.latitude,
          neighborPos.longitude,
        );

        double alt = distances[current]! + distance;
        if (alt < distances[neighbor]!) {
          distances[neighbor] = alt;
          previous[neighbor] = current;
        }
      }
    }

    List<String> path = [];
    String? u = end;
    while (u != null) {
      path.insert(0, u);
      u = previous[u];
    }

    return path.first == start ? path : [];
  }

  void _startDistanceUpdates() {
    _distanceTimer?.cancel(); // Cancel any existing timer
    _distanceTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (!_isStopping) { // Avoid running during navigation stop
        await _fetchDistance();
      }
    });
    print("Started distance updates every 500ms");
  }

  // Add this method to your class to fetch the IP address
  Future<String> _getServerIp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('server_ip') ?? '192.168.11.92'; // Default IP if none saved
  }

  Future<void> _fetchDistance() async {
    try {
      final serverIp = await _getServerIp();
      final response = await http.get(Uri.parse('http://$serverIp:5000/data'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('Raw JSON from Pi: ${response.body}');

        double? newDistance = (data['distance_cm'] as num?)?.toDouble();
        List<String> newDetectedObjects = (data['objects'] as List?)
            ?.map((obj) => (obj['object'] as String?) ?? 'Unknown')
            .toList() ?? [];
        bool motionDetected = data['motion']?['detected'] as bool? ?? false;
        String motionDirection = data['motion']?['direction'] as String? ?? '';
        String movingObjectName = data['motion']?['moving_object'] is Map
            ? (data['motion']['moving_object']['object'] as String? ?? 'unknown object')
            : 'no moving object';
        List<int> motionCentroid = (data['motion']?['centroid'] as List?)
            ?.map((e) => e as int)
            .toList() ?? [0, 0];

        setState(() {
          _distanceFromSensor = newDistance;
          _detectedObjects = newDetectedObjects;
          _motionDetected = motionDetected;
          _motionDirection = motionDirection;
          _movingObjectName = movingObjectName;
          _motionCentroid = motionCentroid;
        });

        // Motion announcement...
        if (_motionDetected && _motionDirection.isNotEmpty && _motionDirection.toLowerCase() != 'stationary') {
          final now = DateTime.now();
          const Duration motionDebounceDuration = Duration(seconds: 6);
          if (!_isMotionAnnouncementInProgress &&
              (_lastMotionAnnouncement == null || now.difference(_lastMotionAnnouncement!) >= motionDebounceDuration)) {
            String? selectedObject;
            final priorityOrder = ['truck', 'car', 'bike', 'bicycle', 'person'];
            for (String priority in priorityOrder) {
              if (_detectedObjects.contains(priority)) {
                selectedObject = priority;
                break;
              }
            }

            String motionText;
            if (selectedObject != null) {
              motionText = "$selectedObject detected moving $_motionDirection";
            } else if (_movingObjectName != 'no moving object') {
              motionText = "$_movingObjectName detected moving $_motionDirection";
            } else {
              motionText = "unknown object moving $_motionDirection";
            }

            setState(() => _isMotionAnnouncementInProgress = true);
            await _speak(motionText, priority: true);
            setState(() {
              _isMotionAnnouncementInProgress = false;
              _lastMotionAnnouncement = now;
            });
          }
        }

        // Obstacle detection...
        final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
        bool isBelowThreshold = _distanceFromSensor != null && _distanceFromSensor! < themeProvider.distanceThreshold;

        // Vibration with debounce
        if (isBelowThreshold && await Vibration.hasVibrator()) {
          final now = DateTime.now();
          const int vibrationInterval = 1000; // 2 seconds between vibrations
          if (_lastVibrationTime == null || now.difference(_lastVibrationTime!) >= Duration(milliseconds: vibrationInterval)) {
            Vibration.vibrate(duration: themeProvider.vibrationDuration);
            _lastVibrationTime = now;
          }
        }

        // Priority object announcement
        if (isBelowThreshold && !_isTtsSpeaking && !_isNavigating) {
          bool shouldAnnounce = !_lastAnnouncedBelowThreshold ||
              (_lastObjectAnnouncementTime != null &&
                  DateTime.now().difference(_lastObjectAnnouncementTime!).inSeconds >= themeProvider.announcementInterval);
          if (shouldAnnounce) {
            // Filter for priority objects only
            List<String> priorityObjects = _detectedObjects.where((obj) {
              String objLower = obj.toLowerCase();
              return [
                'person',
                'car',
                'truck',
                'bus',
                'bike',
                'bicycle',
                'motorbike'
              ].contains(objLower);
            }).toList();

            if (priorityObjects.isNotEmpty) {
              String text = "${priorityObjects.join(", ")} detected";
              await _speak(text);
              _lastObjectAnnouncementTime = DateTime.now();
              _lastAnnouncedBelowThreshold = true;
            }
          }
        } else if (!isBelowThreshold) {
          _lastAnnouncedBelowThreshold = false;
        }

        // QR handling...
        if (data['qr_codes'] != null && (data['qr_codes'] as List).isNotEmpty) {
          for (var qr in data['qr_codes']) {
            if (qr['type'] == "TripuraUni" && _lastDetectedQrId != qr['qid']) {
              setState(() {
                _qrDetected = true;
                _lastDetectedQrId = qr['qid'];
              });
              await handleQRScan(qr['qid']);
            }
          }
        }
      }
    } catch (e) {
      print('Error fetching distance: $e');
      setState(() => _isMotionAnnouncementInProgress = false);
    }
  }

  Future<BitmapDescriptor> _resizeMarker(String assetPath, int targetWidth) async {
    ByteData data = await rootBundle.load(assetPath);
    Uint8List bytes = data.buffer.asUint8List();

    ui.Codec codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
    ui.FrameInfo fi = await codec.getNextFrame();
    ByteData? resizedData = await fi.image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.fromBytes(resizedData!.buffer.asUint8List());
  }

  Future<void> _setCustomMarkers() async {
    try {
      qrPinIcon = await _resizeMarker('assets/qrpin.png', 40);
      destinationIcon = await _resizeMarker('assets/blue_marker.png', 40);
    } catch (e) {
      print("Error loading markers: $e");
      qrPinIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
      destinationIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    }
  }

  void updateNavigationMode() {
    if (_destinationQrId != null && _isNavigating) {
      if (_lastDetectedQrId != null) {
        _useQRNavigation(_lastDetectedQrId!);
      } else if (_currentPosition != null) {
        String nearestQr = _findNearestQr(LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
        if (nearestQr.isNotEmpty) {
          _speak("No recent QR detected. Guiding you to the nearest QR: ${_qrData[nearestQr]['name']}.");
          _fetchAndSpeakDirections(
            LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            LatLng(_qrData[nearestQr]['current_location'][0], _qrData[nearestQr]['current_location'][1]),
          );
        } else {
          _speak("No QR codes found nearby. Please scan a QR code to start navigation.");
        }
      } else {
        _speak("Please scan a QR code or enable GPS to start QR-based navigation.");
      }
    } else if (_currentPosition != null && _isNavigating) {
      _useGPSNavigation(_currentPosition!);
    } else {
      _speak("No location data available. Please scan a QR code or enable GPS.");
    }
  }

  Future<void> handleQRScan(String scannedQr) async {
    if (!_qrData.containsKey(scannedQr)) {
      await _speak("Invalid QR code. Please scan a valid navigation QR.");
      return;
    }

    if (scannedQr == _lastDetectedQrId && _qrDetected) {
      return;
    }

    setState(() {
      _lastDetectedQrId = scannedQr;
      _qrDetected = true;
    });

    _initialQrPosition = LatLng(
      _qrData[scannedQr]['current_location'][0],
      _qrData[scannedQr]['current_location'][1],
    );

    await _speak(_qrData[scannedQr]['context']);

    if (_isNavigating && _destinationQrId != null) {
      List<String> path = findShortestPath(scannedQr, _destinationQrId!);
      if (path.isNotEmpty) {
        int currentIndex = path.indexOf(scannedQr);
        if (currentIndex == path.length - 1) {
          await _speak("${_qrData[scannedQr]['name']} reached");
          await _stopNavigation();
        } else if (currentIndex < 0) {
          await _speak("You are off course. Recalculating path.");
          if (_currentPosition != null) {
            await _fetchAndSpeakDirections(
              LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
              _destination!,
            );
          }
        }
      } else {
        await _speak("You are off course. Switching to GPS navigation.");
        if (_currentPosition != null) {
          await _fetchAndSpeakDirections(
            LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            _destination!,
          );
        }
      }
    } else if (!_isNavigating && !_justStoppedNavigation) { // Check flag
      await _speak("Where would you like to go? Say 'nearest QR code' or a specific destination.");
      _awaitingDestination = true;
    }

    _qrDisplayTimer?.cancel();
    _qrDisplayTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _qrDetected = false);
    });
  }

  void _useQRNavigation(String qrId) {
    if (!_isNavigating) return;
    List<String> path = findShortestPath(qrId, _destinationQrId!);
    if (path.isNotEmpty && path.length > 1) {
      String nextQr = path[1];
      _speak("Proceed to ${_qrData[nextQr]['name']} and scan the QR code.");
    } else {
      _speak("You have arrived at your destination.");
    }
  }

  Future<void> _useGPSNavigation(Position position) async {
    LatLng current = LatLng(position.latitude, position.longitude);
    if (_destination != null) {
      await _fetchAndSpeakDirections(current, _destination!);
    } else {
      _speak("No destination selected.");
    }
  }

  Future<void> handleLocationChange(Position position) async {
    if (_destinationQrId != null && _isNavigating) {
      LatLng currentPos = LatLng(position.latitude, position.longitude);
      bool isOnPath = false;

      // Calculate the current QR route
      String startQrId = _lastDetectedQrId ?? _findNearestQr(currentPos);
      List<String> qrPath = findShortestPath(startQrId, _destinationQrId!);
      List<LatLng> qrRoutePoints = [];
      for (int i = 0; i < qrPath.length - 1; i++) {
        LatLng startPos = LatLng(_qrData[qrPath[i]]['current_location'][0], _qrData[qrPath[i]]['current_location'][1]);
        LatLng endPos = LatLng(_qrData[qrPath[i + 1]]['current_location'][0], _qrData[qrPath[i + 1]]['current_location'][1]);
        var result = await getDirectionsWithSteps(startPos, endPos, apiKey);
        qrRoutePoints.addAll(result['polylinePoints']);
      }

      // Find the minimum distance to the route
      double minDistanceToRoute = double.infinity;
      for (int i = 0; i < qrRoutePoints.length - 1; i++) {
        double distance = _distanceToSegment(currentPos, qrRoutePoints[i], qrRoutePoints[i + 1]);
        if (distance < minDistanceToRoute) {
          minDistanceToRoute = distance;
        }
      }

      // Determine if the user is on-path
      if (minDistanceToRoute < 10.0) { // On-path threshold
        isOnPath = true;
      }

      // Handle off-path scenario
      if (!isOnPath && !_awaitingGpsSwitchResponse) {
        if (minDistanceToRoute > 50.0) { // Off-route threshold
          String nearestQrId = _findNearestQr(currentPos);
          double distanceToNearestQr = Geolocator.distanceBetween(
            currentPos.latitude,
            currentPos.longitude,
            _qrData[nearestQrId]['current_location'][0],
            _qrData[nearestQrId]['current_location'][1],
          );

          if (distanceToNearestQr < 50.0 && qrPath.contains(nearestQrId)) {
            // User is near a QR on the path; recalculate from there
            List<String> newPath = findShortestPath(nearestQrId, _destinationQrId!);
            if (newPath.isNotEmpty) {
              await _speak("You missed a QR code. Recalculating from ${_qrData[nearestQrId]['name']} to your destination.");
              await _navigateThroughQrPath(newPath);
            } else {
              await _speak("No valid QR path from ${_qrData[nearestQrId]['name']}. Switching to GPS navigation.");
              await _fetchAndSpeakDirections(currentPos, _destination!);
            }
          } else {
            // User is too far; prompt for GPS switch
            _awaitingGpsSwitchResponse = true;
            await _speak(
              "You are ${minDistanceToRoute.toStringAsFixed(0)} meters away from the QR path. "
                  "Would you like to switch to GPS navigation? Say 'yes' or 'no'.",
            );
            await _startVoiceInteraction();
          }
        }
      }
    } else if (_isNavigating && _destinationQrId == null) {
      updateNavigationMode();
    }
  }

  void _startLocationUpdates() {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((Position position) {
      if (_isNavigating) {
        _getCurrentLocation(position);
        handleLocationChange(position);
      }
    }, onError: (error) {
      print('Error getting location: $error');
      _speak("Failed to get location updates.");
    });
  }

  void _getCurrentLocation(Position position) {
    if (_currentPosition != null) {
      double distanceMoved = Geolocator.distanceBetween(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      if (distanceMoved < 2) return;
    }

    setState(() {
      _currentPosition = position;
    });

    if (_polylinePoints.isNotEmpty) {
      _updatePolyline(position);
    }

    if (_destination != null && _isNavigating && _destinationQrId == null) {
      if (DateTime.now().difference(_lastDirectionFetch) > _debounceDuration) {
        _fetchAndSpeakDirections(
          LatLng(position.latitude, position.longitude),
          _destination!,
        );
        _lastDirectionFetch = DateTime.now();
      }
    }

    _provideContextualInfo(position);
  }

  void _updatePolyline(Position position) {
    LatLng currentLocation = LatLng(position.latitude, position.longitude);
    if (_polylinePoints.isEmpty) return;

    double minDistance = double.infinity;
    int closestIndex = -1;

    for (int i = 0; i < _polylinePoints.length - 1; i++) {
      double distance = _distanceToSegment(currentLocation, _polylinePoints[i], _polylinePoints[i + 1]);
      if (distance < minDistance) {
        minDistance = distance;
        closestIndex = i;
      }
    }

    if (closestIndex != -1 && minDistance < 20) {
      _polylinePoints = _polylinePoints.sublist(closestIndex);
    }

    setState(() {
      _polylines.clear();
      _polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        points: _polylinePoints,
        color: _destinationQrId != null ? Colors.green : Colors.blue,
        width: 5,
      ));
    });
  }

  double _distanceToSegment(LatLng point, LatLng start, LatLng end) {
    double A = point.latitude - start.latitude;
    double B = point.longitude - start.longitude;
    double C = end.latitude - start.latitude;
    double D = end.longitude - start.longitude;

    double dot = A * C + B * D;
    double lenSq = C * C + D * D;
    double param = (lenSq != 0) ? dot / lenSq : -1;

    double xx, yy;
    if (param < 0) {
      xx = start.latitude;
      yy = start.longitude;
    } else if (param > 1) {
      xx = end.latitude;
      yy = end.longitude;
    } else {
      xx = start.latitude + param * C;
      yy = start.longitude + param * D;
    }

    double dx = point.latitude - xx;
    double dy = point.longitude - yy;
    return Geolocator.distanceBetween(point.latitude, point.longitude, xx, yy);
  }

  void _provideContextualInfo(Position position) {
    const double proximityThreshold = 10;
    if (_isTtsSpeaking || _isNavigating) return;

    _qrData.forEach((qrId, qrInfo) {
      LatLng qrPosition = LatLng(qrInfo['current_location'][0], qrInfo['current_location'][1]);
      double distanceToQr = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        qrPosition.latitude,
        qrPosition.longitude,
      );

      if (distanceToQr < proximityThreshold && qrId != _lastDetectedQrId && !_visitedLandmarks.contains(qrInfo['name'])) {
        _visitedLandmarks.add(qrInfo['name']);
        _speak("You are near ${qrInfo['name']}.");
        print("Announced QR Location: ${qrInfo['name']}");
      }
    });
  }

  Future<void> _fetchCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _visitedLandmarks.clear();
      _getCurrentLocation(position);

      if (_mapController != null) {
        _mapController!.animateCamera(CameraUpdate.newLatLng(LatLng(position.latitude, position.longitude)));
      }
      if (_isNavigating) {
        _provideContextualInfo(position);
      }
    } catch (e) {
      print('Error getting current location: $e');
      _speak("Failed to get your current location.");
    }
  }

  @override
  void dispose() {
    _compassSubscription?.cancel();
    _locationTimer?.cancel();
    _distanceTimer?.cancel();
    _qrDisplayTimer?.cancel();
    _stopListening();
    _porcupineManager?.stop();
    _porcupineManager?.delete();
    _isPorcupineActive = false;
    qrDataChangedNotifier.removeListener(_reloadQrData);
    super.dispose();
  }

  Future<void> _fetchAndSpeakDirections(LatLng start, LatLng end, {List<String>? qrPath}) async {
    if (!_isNavigating) return;

    final cacheKey = '${start.latitude},${start.longitude}-${end.latitude},${end.longitude}';
    Map<String, dynamic> result;

    try {
      if (_directionsCache.containsKey(cacheKey)) {
        result = _directionsCache[cacheKey]!;
        print("Using cached directions for $cacheKey");
      } else {
        result = await getDirectionsWithSteps(start, end, apiKey);
        _directionsCache[cacheKey] = result;
        print("Directions fetched and cached for $cacheKey");
      }

      if (!_isNavigating) return;

      final List<String> directions = result['directions'] ?? [];
      final List<LatLng> polylinePoints = result['polylinePoints'] ?? [];

      setState(() {
        _polylinePoints = polylinePoints;
        _polylines.clear();
        _polylines.add(Polyline(
          polylineId: const PolylineId('route'),
          points: _polylinePoints,
          color: _destinationQrId != null ? Colors.green : Colors.blue,
          width: 5,
        ));
      });

      await _speak("Starting navigation to your destination.");
      await _startPathNavigation(directions: directions, qrPath: qrPath);
    } catch (e) {
      print('Error fetching directions: $e');
      if (_isNavigating && !_isTtsSpeaking) {
        await _speak("Failed to get directions. Please try again.");
      }
    }
  }

  String _refineDirection(String direction) {
    String cleanedText = direction.replaceAll(RegExp(r'<[^>]*>|[\[\]\(\)]'), '').trim();
    RegExp turnRegex = RegExp(r'(turn|head|merge|continue|exit|left|right|roundabout)', caseSensitive: false);
    RegExp distanceRegex = RegExp(r'in\s+([\d.,]+)\s*(miles|kilometers|meters|feet|yards)?', caseSensitive: false);
    RegExp streetRegex = RegExp(r'(?:onto|on|to|toward|at)\s+([^\s,]+(?:[\s-][^\s,]+)*)', caseSensitive: false);

    String turn = turnRegex.firstMatch(cleanedText)?.group(0)?.toLowerCase() ?? 'proceed';
    String? distance = distanceRegex.firstMatch(cleanedText)?.group(1);
    String? units = distanceRegex.firstMatch(cleanedText)?.group(2) ?? 'meters';
    String? street = streetRegex.firstMatch(cleanedText)?.group(1)?.trim();

    String refined = "$turn";
    if (street != null) refined += " onto $street";
    if (distance != null && turn != "continue") refined += " in $distance $units";
    return refined;
  }

  Future<void> _stopNavigation({bool silent = false}) async {
    if (_isNavigating && !_isStopping) {
      _isStopping = true;
      print("Stopping navigation: Clearing state...");
      _isNavigating = false;
      if (_isListening) {
        print("Stopping active listening...");
        _stopListening();
      }

      // Stop TTS and ensure it’s fully stopped
      await _flutterTts.stop();
      await _flutterTts.awaitSpeakCompletion(true);
      _ttsQueue.clear();
      _isTtsSpeaking = false;

      // Reset state
      setState(() {
        _polylines.clear();
        _markers.removeWhere((marker) => marker.markerId.value == 'destination');
        _destination = null;
        _destinationQrId = null;
        _directionsCache.clear();
        _polylinePoints.clear();
        _lastDetectedQrId = null;
        _qrDetected = false;
      });
      _awaitingDestination = false;
      _awaitingGpsSwitchResponse = false;

      // Announce stop as priority
      if (!silent) {
        print("Queueing stop announcement...");
        await _speak("Navigation has been stopped.", priority: true);
      }

      print("Navigation stopped${silent ? ' silently' : ''}. AwaitingDestination: $_awaitingDestination, Listening: $_isListening");
      await Future.delayed(const Duration(seconds: 1));
      _restartPorcupine();
      _isStopping = false; // Move this after Porcupine restart
    }
  }

  Future<Map<String, dynamic>> getDirectionsWithSteps(LatLng start, LatLng end, String apiKey) async {
    final url = 'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${start.latitude},${start.longitude}'
        '&destination=${end.latitude},${end.longitude}'
        '&key=$apiKey';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data == null || !data.containsKey('routes') || data['routes'].isEmpty) {
          throw Exception('No valid routes found');
        }

        final steps = <String>[];
        final polylinePoints = <LatLng>[];
        final routes = data['routes'];
        final legs = routes[0]['legs'];

        if (legs.isEmpty) {
          throw Exception('Route data is incomplete');
        }

        final stepsData = legs[0]['steps'];
        for (var step in stepsData) {
          if (step.containsKey('html_instructions')) {
            steps.add(_cleanHtmlTags(step['html_instructions']));
          }
          if (step.containsKey('polyline')) {
            String polyline = step['polyline']['points'];
            PolylinePoints polylinePointsDecoder = PolylinePoints();
            List<PointLatLng> points = polylinePointsDecoder.decodePolyline(polyline);
            polylinePoints.addAll(points.map((point) => LatLng(point.latitude, point.longitude)));
          }
        }

        return {'directions': steps, 'polylinePoints': polylinePoints};
      } else {
        throw Exception('Failed to load directions (HTTP ${response.statusCode})');
      }
    } catch (e) {
      print('Exception in getDirectionsWithSteps: $e');
      return {'directions': [], 'polylinePoints': []};
    }
  }

  String _cleanHtmlTags(String html) {
    String cleanedHtml = html.replaceAll(RegExp(r'<[^>]*>'), '');
    cleanedHtml = cleanedHtml.replaceAll(RegExp(r'\(.*?\)'), '');
    cleanedHtml = cleanedHtml.replaceAll(RegExp(r'\[.*?\]'), '');
    return cleanedHtml.trim();
  }

  void _addMarkers() {
    setState(() {
      _markers.clear();
      print('Cleared markers, rebuilding from _qrData: ${_qrData.length} entries');
      _qrData.forEach((qrId, qrInfo) {
        try {
          final position = LatLng(
            qrInfo['current_location'][0] as double,
            qrInfo['current_location'][1] as double,
          );
          _markers.add(
            Marker(
              markerId: MarkerId(qrId),
              position: position,
              infoWindow: InfoWindow(
                title: qrInfo['name'] as String? ?? qrId,
                snippet: qrInfo['context'] as String?,
              ),
              icon: qrPinIcon,
            ),
          );
          print('Added marker: $qrId at $position');
        } catch (e) {
          print('Error adding marker $qrId: $e');
        }
      });
      print('Total markers rebuilt: ${_markers.length}');
    });
  }

  Future<void> _setDestination({LatLng? gpsDestination, String? qrId, bool useGps = false}) async {
    await _flutterTts.stop();

    LatLng? start;
    String? startQrId;

    setState(() {
      _polylines.clear();
      _markers.removeWhere((marker) => marker.markerId.value == 'destination');

      if (qrId != null && _qrData.containsKey(qrId) && !useGps) {
        _destinationQrId = qrId;
        _destination = LatLng(
          _qrData[qrId]['current_location'][0],
          _qrData[qrId]['current_location'][1],
        );
      } else if (gpsDestination != null) {
        _destinationQrId = null;
        _destination = gpsDestination;
        _markers.add(
          Marker(
            markerId: const MarkerId('destination'),
            position: gpsDestination,
            infoWindow: const InfoWindow(title: 'Destination'),
            icon: destinationIcon,
          ),
        );
      }

      if (_currentPosition != null) {
        start = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
        if (_lastDetectedQrId != null && _qrData.containsKey(_lastDetectedQrId) && qrId != null && !useGps) {
          startQrId = _lastDetectedQrId;
          start = LatLng(
            _qrData[startQrId]['current_location'][0],
            _qrData[startQrId]['current_location'][1],
          );
        } else if (qrId != null && !useGps) {
          startQrId = _findNearestQr(start!);
        }
      } else if (_initialQrPosition != null && qrId != null && !useGps) {
        start = _initialQrPosition!;
        startQrId = _findNearestQr(start!);
      }

      _isNavigating = true;
    });

    if (start == null) {
      await _speak("No location available. Please enable GPS or scan a QR code to start navigation.");
      _isNavigating = false;
      return;
    }

    if (qrId != null && _qrData.containsKey(qrId) && !useGps) {
      if (startQrId != null) {
        await _speak("Navigating to ${_qrData[qrId]['name']} via QR path from ${_qrData[startQrId]['name']}.");
        List<String> qrPath = findShortestPath(startQrId!, qrId);
        if (qrPath.isNotEmpty) {
          await _navigateThroughQrPath(qrPath);
        } else {
          await _speak("No QR path found. Using GPS to navigate to ${_qrData[qrId]['name']}.");
          await _fetchAndSpeakDirections(start!, _destination!);
        }
      } else {
        await _speak("No recent QR detected. Guiding to the nearest QR to start navigation to ${_qrData[qrId]['name']}.");
        String nearestQr = _findNearestQr(start!);
        await _fetchAndSpeakDirections(
          start!,
          LatLng(_qrData[nearestQr]['current_location'][0], _qrData[nearestQr]['current_location'][1]),
        );
      }
    } else if (gpsDestination != null || useGps) {
      await _speak("Navigating to your selected location.");
      await _fetchAndSpeakDirections(start!, _destination!);
    }
  }

  Future<void> _announceQrPath(List<String> qrPath) async {
    if (qrPath.isEmpty) return;

    String pathAnnouncement = "To reach your destination, you will pass through the following QR codes: ";
    for (int i = 0; i < qrPath.length; i++) {
      String qrName = _qrData[qrPath[i]]['name'];
      pathAnnouncement += qrName;
      if (i < qrPath.length - 1) {
        pathAnnouncement += ", ";
      }
    }
    pathAnnouncement += ". Please follow the QR path.";
    await _speak(pathAnnouncement);
  }

  Future<void> _navigateThroughQrPath(List<String> qrPath) async {
    if (qrPath.length <= 1) {
      await _speak("You have reached your destination: ${_qrData[qrPath.last]['name']}.");
      await _stopNavigation();
      return;
    }

    // Set up QR waypoints for visualization
    List<LatLng> pathPoints = qrPath.map((qrId) => LatLng(
        _qrData[qrId]['current_location'][0],
        _qrData[qrId]['current_location'][1])).toList();

    setState(() {
      _polylines.clear();
      _polylinePoints = pathPoints;
      _polylines.add(Polyline(
        polylineId: const PolylineId('qr_route'),
        points: _polylinePoints,
        color: Colors.green,
        width: 5,
      ));

      // Clear old QR markers and add new ones
      _markers.removeWhere((marker) => marker.markerId.value.startsWith('qr_'));
      for (String qrId in qrPath) {
        LatLng qrPos = LatLng(_qrData[qrId]['current_location'][0], _qrData[qrId]['current_location'][1]);
        _markers.add(Marker(
          markerId: MarkerId('qr_$qrId'),
          position: qrPos,
          infoWindow: InfoWindow(title: _qrData[qrId]['name']),
          icon: qrPinIcon,
        ));
      }
    });

    // Start or update navigation with the new QR path
    await _startPathNavigation(qrPath: qrPath);
  }

  Future<void> _startPathNavigation({List<String>? directions, List<String>? qrPath}) async {
    if ((qrPath == null || qrPath.isEmpty) && (directions == null || directions.isEmpty)) {
      await _speak("No valid path available. Please set a destination.");
      return;
    }

    if (qrPath != null && qrPath.isNotEmpty) {
      await _announceQrPath(qrPath);
    }

    StreamSubscription<Position>? positionStream;
    DateTime lastAnnouncement = DateTime.now().subtract(const Duration(seconds: 2));
    int currentStepIndex = 0;
    const double waypointThreshold = 5.0; // Distance for deemed QR scanned in meters
    const double finalThreshold = 20.0; // Increased for GPS reliability
    const double proximityThreshold = 30.0; // Announce if lingering near destination
    const double headingTolerance = 45.0;
    const int updateInterval = 4; // Navigation announcement interval in seconds
    String? lastDirectionText; // Track the previous direction
    DateTime? proximityAnnounced; // Track proximity announcement

    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1,
      ),
    ).listen((Position position) async {
      if (!_isNavigating) {
        print('Navigation stopped: _isNavigating is false');
        await _speak("Navigation interrupted.", priority: true);
        positionStream?.cancel();
        return;
      }

      _getCurrentLocation(position);
      LatLng currentPos = LatLng(position.latitude, position.longitude);

      _provideContextualInfo(position);

      List<LatLng> waypoints = qrPath != null && qrPath.isNotEmpty
          ? qrPath.map((qrId) => LatLng(
          _qrData[qrId]['current_location'][0],
          _qrData[qrId]['current_location'][1])).toList()
          : _polylinePoints;

      if (waypoints.isEmpty) {
        print('Navigation stopped: Empty waypoints');
        await _speak("Route data is missing. Navigation stopped.", priority: true);
        await _stopNavigation(silent: true);
        positionStream?.cancel();
        return;
      }

      // Check if off-path and recalculate if necessary, but skip for final QR
      if (qrPath != null && qrPath.isNotEmpty && currentStepIndex < qrPath.length - 1) {
        double minDistanceToPath = double.infinity;
        for (int i = 0; i < waypoints.length - 1; i++) {
          double distance = _distanceToSegment(currentPos, waypoints[i], waypoints[i + 1]);
          if (distance < minDistanceToPath) {
            minDistanceToPath = distance;
          }
        }

        if (minDistanceToPath > 20.0) {
          String nearestQrId = _findNearestQr(currentPos);
          double distanceToNearestQr = Geolocator.distanceBetween(
            currentPos.latitude,
            currentPos.longitude,
            _qrData[nearestQrId]['current_location'][0],
            _qrData[nearestQrId]['current_location'][1],
          );

          if (distanceToNearestQr < 50.0 && !qrPath.contains(nearestQrId)) {
            List<String> newPath = findShortestPath(nearestQrId, _destinationQrId!);
            if (newPath.isNotEmpty && newPath != qrPath) {
              await _speak("You’re off course. Recalculating from ${_qrData[nearestQrId]['name']}.", priority: true);
              positionStream?.cancel();
              await _navigateThroughQrPath(newPath);
              return;
            }
          }
        }
      }

      double distanceToNextWaypoint = Geolocator.distanceBetween(
        currentPos.latitude,
        currentPos.longitude,
        waypoints[currentStepIndex].latitude,
        waypoints[currentStepIndex].longitude,
      );

      double? heading = _userHeading;
      double bearingToNext = Geolocator.bearingBetween(
        currentPos.latitude,
        currentPos.longitude,
        waypoints[currentStepIndex].latitude,
        waypoints[currentStepIndex].longitude,
      );

      double headingDifference = (bearingToNext - (heading ?? 0)).abs();
      if (headingDifference > 180) {
        headingDifference = 360 - headingDifference;
      }

      String directionText;
      if (headingDifference < headingTolerance) {
        directionText = "Proceed straight";
      } else if (headingDifference > (180 - headingTolerance)) {
        directionText = "Turn around";
      } else {
        double relativeBearing = bearingToNext - (heading ?? 0);
        if (relativeBearing < 0) relativeBearing += 360;
        double turnAngle = relativeBearing <= 180 ? relativeBearing : 360 - relativeBearing;
        turnAngle = (turnAngle / 5).round() * 5;
        if (turnAngle < headingTolerance) {
          directionText = "Proceed straight";
        } else {
          directionText = relativeBearing <= 180
              ? "Turn right $turnAngle degrees"
              : "Turn left $turnAngle degrees";
        }
      }

      final now = DateTime.now();
      if (distanceToNextWaypoint <= waypointThreshold ||
          (currentStepIndex == (qrPath?.length ?? directions!.length) - 1 && distanceToNextWaypoint <= finalThreshold)) {
        if (qrPath != null && qrPath.isNotEmpty) {
          if (currentStepIndex == qrPath.length - 1) {
            String destinationName = _qrData[qrPath.last]['name'] ?? 'your destination';
            print('Reached destination: $destinationName at distance: $distanceToNextWaypoint');
            await _speak("You have reached $destinationName.", priority: true);
            await _stopNavigation(silent: true);
            positionStream?.cancel();
            return;
          } else {
            String currentQrName = _qrData[qrPath[currentStepIndex]]['name'] ?? qrPath[currentStepIndex];
            String nextQrName = _qrData[qrPath[currentStepIndex + 1]]['name'] ?? qrPath[currentStepIndex + 1];
            await _speak("You have reached $currentQrName. Proceed to $nextQrName", priority: true);
            currentStepIndex++;
            lastDirectionText = null;
          }
        } else {
          if (currentStepIndex == directions!.length - 1) {
            print('Reached GPS destination at distance: $distanceToNextWaypoint');
            await _speak("You have reached your destination.", priority: true);
            await _stopNavigation(silent: true);
            positionStream?.cancel();
            return;
          } else {
            currentStepIndex++;
            await _speak(directions[currentStepIndex], priority: true);
            lastDirectionText = null;
          }
        }
      } else {
        // Proximity check for final QR
        if (qrPath != null && qrPath.isNotEmpty && currentStepIndex == qrPath.length - 1 && distanceToNextWaypoint <= proximityThreshold) {
          if (proximityAnnounced == null || now.difference(proximityAnnounced!).inSeconds >= 10) {
            String destinationName = _qrData[qrPath.last]['name'] ?? 'your destination';
            await _speak("You are approximately ${distanceToNextWaypoint.toStringAsFixed(0)} meters from $destinationName.", priority: true);
            proximityAnnounced = now;
          }
        }

        String distanceText = distanceToNextWaypoint < 1000
            ? "${distanceToNextWaypoint.toStringAsFixed(0)} meters"
            : "${(distanceToNextWaypoint / 1000).toStringAsFixed(1)} kilometers";
        String announcement;

        if (lastDirectionText != null && lastDirectionText != directionText) {
          if (qrPath != null && qrPath.isNotEmpty) {
            String nextQrName = _qrData[qrPath[currentStepIndex]]['name'] ?? qrPath[currentStepIndex];
            announcement = "$directionText towards $nextQrName in $distanceText.";
          } else {
            announcement = "$directionText in $distanceText. ${directions![currentStepIndex]}";
          }
          await _speak(announcement, priority: true);
          lastAnnouncement = now;
          lastDirectionText = directionText;
        } else if (now.difference(lastAnnouncement).inSeconds >= updateInterval) {
          if (qrPath != null && qrPath.isNotEmpty) {
            String nextQrName = _qrData[qrPath[currentStepIndex]]['name'] ?? qrPath[currentStepIndex];
            announcement = "$directionText towards $nextQrName in $distanceText.";
          } else {
            announcement = "$directionText in $distanceText. ${directions![currentStepIndex]}";
          }
          await _speak(announcement);
          lastAnnouncement = now;
          lastDirectionText = directionText;
        } else {
          lastDirectionText = directionText;
        }
      }
    }, onError: (error) async { // Fixed: Added async
      print('Location stream error: $error');
      await _speak("Error tracking your location. Please ensure GPS is enabled.", priority: true);
    });

    await Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      return _isNavigating;
    });

    print('Navigation loop ended');
    positionStream?.cancel();
  }

  Future<void> _reloadQrData() async {
    print('reloadQrData triggered');
    await _loadQrData();
    setState(() {
      _addMarkers();
      buildQrGraph();
    });
  }

  void _showGpsPrompt() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('GPS Disabled'),
          content: const Text('Please enable GPS to use this feature.'),
          actions: <Widget>[
            ElevatedButton(
              child: const Text('Open Settings'),
              onPressed: () {
                Navigator.of(context).pop();
                Geolocator.openLocationSettings();
              },
            ),
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _showMapTypeDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select Map Type'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<MapType>(
                title: const Text('Normal'),
                value: MapType.normal,
                groupValue: _currentMapType,
                onChanged: (value) {
                  setState(() => _currentMapType = value!);
                  Navigator.pop(context);
                },
              ),
              RadioListTile<MapType>(
                title: const Text('Satellite'),
                value: MapType.satellite,
                groupValue: _currentMapType,
                onChanged: (value) {
                  setState(() => _currentMapType = value!);
                  Navigator.pop(context);
                },
              ),
              RadioListTile<MapType>(
                title: const Text('Hybrid'),
                value: MapType.hybrid,
                groupValue: _currentMapType,
                onChanged: (value) {
                  setState(() => _currentMapType = value!);
                  Navigator.pop(context);
                },
              ),
              RadioListTile<MapType>(
                title: const Text('Terrain'),
                value: MapType.terrain,
                groupValue: _currentMapType,
                onChanged: (value) {
                  setState(() => _currentMapType = value!);
                  Navigator.pop(context);
                },
              ),
              SwitchListTile(
                title: const Text('Show Traffic'),
                value: _isTrafficEnabled,
                onChanged: (value) {
                  setState(() => _isTrafficEnabled = value);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _onDrawerItemTap(String title) {
    Navigator.of(context).pop();
    switch (title) {
      case 'Destination':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => DestinationScreen(
              qrData: _qrData,
              onDestinationSelected: (LatLng destination) {
                _setDestination(gpsDestination: destination, useGps: true);
              },
            ),
          ),
        );
        break;
      case 'QR Location':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => QRLocationScreen(
              qrData: _qrData,
              onQrSelected: (qrId) => _setDestination(qrId: qrId),
            ),
          ),
        );
        break;
      case 'Admin Panel':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => AdminPanelScreen(themeProvider: Provider.of<ThemeProvider>(context, listen: false)),
          ),
        ).then((_) {
          if (mounted) {
            _reloadQrData(); // Trigger reload on return
            print('Manual refresh after AdminPanelScreen');
          }
        });
        break;
      case 'Settings':
        Navigator.of(context).push(MaterialPageRoute(
          builder: (context) => SettingsScreen(themeProvider: Provider.of<ThemeProvider>(context, listen: false)),
        ));
        break;
      case 'Help':
        Navigator.of(context).push(MaterialPageRoute(
          builder: (context) => HelpScreen(themeProvider: Provider.of<ThemeProvider>(context, listen: false)),
        ));
        break;
      case 'About':
        Navigator.of(context).push(MaterialPageRoute(
          builder: (context) => AboutScreen(themeProvider: Provider.of<ThemeProvider>(context, listen: false)),
        ));
        break;
      case 'Server Data':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ServerDataScreen(
              distance: _distanceFromSensor,
              qrCodes: _qrData[_lastDetectedQrId] != null ? [_qrData[_lastDetectedQrId]['name']] : [],
              objects: _detectedObjects,
              motionDetected: _motionDetected,
              motionDirection: _motionDirection,
              motionCentroid: _motionCentroid,
              movingObjectName: _movingObjectName,
            ),
          ),
        );
        break;
    }
  }

  Widget _buildDrawerItem(String title, IconData icon) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      leading: Icon(
        icon,
        color: themeProvider.isDarkMode ? Colors.white : Colors.blue,
      ),
      title: Text(
        title,
        style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
      ),
      onTap: () => _onDrawerItemTap(title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Blind Navigation App',
          style: TextStyle(color: Colors.black87),
        ),
        backgroundColor: themeProvider.isDarkMode ? Colors.black87 : Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.map),
            onPressed: _showMapTypeDialog,
          ),
          IconButton(
            icon: const Icon(Icons.mic),
            onPressed: _startVoiceInteraction,
          ),
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: _fetchCurrentLocation,
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: themeProvider.isDarkMode ? Colors.black : Colors.blue,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: Opacity(
                      opacity: 1,
                      child: Image.asset('assets/map.png', fit: BoxFit.cover),
                    ),
                  ),
                  Center(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 0.0, sigmaY: 0.0),
                      child: Container(
                        color: Colors.black.withOpacity(0.2),
                        padding: const EdgeInsets.all(5.0),
                        child: const Text(
                          'HAIM App',
                          style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _buildDrawerItem('Destination', Icons.place),
            _buildDrawerItem('QR Location', Icons.qr_code),
            _buildDrawerItem('Settings', Icons.settings),
            _buildDrawerItem('Help', Icons.help),
            _buildDrawerItem('About', Icons.info),
            _buildDrawerItem('Admin Panel', Icons.admin_panel_settings),
            _buildDrawerItem('Server Data', Icons.data_usage),
          ],
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              onMapCreated: (controller) {
                _mapController = controller;
              },
              mapType: _currentMapType,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              trafficEnabled: _isTrafficEnabled,
              initialCameraPosition: CameraPosition(target: _initialPosition, zoom: 15),
              markers: Set<Marker>.of(_markers),
              polylines: _polylines,
              onTap: (LatLng position) {
                if (!_isNavigating) {
                  _setDestination(gpsDestination: position, useGps: true);
                }
              },
            ),
          ),
          Positioned(
            top: 2,
            left: 5,
            right: 264,
            child: ElevatedButton(
              onPressed: _stopNavigation,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                elevation: 5,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(
                _isNavigating ? 'Stop Navigation' : 'Navigation Stopped',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          Positioned(
            bottom: 5,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: themeProvider.isDarkMode ? Colors.black54 : Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            "Distance:",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: themeProvider.isDarkMode ? Colors.white70 : Colors.white,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _distanceFromSensor != null ? "${_distanceFromSensor!.toStringAsFixed(2)} cm" : "Fetching...",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: themeProvider.isDarkMode ? Colors.white70 : Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                      if (_qrDetected && _lastDetectedQrId != null)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              "QR Code Detected:",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: themeProvider.isDarkMode ? Colors.white70 : Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _qrData[_lastDetectedQrId]['name'],
                              style: TextStyle(
                                fontSize: 16,
                                color: themeProvider.isDarkMode ? Colors.white70 : Colors.white,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                    ],
                  ),
                  if (_detectedObjects.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "Detected Objects:",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: themeProvider.isDarkMode ? Colors.white70 : Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            alignment: WrapAlignment.center,
                            children: _detectedObjects.map((obj) {
                              return Chip(
                                label: Text(
                                  obj,
                                  style: TextStyle(
                                    color: themeProvider.isDarkMode ? Colors.white70 : Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                                backgroundColor: Colors.blueAccent,
                                avatar: const Icon(Icons.visibility, color: Colors.white, size: 16),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_isListening)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                        "Listening: $_recognizedText",
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.greenAccent,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DestinationScreen extends StatelessWidget {
  final Map<String, dynamic> qrData;
  final Function(LatLng) onDestinationSelected;

  const DestinationScreen({required this.qrData, required this.onDestinationSelected, super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Destination'),
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black87 : Colors.blue,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose Your Destination',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.blue,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Pick a place to navigate to from the list below.',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 24),
            qrData.isEmpty
                ? Center(
              child: Text(
                'No destinations available',
                style: TextStyle(
                  fontSize: 18,
                  color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black54,
                ),
              ),
            )
                : ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: qrData.length,
              itemBuilder: (context, index) {
                String qrId = qrData.keys.elementAt(index);
                String destinationName = qrData[qrId]['name'] ?? qrId;
                LatLng destinationCoordinates = LatLng(
                  qrData[qrId]['current_location'][0],
                  qrData[qrId]['current_location'][1],
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: ListTile(
                    leading: Icon(
                      Icons.place,
                      color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.blue,
                      size: 28,
                    ),
                    title: Text(
                      destinationName,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87,
                      ),
                    ),
                    onTap: () {
                      onDestinationSelected(destinationCoordinates);
                      Navigator.pop(context);
                    },
                    tileColor: Theme.of(context).brightness == Brightness.dark ? Colors.grey[800] : Colors.grey[100],
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class QRLocationScreen extends StatelessWidget {
  final Map<String, dynamic> qrData;
  final Function(String) onQrSelected;

  const QRLocationScreen({required this.qrData, required this.onQrSelected, super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select QR Destination'),
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black87 : Colors.blue,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pick a QR Location',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.blue,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Select a QR code destination to start your journey.',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 24),
            qrData.isEmpty
                ? Center(
              child: Text(
                'No QR locations available',
                style: TextStyle(
                  fontSize: 18,
                  color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black54,
                ),
              ),
            )
                : ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: qrData.length,
              itemBuilder: (context, index) {
                String qrId = qrData.keys.elementAt(index);
                String qrName = qrData[qrId]['name'] ?? qrId;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: ListTile(
                    leading: Icon(
                      Icons.qr_code,
                      color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.blue,
                      size: 28,
                    ),
                    title: Text(
                      qrName,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87,
                      ),
                    ),
                    onTap: () {
                      onQrSelected(qrId);
                      Navigator.pop(context);
                    },
                    tileColor: Theme.of(context).brightness == Brightness.dark ? Colors.grey[800] : Colors.grey[100],
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final ThemeProvider themeProvider;

  const SettingsScreen({super.key, required this.themeProvider});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late double _distanceThreshold;
  late double _speechRate;
  late int _vibrationDuration;
  late int _announcementInterval;
  final TextEditingController _ipController = TextEditingController(); // Add controller for IP input
  late String _currentIp; // Add variable to store current IP

  @override
  void initState() {
    super.initState();
    _distanceThreshold = widget.themeProvider.distanceThreshold;
    _speechRate = widget.themeProvider.speechRate;
    _vibrationDuration = widget.themeProvider.vibrationDuration;
    _announcementInterval = widget.themeProvider.announcementInterval;
    _loadIp(); // Load IP on init
  }

  Future<void> _loadIp() async { // Add method to load IP from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentIp = prefs.getString('server_ip') ?? '192.168.11.92';
      _ipController.text = _currentIp;
    });
  }

  Future<void> _saveIp() async { // Add method to save IP to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', _ipController.text.trim());
    setState(() {
      _currentIp = _ipController.text.trim();
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = widget.themeProvider;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: themeProvider.isDarkMode ? Colors.black87 : Colors.blue,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            SwitchListTile(
              title: Text(
                'Dark Mode',
                style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
              ),
              value: themeProvider.isDarkMode,
              onChanged: (value) {
                themeProvider.toggleTheme();
              },
            ),
            const SizedBox(height: 20),
            Text(
              'Distance Threshold (cm): ${_distanceThreshold.toStringAsFixed(1)}',
              style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
            ),
            Slider(
              value: _distanceThreshold,
              min: 10.0,
              max: 200.0,
              divisions: 190,
              label: _distanceThreshold.toStringAsFixed(1),
              onChanged: (value) {
                setState(() {
                  _distanceThreshold = value;
                });
              },
              onChangeEnd: (value) {
                themeProvider.setDistanceThreshold(value);
              },
            ),
            const SizedBox(height: 20),
            Text(
              'Speech Rate: ${_speechRate.toStringAsFixed(2)}',
              style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
            ),
            Slider(
              value: _speechRate,
              min: 0.1,
              max: 1.0,
              divisions: 9,
              label: _speechRate.toStringAsFixed(2),
              onChanged: (value) {
                setState(() {
                  _speechRate = value;
                });
              },
              onChangeEnd: (value) {
                themeProvider.setSpeechRate(value);
              },
            ),
            const SizedBox(height: 20),
            Text(
              'Vibration Duration (ms): $_vibrationDuration',
              style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
            ),
            Slider(
              value: _vibrationDuration.toDouble(),
              min: 100,
              max: 1000,
              divisions: 9,
              label: _vibrationDuration.toString(),
              onChanged: (value) {
                setState(() {
                  _vibrationDuration = value.toInt();
                });
              },
              onChangeEnd: (value) {
                themeProvider.setVibrationDuration(value.toInt());
              },
            ),
            const SizedBox(height: 20),
            Text(
              'Announcement Interval (s): $_announcementInterval',
              style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
            ),
            Slider(
              value: _announcementInterval.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: _announcementInterval.toString(),
              onChanged: (value) {
                setState(() {
                  _announcementInterval = value.toInt();
                });
              },
              onChangeEnd: (value) {
                themeProvider.setAnnouncementInterval(value.toInt());
              },
            ),
            const SizedBox(height: 20), // Add spacing
            Text(
              'Server IP Address: $_currentIp', // Display current IP
              style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
            ),
            TextField( // Add input field for IP
              controller: _ipController,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Enter IP Address',
                labelStyle: TextStyle(color: themeProvider.isDarkMode ? Colors.white70 : Colors.black54),
              ),
              style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
              keyboardType: TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 10),
            ElevatedButton( // Add save button
              onPressed: _saveIp,
              child: const Text('Save IP'),
            ),
          ],
        ),
      ),
    );
  }
}

class HelpScreen extends StatelessWidget {
  final ThemeProvider themeProvider;
  const HelpScreen({super.key, required this.themeProvider});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Help'),
        backgroundColor: themeProvider.isDarkMode ? Colors.black87 : Colors.blue,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Welcome to Your Navigation Assistant!',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: themeProvider.isDarkMode ? Colors.white : Colors.blue,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'This app is designed to help you navigate easily using voice commands and QR codes. Here’s how to get started and make the most of it.',
              style: TextStyle(
                fontSize: 16,
                color: themeProvider.isDarkMode ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionHeader('Voice Commands', themeProvider),
            const SizedBox(height: 8),
            _buildHelpItem(
              icon: Icons.mic,
              title: 'Start Listening',
              description: 'Press the microphone button or wait for the app to say "How may I help you?" to begin giving commands.',
              themeProvider: themeProvider,
            ),
            _buildHelpItem(
              icon: Icons.place,
              title: 'Set a Destination',
              description: 'Say "Set destination to [place]" (e.g., "Set destination to Library") to start navigating to a QR location.',
              themeProvider: themeProvider,
            ),
            _buildHelpItem(
              icon: Icons.location_on,
              title: 'Check Your Location',
              description: 'Say "Where am I" to hear your current position or nearby landmarks.',
              themeProvider: themeProvider,
            ),
            _buildHelpItem(
              icon: Icons.stop,
              title: 'Stop Navigation',
              description: 'Say "Stop navigation" to end your current route.',
              themeProvider: themeProvider,
            ),
            const SizedBox(height: 24),
            _buildSectionHeader('Using QR Codes', themeProvider),
            const SizedBox(height: 8),
            _buildHelpItem(
              icon: Icons.qr_code,
              title: 'Scan a QR Code',
              description: 'When near a QR code, the app will detect it and tell you where you are. Follow instructions to proceed.',
              themeProvider: themeProvider,
            ),
            _buildHelpItem(
              icon: Icons.directions,
              title: 'Follow the Path',
              description: 'I’ll guide you through a series of QR codes to your destination. Keep scanning as you go!',
              themeProvider: themeProvider,
            ),
            const SizedBox(height: 24),
            _buildSectionHeader('Tips for Smooth Navigation', themeProvider),
            const SizedBox(height: 8),
            _buildHelpItem(
              icon: Icons.vibration,
              title: 'Vibration Alerts',
              description: 'Feel a vibration when I’m listening or when you’re close to an obstacle (<75 cm).',
              themeProvider: themeProvider,
            ),
            _buildHelpItem(
              icon: Icons.map,
              title: 'Map Options',
              description: 'Use the map button in the top bar to switch map types or enable traffic view.',
              themeProvider: themeProvider,
            ),
            _buildHelpItem(
              icon: Icons.settings,
              title: 'Settings',
              description: 'Toggle dark mode in Settings for better visibility in different lighting.',
              themeProvider: themeProvider,
            ),
            const SizedBox(height: 24),
            Text(
              'Need more help? Check the About section for contact details!',
              style: TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                color: themeProvider.isDarkMode ? Colors.white60 : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, ThemeProvider themeProvider) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: themeProvider.isDarkMode ? Colors.white : Colors.blueAccent,
      ),
    );
  }

  Widget _buildHelpItem({
    required IconData icon,
    required String title,
    required String description,
    required ThemeProvider themeProvider,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: themeProvider.isDarkMode ? Colors.white70 : Colors.blue,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: themeProvider.isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 16,
                    color: themeProvider.isDarkMode ? Colors.white70 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ServerDataScreen extends StatelessWidget {
  final double? distance;
  final List<String> qrCodes;
  final List<String> objects;
  final bool motionDetected;
  final String motionDirection;
  final List<int> motionCentroid;
  final String movingObjectName;

  const ServerDataScreen({
    super.key,
    required this.distance,
    required this.qrCodes,
    required this.objects,
    required this.motionDetected,
    required this.motionDirection,
    required this.motionCentroid,
    required this.movingObjectName,
  });

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server Data'),
        backgroundColor: themeProvider.isDarkMode ? Colors.black87 : Colors.blue,
      ),
      body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: ListView(
            children: [
              _buildDataItem('Distance (cm)', distance?.toStringAsFixed(2) ?? 'N/A', themeProvider),
              _buildDataItem('QR Codes', qrCodes.isEmpty ? 'None' : qrCodes.join(', '), themeProvider),
              _buildDataItem('Objects', objects.isEmpty ? 'None' : objects.join(', '), themeProvider),
              _buildDataItem('Motion Detected', motionDetected.toString(), themeProvider),
              _buildDataItem('Motion Direction', motionDirection.isEmpty ? 'N/A' : motionDirection, themeProvider),
              _buildDataItem('Motion Centroid', motionCentroid.length == 2 ? '[${motionCentroid[0]}, ${motionCentroid[1]}]' : 'N/A', themeProvider),
              _buildDataItem('Moving Object', movingObjectName.isEmpty ? 'None' : movingObjectName, themeProvider),
              _buildDataItem('Version:', 'test', themeProvider), // version checker
            ],
          )
      ),
    );
  }

  Widget _buildDataItem(String label, String value, ThemeProvider themeProvider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: themeProvider.isDarkMode ? Colors.white : Colors.black,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              color: themeProvider.isDarkMode ? Colors.white70 : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  final ThemeProvider themeProvider;
  const AboutScreen({super.key, required this.themeProvider});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About Us'),
        backgroundColor: themeProvider.isDarkMode ? Colors.black87 : Colors.blue,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'About Blind Navigation App',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: themeProvider.isDarkMode ? Colors.white : Colors.blue,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Learn more about this innovative project and the team behind it!',
              style: TextStyle(
                fontSize: 16,
                color: themeProvider.isDarkMode ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionHeader('Our Mission', themeProvider),
            const SizedBox(height: 8),
            _buildAboutItem(
              icon: Icons.info,
              title: 'What We Do',
              description: 'This app is part of our MCA coursework at Tripura University. It’s designed to assist visually impaired individuals with navigation using voice-guided directions, QR codes, and Google Maps integration.',
              themeProvider: themeProvider,
            ),
            const SizedBox(height: 24),
            _buildSectionHeader('Meet the Team', themeProvider),
            const SizedBox(height: 8),
            _buildAboutItem(
              icon: Icons.people,
              title: 'Developers',
              description: 'Imnasungit - Bringing tech to life with code.\nMuhammad Hasim S - Crafting solutions for accessibility.',
              themeProvider: themeProvider,
            ),
            _buildAboutItem(
              icon: Icons.school,
              title: 'Supervisor',
              description: 'Dr. Jayanta Pal - Assistant Professor at Tripura University, guiding us every step of the way.',
              themeProvider: themeProvider,
            ),
            const SizedBox(height: 24),
            _buildSectionHeader('Get in Touch', themeProvider),
            const SizedBox(height: 8),
            _buildAboutItem(
              icon: Icons.email,
              title: 'Contact Us',
              description: 'For feedback, support, or inquiries, reach out at:\n- Email: imnasungitlkr@gmail.com\n- Email: muhammedhasi234@gmail.com',
              themeProvider: themeProvider,
            ),
            const SizedBox(height: 24),
            Text(
              'Thank you for using our app! Explore the Help section for usage tips.',
              style: TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                color: themeProvider.isDarkMode ? Colors.white60 : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, ThemeProvider themeProvider) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: themeProvider.isDarkMode ? Colors.white : Colors.blueAccent,
      ),
    );
  }

  Widget _buildAboutItem({
    required IconData icon,
    required String title,
    required String description,
    required ThemeProvider themeProvider,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: themeProvider.isDarkMode ? Colors.white70 : Colors.blue,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: themeProvider.isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 16,
                    color: themeProvider.isDarkMode ? Colors.white70 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
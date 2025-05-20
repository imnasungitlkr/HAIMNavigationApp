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
import 'navigation_assistant.dart';

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
  final Duration _debounceDuration = const Duration(seconds: 10);
  bool _awaitingGpsSwitchResponse = false;
  PorcupineManager? _porcupineManager;
  bool _isPorcupineActive = false;
  bool _motionDetected = false;
  String _motionDirection = "";
  String _movingObjectName = ''; // Simplified from Map if confidence isn't needed
  DateTime? _lastMotionAnnouncement; // Renamed for clarity
  List<int> _motionCentroid = [0, 0]; // Only if used elsewhere (e.g., ServerDataScreen)
  final ValueNotifier<bool> qrDataChangedNotifier = ValueNotifier(false);
  double? _userHeading; // User's current heading in degrees (0-360)
  StreamSubscription<CompassEvent>? _compassSubscription; // Updated for flutter_compass
  bool _isStopping = false;
  DateTime? _lastVibrationTime;
  bool _isProcessingQr = false;
  DateTime? _lastManualScanTime; // Tracks last manual scan time
  final Duration _manualScanOverrideDuration = const Duration(seconds: 15); // Duration to prioritize manual scans
  List<String> _qrScanQueue = []; // Queue for manual QR scans
  DateTime? _lastProximityCheck; // Tracks last proximity check for debouncing
  bool _isNewNavigation = false; // Tracks if navigation is newly started or recalculated
  StreamSubscription<Position>? _positionStream; // Declare position stream
  String? _currentTtsText; // Tracks the currently spoken TTS text
  String? _lastAnnouncementText; // Tracks the last announced text for debouncing
  DateTime? _lastAnnouncementTime;
  final NavigationAssistant _navigationAssistant = NavigationAssistant();
  bool _isUserInteractionActive = false; // New flag for STT/instruction processing
  String? _lastManualScanQrId; // Tracks the QR ID of the last manual scan


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
    await Future.delayed(const Duration(milliseconds: 500));
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
    await Future.delayed(const Duration(milliseconds: 500)); // Slight delay to reduce main thread load
    try {
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
        "OvTGqLwZjKOUcjX1yw3otlghy8bvxCzAjG8nKjzVj+iW6kQMHdBkMQ==",
        ["assets/Hey-coco_en_android_v3_0_0.ppn"],
            (int keywordIndex) {
          if (keywordIndex == 0) {
            print("Wake word 'Hey Coco' detected");
            _handleWakeWordDetection();
          }
        },
      );
      await _porcupineManager?.start();
      _isPorcupineActive = true;
      print("Porcupine wake word detection started");
    } catch (e, stackTrace) {
      print("Error initializing Porcupine: $e\nStackTrace: $stackTrace");
      await _speak("Failed to initialize wake word detection.");
    }
  }

  Future<void> _handleWakeWordDetection() async {
    if (_isPorcupineActive) {
      await _porcupineManager?.stop();
      _isPorcupineActive = false;
      print("Porcupine stopped for command input");

      // Stop current TTS, clear queue, and mark interaction active
      await _navigationAssistant.stop();
      setState(() {
        _ttsQueue.clear();
        _isTtsSpeaking = false;
        _isUserInteractionActive = true;
      });
      print("TTS stopped, queue cleared, and interaction marked active due to wake word detection");

      // Start voice interaction
      await _startVoiceInteraction();
    }
  }

  Future<void> _initializeTts() async {
    await _navigationAssistant.updateSpeechRate(Provider.of<ThemeProvider>(context, listen: false).speechRate);
    _ttsInitialized = true;
    print("TTS Initialized via NavigationAssistant");
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
        _isUserInteractionActive = false;
      });
      print("Stopped listening, interaction ended, TTS enabled with fresh queue");

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

    try {
      // Reset interaction state early to allow _setDestination
      setState(() => _isUserInteractionActive = false);

      if (_awaitingDestination) {
        print("Awaiting destination, handling: '$command'");
        // Map destination to QR ID
        String? qrId = _mapDestinationToQrId(command);
        if (qrId != null) {
          await _setDestination(qrId: qrId);
          if (_destinationQrId == qrId && _isNavigating) {
            await _speak("Destination set to ${_qrData[qrId]['name']}. Follow the QR path.", priority: true);
          } else {
            //await _speak("Failed to set destination. Please try again.", priority: true);
          }
        } else {
          await _speak(
            "I couldn’t find that destination. Please say a valid location like 'Cottage' or 'Library'.",
            priority: true,
          );
          setState(() => _awaitingDestination = true); // Keep awaiting
        }
      } else if (_awaitingGpsSwitchResponse) {
        debugPrint("Awaiting GPS switch response, handling: '$command'");
        await _handleGpsSwitchResponse(command);
      } else {
        debugPrint("Passing to processCommand: '$command'");
        if (command.contains('set destination')) {
          // Handle destination command directly
          String destination = command.replaceFirst('set destination', '').trim();
          String? qrId = _mapDestinationToQrId(destination);
          if (qrId != null) {
            await _setDestination(qrId: qrId);
            if (_destinationQrId == qrId && _isNavigating) {
              await _speak("Destination set to ${_qrData[qrId]['name']}. Follow the QR path.", priority: true);
            } else {
              //await _speak("Failed to set destination. Please try again.", priority: true);
            }
          } else {
            await _speak(
              "I couldn’t find that destination. Please say a valid location like 'Cottage' or 'Library'.",
              priority: true,
            );
            setState(() => _awaitingDestination = true);
          }
        } else {
          await _processCommand(command);
        }
      }
    } finally {
      // Wait for any ongoing TTS to complete
      while (_navigationAssistant.isSpeaking) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      // Reset voice state
      setState(() {
        _isUserInteractionActive = false;
        _isListening = false;
        // Only reset _awaitingDestination if it wasn’t set above
        if (!_awaitingDestination) {
          _awaitingDestination = false;
        }
      });
      print("Voice command processed, interaction ended, TTS enabled with fresh queue");
      _stopListening();
      _restartPorcupine();
    }
  }

// Helper method to map destination to QR ID
  // Helper method to map destination to QR ID
  String? _mapDestinationToQrId(String destination) {
    destination = destination.toLowerCase().trim();
    for (String qrId in _qrData.keys) {
      String qrName = _qrData[qrId]['name']?.toLowerCase() ?? '';
      if (qrName.isNotEmpty && destination.contains(qrName)) {
        return qrId;
      }
    }
    return null;
  }

  Future<void> _startVoiceInteraction() async {
    print("Starting voice interaction, IsNavigating: $_isNavigating");
    if (_speechInitialized && _ttsInitialized) {
      await _navigationAssistant.stop();
      setState(() {
        _ttsQueue.clear();
        _isTtsSpeaking = false;
        _isUserInteractionActive = true;
      });
      print("TTS stopped, queue cleared, and interaction marked active for voice interaction");

      if (_isListening) {
        print("Stopping existing listening session...");
        _stopListening();
        await Future.delayed(const Duration(milliseconds: 200));
      }

      if (_isPorcupineActive) {
        await _porcupineManager?.stop();
        _isPorcupineActive = false;
        debugPrint("Porcupine stopped for manual microphone activation");
      }

      print("Speaking prompt: How may I help you?");
      await _speak("How may I help you?", priority: true);
      while (_navigationAssistant.isSpeaking) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      print("Prompt completed");

      print("Triggering vibration");
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [0, 200, 100, 200]);
        await Future.delayed(const Duration(milliseconds: 500));
      }

      debugPrint("Starting STT listening");
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
      print("Listening started");

      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 100));
        return _isListening;
      });

      print("Voice interaction completed, waiting for command processing to finish");
    } else {
      if (!_speechInitialized) {
        print("Speech recognition not initialized, speaking error");
        await _speak("Speech recognition is not initialized. Please check permissions.", priority: true);
      }
      if (!_isPorcupineActive) {
        print("Restarting Porcupine");
        await _restartPorcupine();
      }
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
        await _speak("Where to? Say a place like 'Library' or 'Cafeteria.'", priority: true);
        _awaitingDestination = true;
      }
    } else if (_isNavigating && stopCommands.any((cmd) => command.contains(cmd))) {
      print("Matched stop command: '$command'");
      await _stopNavigation();
      await _speak("Navigation stopped.", priority: true);
    } else if (objectCommands.any((cmd) => command.contains(cmd))) {
      print("Matched object command: '$command'");
      if (_detectedObjects.isNotEmpty) {
        await _speak("${_detectedObjects.join(", ")} detected", priority: true);
      } else {
        await _speak("No objects detected in front of you.", priority: true);
      }
    } else {
      print("Unrecognized command: '$command'");
      await _speak(
        "I didn’t understand that. Please try again with commands like 'where am I', 'set destination to Library', or 'what is in front of me'.",
        priority: true,
      );
    }
    setState(() => _recognizedText = '');
  }

  Future<void> _handleWhereAmI() async {
    if (_currentPosition != null) {
      LatLng current = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
      String nearestLandmark = _findNearestLandmark(current);
      if (nearestLandmark.isNotEmpty) {
        await _speak("You are near $nearestLandmark.", priority: true);
      } else {
        await _speak(
          "You are at latitude ${_currentPosition!.latitude.toStringAsFixed(4)}, "
              "longitude ${_currentPosition!.longitude.toStringAsFixed(4)}.",
          priority: true,
        );
      }
    } else {
      await _speak("I can’t determine your location yet. Please wait.", priority: true);
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
        await _speak("Destination set to nearest QR code: ${_qrData[nearestQr]['name']}.", priority: true);
        if (_lastDetectedQrId != null) {
          List<String> path = findShortestPath(_lastDetectedQrId!, nearestQr);
          await _announceQrPath(path);
        } else {
          await _speak("Please scan a QR code to start navigation.", priority: true);
        }
      } else {
        await _speak(
          "No nearby QR codes found or location unavailable. Please specify a destination or enable GPS.",
          priority: true,
        );
        _awaitingDestination = true;
      }
      return;
    }

    String? qrId = _mapDestinationToQrId(destination);
    if (qrId != null) {
      print("Setting destination to QR ID: $qrId");
      await _setDestination(qrId: qrId);
      await _speak("Destination set to ${_qrData[qrId]['name']}. Follow the QR path.", priority: true);
      if (_lastDetectedQrId != null) {
        List<String> path = findShortestPath(_lastDetectedQrId!, qrId);
        await _announceQrPath(path);
      } else {
        await _speak("Please scan a QR code to start navigation.", priority: true);
      }
    } else {
      await _speak(
        "I couldn’t find that destination. Please say a valid location like 'Cottage' or 'Library'.",
        priority: true,
      );
      _awaitingDestination = true;
    }
  }

  Future<void> _speak(String text, {bool priority = false, bool isManualQrScan = false, bool critical = false}) async {
    print("Speaking: $text, Priority: $priority, Critical: $critical, IsManualQrScan: $isManualQrScan, "
        "TTS Initialized: $_ttsInitialized, Speaking: $_isTtsSpeaking, Queue: ${_ttsQueue.length}, "
        "Interaction Active: $_isUserInteractionActive");

    if (!_ttsInitialized) {
      print("TTS not initialized, discarding: $text");
      return;
    }

    if (_isUserInteractionActive && !isManualQrScan && !critical && !priority) {
      print("Interaction active, discarding non-critical/priority: $text");
      return;
    }

    if (!priority && !critical && !isManualQrScan && !_isNavigating && text.contains("Destination set to")) {
      print("Ignoring outdated destination message: $text (not navigating)");
      return;
    }

    if (_isStopping && !priority && !critical && !isManualQrScan) {
      print("Ignoring non-critical/priority speech '$text' during navigation stop");
      return;
    }

    if (_lastAnnouncementText == text && _lastAnnouncementTime != null && DateTime.now().difference(_lastAnnouncementTime!).inSeconds < 4) {
      debugPrint("Skipping redundant announcement: $text");
      return;
    }

    _isTtsSpeaking = true;
    _currentTtsText = text;

    try {
      if (isManualQrScan || critical || priority) {
        await _navigationAssistant.stop();
        await _navigationAssistant.speakAnnouncement(
          text,
          isCritical: critical,
          isManualQrScan: isManualQrScan,
          priority: priority,
        );
      } else {
        await _navigationAssistant.speakAnnouncement(text);
      }

      while (_navigationAssistant.isSpeaking) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      print("TTS completed: $text");
      _lastAnnouncementText = text;
      _lastAnnouncementTime = DateTime.now();
    } catch (e) {
      print("TTS failed: $e");
    } finally {
      _isTtsSpeaking = false;
      _currentTtsText = null;
    }

    // Process queue only if not in stopping state or interaction
    if (!isManualQrScan && !priority && _ttsQueue.isNotEmpty && !_isStopping && !_isUserInteractionActive) {
      String next = _ttsQueue.removeFirst();
      print("Speaking from queue: $next");
      await _speak(next);
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
            ?.map((obj) => (obj['object'] as String?)?.toLowerCase() ?? 'unknown')
            .toList() ?? [];
        bool motionDetected = data['motion']?['detected'] as bool? ?? false;
        String motionDirection = (data['motion']?['direction'] as String?)?.toLowerCase() ?? '';
        String movingObjectName = data['motion']?['moving_object'] is Map
            ? ((data['motion']['moving_object']['object'] as String?)?.toLowerCase() ?? 'unknown object')
            : 'no moving object';
        List<int> motionCentroid = (data['motion']?['centroid'] as List?)
            ?.map((e) => e as int)
            .toList() ?? [0, 0];
        List<String> qrCodes = (data['qr_codes'] as List?)
            ?.map((qr) => (qr['qid'] as String?) ?? '')
            .where((qid) => qid.isNotEmpty)
            .toList() ?? [];

        setState(() {
          _distanceFromSensor = newDistance;
          _detectedObjects = newDetectedObjects;
          _motionDetected = motionDetected;
          _motionDirection = motionDirection;
          _movingObjectName = movingObjectName;
          _motionCentroid = motionCentroid;
        });

        // Process QR codes
        for (String qrId in qrCodes) {
          if (_qrData.containsKey(qrId)) {
            await handleQRScan(qrId, isManualScan: true);
          } else {
            print('Invalid QR code received from Pi: $qrId');
            await _speak('Invalid QR code detected.', critical: true);
          }
        }

        // Motion detection announcements
        if (_motionDetected && motionDirection.isNotEmpty && motionDirection != 'stationary') {
          final now = DateTime.now();
          if (_lastMotionAnnouncement == null || now.difference(_lastMotionAnnouncement!).inSeconds >= 6) {
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
              motionText = "$selectedObject detected moving $motionDirection";
            } else if (_movingObjectName != 'no moving object') {
              motionText = "$_movingObjectName detected moving $motionDirection";
            } else {
              motionText = "unknown object moving $motionDirection";
            }

            print('Attempting to announce motion: $motionText, Interaction Active: $_isUserInteractionActive, TTS Speaking: $_isTtsSpeaking');
            _lastMotionAnnouncement = now;
            await _speak(motionText, critical: true);
            print('Motion announcement processed: $motionText');
          } else {
            print('Motion announcement suppressed (debounced): $motionDirection');
          }
        } else {
          print('Motion announcement skipped: Detected=$_motionDetected, Direction=$motionDirection');
        }

        // Threshold-based announcements and vibration
        final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
        bool isBelowThreshold = _distanceFromSensor != null && _distanceFromSensor! < themeProvider.distanceThreshold;

        if (isBelowThreshold) {
          final priorityOrder = ['truck', 'car', 'bike', 'bicycle', 'person'];
          String? detectedObject;
          for (String priority in priorityOrder) {
            if (_detectedObjects.contains(priority)) {
              detectedObject = priority;
              break;
            }
          }

          if (detectedObject != null) {
            String objectText = "$detectedObject is in front of you";
            print('Attempting to announce static object: $objectText');
            await _speak(objectText, critical: true);
          }

          if (await Vibration.hasVibrator()) {
            const int vibrationInterval = 1000;
            final now = DateTime.now();
            if (_lastVibrationTime == null || now.difference(_lastVibrationTime!) >= const Duration(milliseconds: vibrationInterval)) {
              Vibration.vibrate(duration: themeProvider.vibrationDuration);
              setState(() {
                _lastVibrationTime = now;
              });
            }
          }
        }
      } else {
        print('Failed to fetch data: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching data: $e');
    }
  }

  Future<void> _processQrQueue() async {
    if (_isProcessingQr || _qrScanQueue.isEmpty) return;

    String qrId = _qrScanQueue.removeAt(0);
    debugPrint("Processing queued QR: $qrId");
    await handleQRScan(qrId, isManualScan: true);
    setState(() {
      _qrDetected = true;
      _lastDetectedQrId = qrId;
      _lastManualScanTime = DateTime.now();
    });

    // Process next QR in queue
    if (_qrScanQueue.isNotEmpty) {
      await _processQrQueue();
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

  Future<void> handleQRScan(String scannedQr, {bool isManualScan = false}) async {
    debugPrint("handleQRScan: Entered with QR: $scannedQr, isManualScan: $isManualScan, _qrDetected: $_qrDetected, _lastDetectedQrId: $_lastDetectedQrId, _isNavigating: $_isNavigating, _isProcessingQr: $_isProcessingQr");

    // Queue all scans to prevent concurrent processing
    if (_isProcessingQr) {
      debugPrint("handleQRScan: Queuing QR scan: $scannedQr (Processing: $_isProcessingQr)");
      _qrScanQueue.add(scannedQr);
      return;
    }

    // Set processing flag and timeout
    _isProcessingQr = true;
    Timer(const Duration(seconds: 5), () {
      if (_isProcessingQr) {
        debugPrint("handleQRScan: Timeout triggered, resetting _isProcessingQr for QR: $scannedQr");
        _isProcessingQr = false;
        _processQrQueue();
      }
    });

    try {
      if (_qrData.isEmpty) {
        debugPrint("handleQRScan: QR data is empty");
        await _speak("QR data not loaded. Please try again later.", priority: true, isManualQrScan: isManualScan);
        return;
      }

      if (!_qrData.containsKey(scannedQr)) {
        debugPrint("handleQRScan: Invalid QR code: $scannedQr");
        await _speak("Invalid QR code. Please scan a valid navigation QR.", priority: true, isManualQrScan: isManualScan);
        return;
      }

      // Check for duplicate manual scan
      if (isManualScan &&
          _lastManualScanQrId == scannedQr &&
          _lastManualScanTime != null &&
          DateTime.now().difference(_lastManualScanTime!) < Duration(seconds: 6)) {
        debugPrint('Ignoring duplicate manual scan for QR: $scannedQr');
        return; // Skip processing
      }

      // Update manual scan state
      if (isManualScan) {
        _lastManualScanQrId = scannedQr;
        _lastManualScanTime = DateTime.now();
      }

      // Update state
      setState(() {
        _lastDetectedQrId = scannedQr;
        _initialQrPosition = LatLng(
          _qrData[scannedQr]['current_location'][0],
          _qrData[scannedQr]['current_location'][1],
        );
        _qrDetected = true;
      });

      _qrDisplayTimer?.cancel();
      _qrDisplayTimer = Timer(const Duration(seconds: 10), () {
        debugPrint("handleQRScan: QR display timer firing for QR: $scannedQr");
        setState(() {
          _qrDetected = false;
          debugPrint("handleQRScan: QR display timer reset _qrDetected to false for QR: $scannedQr");
        });
      });

      // Non-navigation mode
      if (!_isNavigating || _destinationQrId == null) {
        debugPrint("handleQRScan: Non-navigation mode: Announcing QR context for $scannedQr");
        String announcement;
        try {
          announcement = _qrData[scannedQr]['context'];
        } catch (e) {
          debugPrint("handleQRScan: Error accessing QR context for $scannedQr: $e");
          announcement = "You are at ${_qrData[scannedQr]['name']}. Location details unavailable.";
        }
        debugPrint("handleQRScan: Speaking announcement: $announcement");
        await _speak(announcement, priority: true, isManualQrScan: isManualScan);
        return;
      }

      // Navigation mode
      debugPrint("handleQRScan: Navigation mode: Processing QR scan, _destinationQrId: $_destinationQrId");
      List<String> path = findShortestPath(scannedQr, _destinationQrId!);
      debugPrint("handleQRScan: Calculated path from $scannedQr to $_destinationQrId: $path");
      if (path.isEmpty) {
        debugPrint("handleQRScan: No path found from $scannedQr to $_destinationQrId");
        await _speak("No QR path found from ${_qrData[scannedQr]['name']} to ${_qrData[_destinationQrId!]['name']}. Please scan another QR or set a new destination.", priority: true, isManualQrScan: isManualScan);
        return;
      }

      if (scannedQr == _destinationQrId) {
        debugPrint("handleQRScan: Destination reached: $scannedQr");
        // Destination reached: Stop TTS, speak with priority, and pause
        await _navigationAssistant.stop(); // Clear ongoing announcements
        await _speak("Destination ${_qrData[scannedQr]['name']} reached.", priority: true, isManualQrScan: isManualScan); // Use priority to ensure spoken
        await _navigationAssistant.waitForCompletion();
        await Future.delayed(const Duration(seconds: 0)); // 1-second pause
        await _stopNavigation(silent: true); // Silent to avoid duplicate stop announcement
        setState(() {});
      } else if (path.contains(scannedQr)) {
        debugPrint("handleQRScan: On path QR: $scannedQr, index: ${path.indexOf(scannedQr)}");
        int currentIndex = path.indexOf(scannedQr);
        String nextQr = path[currentIndex + 1];
        await _speak("You scanned ${_qrData[scannedQr]['name']} ${isManualScan ? 'manually' : 'by proximity'}. Proceed to ${_qrData[nextQr]['name']}.", priority: true, isManualQrScan: isManualScan);
        await _navigateThroughQrPath(path, announceFullPath: false, currentIndex: currentIndex);
        setState(() {});
      } else {
        debugPrint("handleQRScan: Off path QR: $scannedQr, recalculating");
        await _speak("You scanned ${_qrData[scannedQr]['name']} ${isManualScan ? 'manually' : 'by proximity'}, which is off the current path. Recalculating route from here.", priority: true, isManualQrScan: isManualScan);
        List<String> newPath = findShortestPath(scannedQr, _destinationQrId!);
        debugPrint("handleQRScan: New calculated path: $newPath");
        if (newPath.isNotEmpty) {
          setState(() {
            _isNewNavigation = true;
          });
          await _speak("New path calculated to ${_qrData[_destinationQrId!]['name']} starting from ${_qrData[scannedQr]['name']}.", priority: true, isManualQrScan: isManualScan);
          await _navigateThroughQrPath(newPath, announceFullPath: true, currentIndex: 0);
          setState(() {});
        } else {
          await _speak("No QR path found from ${_qrData[scannedQr]['name']} to ${_qrData[_destinationQrId!]['name']}. Please scan another QR or set a new destination.", priority: true, isManualQrScan: isManualScan);
        }
      }
    } catch (e, stackTrace) {
      debugPrint("handleQRScan: Error processing QR: $scannedQr, Error: $e, StackTrace: $stackTrace");
      await _speak("Error processing QR code. Please try again.", priority: true, isManualQrScan: isManualScan);
    } finally {
      _isProcessingQr = false;
      debugPrint("handleQRScan: Finished processing QR: $scannedQr, _isProcessingQr: $_isProcessingQr, _lastDetectedQrId: $_lastDetectedQrId");
      _processQrQueue();
    }
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
    if (_isStopping || _isListening || (!_isNavigating && _destinationQrId == null)) {
      debugPrint("handleLocationChange: Skipping due to stopping, listening, or no active navigation");
      return;
    }

    setState(() {
      _currentPosition = position;
    });

    if (_isNavigating && _destinationQrId == null) {
      debugPrint("handleLocationChange: No destination QR set, updating navigation mode");
      updateNavigationMode();
    } else if (_isNavigating && _destinationQrId != null) {
      _provideContextualInfo(position);

      LatLng currentPos = LatLng(position.latitude, position.longitude);
      debugPrint("handleLocationChange: Current position: $currentPos, _lastDetectedQrId: $_lastDetectedQrId");

      // Skip proximity and off-path checks if a recent manual scan exists
      bool hasRecentManualScan = _lastManualScanTime != null &&
          DateTime.now().difference(_lastManualScanTime!).inSeconds < _manualScanOverrideDuration.inSeconds;
      if (hasRecentManualScan) {
        debugPrint("handleLocationChange: Recent manual scan detected ($_lastDetectedQrId), skipping proximity and off-path checks");
        return;
      }

      // Use _lastDetectedQrId if set, otherwise find nearest QR
      String startQrId = _lastDetectedQrId ?? _findNearestQr(currentPos);
      debugPrint("handleLocationChange: Starting from QR: $startQrId to destination: $_destinationQrId");
      List<String> qrPath = findShortestPath(startQrId, _destinationQrId!);
      debugPrint("handleLocationChange: Calculated path: $qrPath");

      if (qrPath.isEmpty) {
        debugPrint("handleLocationChange: No QR path found from $startQrId to $_destinationQrId");
        await _speak("No QR path available. Please scan a QR code or set a new destination.", priority: true, isManualQrScan: false);
        return;
      }

      // Proximity check for next QR, only if no recent QR detection
      if (!_qrDetected && qrPath.isNotEmpty && !_isTtsSpeaking) {
        String nextQrId = qrPath.length > 1 ? qrPath[1] : qrPath[0];
        if (!_qrData.containsKey(nextQrId)) {
          debugPrint("handleLocationChange: Invalid next QR ID: $nextQrId");
          return;
        }
        double distanceToNextQr = Geolocator.distanceBetween(
          currentPos.latitude,
          currentPos.longitude,
          _qrData[nextQrId]['current_location'][0],
          _qrData[nextQrId]['current_location'][1],
        );
        debugPrint("handleLocationChange: Distance to next QR $nextQrId: $distanceToNextQr meters");

        // Debounce proximity detection to prevent rapid updates
        DateTime now = DateTime.now();
        const Duration proximityDebounceDuration = Duration(seconds: 5);
        if (_lastProximityCheck == null || now.difference(_lastProximityCheck!) >= proximityDebounceDuration) {
          if (distanceToNextQr <= 3.0) {
            debugPrint("handleLocationChange: Proximity to QR $nextQrId detected at $distanceToNextQr meters");
            setState(() {
              _lastDetectedQrId = nextQrId;
              _qrDetected = true;
              _lastProximityCheck = now;
            });
            _qrDisplayTimer?.cancel();
            _qrDisplayTimer = Timer(const Duration(seconds: 10), () {
              setState(() {
                _qrDetected = false;
                debugPrint("handleLocationChange: QR display timer reset _qrDetected to false for QR: $nextQrId");
              });
            });

            if (nextQrId == _destinationQrId) {
              await _speak("You have reached ${_qrData[nextQrId]['name']} by proximity.", priority: true, isManualQrScan: false);
              await _stopNavigation();
            } else {
              String nextQrName = qrPath.length > 2 ? _qrData[qrPath[2]]['name'] : _qrData[_destinationQrId!]['name'];
              await _speak(
                "You have reached ${_qrData[nextQrId]['name']} by proximity. Proceed to $nextQrName.",
                priority: true,
                isManualQrScan: false,
              );
              await _navigateThroughQrPath(qrPath.sublist(1), announceFullPath: false);
            }
            debugPrint("handleLocationChange: Proximity processed, _lastDetectedQrId: $_lastDetectedQrId");
            return;
          }
        }
      }

      // Skip off-path check if a recent QR was detected
      if (_lastDetectedQrId != null && _qrDetected) {
        debugPrint("Recent QR scan or proximity detection ($_lastDetectedQrId), skipping GPS off-path check");
        return;
      }

      // Off-path detection
      List<LatLng> qrRoutePoints = [];
      for (int i = 0; i < qrPath.length - 1; i++) {
        LatLng startPos = LatLng(_qrData[qrPath[i]]['current_location'][0], _qrData[qrPath[i]]['current_location'][1]);
        LatLng endPos = LatLng(_qrData[qrPath[i + 1]]['current_location'][0], _qrData[qrPath[i + 1]]['current_location'][1]);
        var result = await getDirectionsWithSteps(startPos, endPos, apiKey);
        qrRoutePoints.addAll(result['polylinePoints']);
      }
      debugPrint("handleLocationChange: QR route points calculated, length: ${qrRoutePoints.length}");

      double minDistanceToRoute = double.infinity;
      for (int i = 0; i < qrRoutePoints.length - 1; i++) {
        double distance = _distanceToSegment(currentPos, qrRoutePoints[i], qrRoutePoints[i + 1]);
        if (distance < minDistanceToRoute) {
          minDistanceToRoute = distance;
        }
      }
      debugPrint("handleLocationChange: Minimum distance to route: $minDistanceToRoute meters");

      if (minDistanceToRoute > 50.0 && !_isTtsSpeaking && !_awaitingGpsSwitchResponse) {
        String nearestQrId = _findNearestQr(currentPos);
        double distanceToNearestQr = Geolocator.distanceBetween(
          currentPos.latitude,
          currentPos.longitude,
          _qrData[nearestQrId]['current_location'][0],
          _qrData[nearestQrId]['current_location'][1],
        );
        debugPrint("handleLocationChange: Nearest QR $nearestQrId, distance: $distanceToNearestQr meters");

        if (distanceToNearestQr < 50.0 && qrPath.contains(nearestQrId)) {
          debugPrint("User near QR $nearestQrId on path, recalculating");
          await _speak(
            "You are off the QR path. Recalculating from ${_qrData[nearestQrId]['name']} to ${_qrData[_destinationQrId!]['name']}.",
            priority: true,
            isManualQrScan: false,
          );
          List<String> newPath = findShortestPath(nearestQrId, _destinationQrId!);
          debugPrint("handleLocationChange: New path from $nearestQrId: $newPath");
          if (newPath.isNotEmpty) {
            await _navigateThroughQrPath(newPath);
          } else {
            await _speak(
              "No QR path found from ${_qrData[nearestQrId]['name']}. Switching to GPS navigation.",
              priority: true,
              isManualQrScan: false,
            );
            await _fetchAndSpeakDirections(currentPos, _destination!);
          }
        } else {
          debugPrint("User far from QR path, distance: $minDistanceToRoute meters");
          await _speak(
            "You are ${minDistanceToRoute.toStringAsFixed(0)} meters off the QR path. "
                "Please scan a QR code or say 'use GPS' to navigate from your current location.",
            priority: true,
            isManualQrScan: false,
          );
          _awaitingGpsSwitchResponse = true;
          await _startVoiceInteraction();
        }
      }
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
    _navigationAssistant.dispose();
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

      // Stop TTS to clear ongoing announcements
      await _navigationAssistant.stop();
      // Retry stop to ensure _isSpeaking is cleared
      if (_navigationAssistant.isSpeaking) {
        await Future.delayed(Duration(milliseconds: 200));
        await _navigationAssistant.stop();
      }
      _isTtsSpeaking = false;
      _qrScanQueue.clear(); // Clear QR scan queue

      // Reset navigation and voice state
      setState(() {
        _polylines.clear();
        _markers.removeWhere((marker) => marker.markerId.value == 'destination');
        _destination = null;
        _destinationQrId = null;
        _lastDetectedQrId = null; // Clear to prevent handleLocationChange triggers
        _directionsCache.clear();
        _polylinePoints.clear();
        _qrDetected = false;
        _awaitingDestination = false; // Clear voice command state
        _isUserInteractionActive = false; // Stop voice interaction
        _isListening = false; // Ensure no voice command re-trigger
      });
      _awaitingGpsSwitchResponse = false;

      // Announce stop with priority to ensure it’s spoken
      if (!silent) {
        print("Speaking stop announcement...");
        // Wait to ensure prior TTS completes
        await Future.delayed(Duration(seconds: 1));
        await _speak("Navigation has been stopped.", priority: true); // Priority to bypass _isSpeaking
        await _navigationAssistant.waitForCompletion(); // Ensure announcement completes
        await Future.delayed(const Duration(seconds: 1)); // 1-second pause
      }

      print("Navigation stopped${silent ? ' silently' : ''}. AwaitingDestination: $_awaitingDestination, Listening: $_isListening, _lastDetectedQrId: $_lastDetectedQrId");
      _restartPorcupine();
      _isStopping = false; // Unlock state after all operations
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

  Future<void> _setDestination({String? qrId, LatLng? gpsDestination, bool useGps = false}) async {
    if (_isStopping) {
      debugPrint("_setDestination: Skipping due to stopping, qrId: $qrId, gpsDestination: $gpsDestination");
      return;
    }

    // Validate qrId before accessing _qrData
    if (qrId != null && !_qrData.containsKey(qrId)) {
      debugPrint("_setDestination: Invalid QR ID: $qrId");
      await _speak("Invalid destination. Please choose a valid destination.", priority: true);
      setState(() => _isNavigating = false);
      return;
    }

    setState(() {
      _destination = gpsDestination ?? (qrId != null && _qrData[qrId] != null
          ? LatLng(_qrData[qrId]['current_location'][0], _qrData[qrId]['current_location'][1])
          : null);
      _destinationQrId = qrId;
      _polylines.clear();
      _polylinePoints.clear();
      if (_destination != null) {
        _markers.removeWhere((marker) => marker.markerId.value == 'destination');
        _markers.add(Marker(
          markerId: const MarkerId('destination'),
          position: _destination!,
          infoWindow: InfoWindow(title: qrId != null && _qrData[qrId] != null ? _qrData[qrId]['name'] : 'Destination'),
          icon: destinationIcon,
        ));
      }
      _isNavigating = true;
      _isNewNavigation = true; // Flag new navigation for full path announcement
    });

    if (_destination == null) {
      await _speak("No destination selected. Please choose a valid destination.", priority: true);
      setState(() => _isNavigating = false);
      return;
    }

    String? startQrId;
    LatLng? start;

    // Prioritize last scanned QR
    if (_lastDetectedQrId != null && _qrData.containsKey(_lastDetectedQrId) && qrId != null && !useGps) {
      startQrId = _lastDetectedQrId;
      start = LatLng(
        _qrData[startQrId]['current_location'][0],
        _qrData[startQrId]['current_location'][1],
      );
    } else if (qrId != null && !useGps && _currentPosition != null) {
      // Fallback to nearest QR using GPS
      start = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
      startQrId = _findNearestQr(start);
    } else if (qrId != null && !useGps && _initialQrPosition != null) {
      // Fallback to initial QR position
      start = _initialQrPosition!;
      startQrId = _findNearestQr(start);
    } else if (gpsDestination != null || useGps) {
      // Use GPS location for GPS navigation
      start = _currentPosition != null ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude) : null;
    }

    if (start == null || (startQrId != null && !_qrData.containsKey(startQrId))) {
      await _speak("No location available. Please scan a QR code or enable GPS to start navigation.", priority: true);
      setState(() => _isNavigating = false);
      return;
    }

    // Clear prior TTS to avoid overlap
    await _navigationAssistant.stop();

    // Use non-nullable destination for _fetchAndSpeakDirections
    final LatLng destination = _destination!;

    if (qrId != null && _qrData.containsKey(qrId) && !useGps) {
      await _speak("Calculating path from ${_qrData[startQrId]['name']} to ${_qrData[qrId]['name']} via QR path.", priority: true);
      if (startQrId != null) {
        List<String> qrPath = findShortestPath(startQrId, qrId);
        if (qrPath.isNotEmpty) {
          await _navigateThroughQrPath(qrPath, announceFullPath: true);
        } else {
          await _speak("No QR path found from ${_qrData[startQrId]['name']}. Switching to GPS navigation.", priority: true);
          await _fetchAndSpeakDirections(start, destination);
        }
      } else {
        await _speak("No recent QR scanned. Guiding to the nearest QR: ${_qrData[startQrId]['name']} to start navigation to ${_qrData[qrId]['name']}.", priority: true);
        await _fetchAndSpeakDirections(
          start,
          LatLng(_qrData[startQrId]['current_location'][0], _qrData[startQrId]['current_location'][1]),
        );
      }
    } else if (gpsDestination != null || useGps) {
      await _speak("Calculating path to your selected location via GPS.", priority: true);
      await _fetchAndSpeakDirections(start, destination);
    }
  }

  Future<void> _announceQrPath(List<String> qrPath) async {
    if (qrPath.isEmpty) {
      await _speak("No QR path found to the destination.", priority: true);
      return;
    }

    String pathAnnouncement = "To reach your destination, you will pass through the following QR codes: ";
    for (int i = 0; i < qrPath.length; i++) {
      String qrName = _qrData[qrPath[i]]['name'] ?? qrPath[i];
      pathAnnouncement += qrName;
      if (i < qrPath.length - 1) {
        pathAnnouncement += ", ";
      }
    }
    pathAnnouncement += ". Please follow the QR path.";
    await _speak(pathAnnouncement, priority: true);
  }

  Future<void> _navigateThroughQrPath(List<String> qrPath, {bool announceFullPath = true, int currentIndex = 0}) async {
    debugPrint("_navigateThroughQrPath: Entered with Path: $qrPath, currentIndex: $currentIndex, announceFullPath: $announceFullPath, _isNewNavigation: $_isNewNavigation, _destinationQrId: $_destinationQrId");
    if (_isStopping || _destinationQrId == null || qrPath.isEmpty) {
      debugPrint("_navigateThroughQrPath: Empty path or no destination, skipping");
      return;
    }

    // Existing logic for path navigation
    if (announceFullPath) {
      await _speak("Destination set to ${_qrData[_destinationQrId!]['name']}. Follow the QR path.", priority: true);
    }

    if (qrPath.isEmpty || _destinationQrId == null) {
      debugPrint("_navigateThroughQrPath: Empty path or no destination, stopping navigation");
      //await _speak("No valid QR path or destination set. Please set a destination.", priority: true);
      await _stopNavigation(silent: true);
      return;
    }

    // Check if at destination
    if (currentIndex >= qrPath.length - 1 && qrPath.last == _destinationQrId) {
      debugPrint("_navigateThroughQrPath: Reached destination: ${qrPath.last}");
      await _navigationAssistant.stop();
      _ttsQueue.clear();
      await _speak("You have reached your destination: ${_qrData[qrPath.last]['name']}.", priority: true);
      await _stopNavigation(silent: true);
      return;
    }

    if (currentIndex >= qrPath.length) {
      debugPrint("_navigateThroughQrPath: Invalid currentIndex $currentIndex for path length ${qrPath.length}");
      await _speak("Invalid path position. Please scan another QR.", priority: true);
      return;
    }

    // Validate QR data
    for (String qrId in qrPath) {
      if (!_qrData.containsKey(qrId)) {
        debugPrint("_navigateThroughQrPath: Invalid QR ID in path: $qrId");
        await _speak("Invalid QR data in path. Please scan a valid QR.", priority: true);
        return;
      }
    }

    // Set up QR waypoints for visualization from currentIndex onward
    List<LatLng> pathPoints = qrPath
        .sublist(currentIndex)
        .map((qrId) => LatLng(
      _qrData[qrId]['current_location'][0],
      _qrData[qrId]['current_location'][1],
    ))
        .toList();

    setState(() {
      _polylines.clear();
      _polylinePoints = pathPoints;
      _polylines.add(Polyline(
        polylineId: const PolylineId('qr_route'),
        points: _polylinePoints,
        color: Colors.green,
        width: 5,
      ));

      // Clear QR markers and add from currentIndex onward
      _markers.removeWhere((marker) => marker.markerId.value.startsWith('qr_'));
      for (String qrId in qrPath.sublist(currentIndex)) {
        LatLng qrPos = LatLng(_qrData[qrId]['current_location'][0], _qrData[qrId]['current_location'][1]);
        _markers.add(Marker(
          markerId: MarkerId('qr_$qrId'),
          position: qrPos,
          infoWindow: InfoWindow(title: _qrData[qrId]['name']),
          icon: qrPinIcon,
        ));
      }
    });

    // Announce the QR path only if requested and it's a new navigation
    if (announceFullPath && _isNewNavigation) {
      await _announceQrPath(qrPath.sublist(currentIndex));
      //await _speak("Navigation started. Follow the QR path to ${_qrData[_destinationQrId!]['name']}.", priority: true);
      setState(() {
        _isNewNavigation = false;
      });
    } else if (_isNewNavigation) {
      await _speak("Navigation started to ${_qrData[_destinationQrId!]['name']}.", priority: true);
      setState(() {
        _isNewNavigation = false;
      });
    }

    // Start navigation with the full QR path and current index
    await _startPathNavigation(qrPath: qrPath, currentIndex: currentIndex);
    debugPrint("_navigateThroughQrPath: Path updated, qrPath: $qrPath, currentIndex: $currentIndex");
  }

  Future<void> _startPathNavigation({List<String>? qrPath, List<String>? directions, int currentIndex = 0}) async {
    debugPrint("_startPathNavigation: qrPath: $qrPath, directions: $directions, currentIndex: $currentIndex, _lastDetectedQrId: $_lastDetectedQrId");

    if ((qrPath == null || qrPath.isEmpty) && (directions == null || directions.isEmpty)) {
      debugPrint("_startPathNavigation: No valid path available");
      await _speak("No valid path available. Please set a destination.", priority: true);
      return;
    }

    // Cancel existing stream to prevent overlap
    if (_positionStream != null) {
      debugPrint("_startPathNavigation: Canceling existing position stream");
      await _positionStream!.cancel();
      _positionStream = null;
    }

    DateTime lastAnnouncement = DateTime.now().subtract(const Duration(seconds: 2));
    int currentStepIndex = currentIndex;
    const double waypointThreshold = 3.0;
    const double finalThreshold = 3.0;
    const double proximityThreshold = 30.0;
    const double headingTolerance = 45.0;
    const int updateInterval = 5; // 4 seconds for frequent updates
    String? lastDirectionText;
    DateTime? proximityAnnounced;

    // Adjust currentStepIndex based on _lastDetectedQrId only if currentIndex is 0
    if (currentIndex == 0 && qrPath != null && qrPath.isNotEmpty && _lastDetectedQrId != null && qrPath.contains(_lastDetectedQrId)) {
      int qrIndex = qrPath.indexOf(_lastDetectedQrId!);
      currentStepIndex = qrIndex < qrPath.length - 1 ? qrIndex + 1 : qrIndex;
      debugPrint("_startPathNavigation: Adjusted currentStepIndex to $currentStepIndex based on _lastDetectedQrId: $_lastDetectedQrId");
    }

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, // Frequent updates
      ),
    ).listen((Position position) async {
      debugPrint("_startPathNavigation: Position update, currentStepIndex: $currentStepIndex, qrPath: $qrPath, _lastDetectedQrId: $_lastDetectedQrId");

      if (!_isNavigating) {
        debugPrint("_startPathNavigation: Navigation stopped: _isNavigating is false");
        await _speak("Navigation interrupted.", priority: true);
        await _positionStream?.cancel();
        _positionStream = null;
        return;
      }

      _getCurrentLocation(position);
      LatLng currentPos = LatLng(position.latitude, position.longitude);

      _provideContextualInfo(position);

      List<LatLng> waypoints = qrPath != null && qrPath.isNotEmpty
          ? qrPath.map((qrId) => LatLng(
        _qrData[qrId]['current_location'][0],
        _qrData[qrId]['current_location'][1],
      )).toList()
          : _polylinePoints;

      if (waypoints.isEmpty) {
        debugPrint("_startPathNavigation: Navigation stopped: Empty waypoints");
        await _speak("Route data is missing. Navigation stopped.", priority: true);
        await _stopNavigation(silent: true);
        await _positionStream?.cancel();
        _positionStream = null;
        return;
      }

      // Check if off-path and recalculate if necessary
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
              debugPrint("_startPathNavigation: Off-path detected, recalculating from $nearestQrId");
              await _speak("You’re off course. Recalculating from ${_qrData[nearestQrId]['name']}.", priority: true);
              await _positionStream?.cancel();
              _positionStream = null;
              await _navigateThroughQrPath(newPath, currentIndex: 0); // Start from beginning of new path
              return;
            }
          }
        }
      }

      // Validate currentStepIndex
      if (qrPath != null && qrPath.isNotEmpty && currentStepIndex >= qrPath.length) {
        debugPrint("_startPathNavigation: Invalid currentStepIndex $currentStepIndex, stopping navigation");
        await _stopNavigation(silent: true);
        await _positionStream?.cancel();
        _positionStream = null;
        return;
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
        // Custom rounding: ≥ X.5 rounds up, < X.5 rounds down
        double decimalPart = turnAngle - turnAngle.floor();
        if (decimalPart >= 0.5) {
          turnAngle = turnAngle.ceilToDouble();
        } else {
          turnAngle = turnAngle.floorToDouble();
        }
        if (turnAngle < headingTolerance) {
          directionText = "Proceed straight";
        } else {
          directionText = relativeBearing <= 180
              ? "Turn right ${turnAngle.toInt()} degrees"
              : "Turn left ${turnAngle.toInt()} degrees";
        }
      }

      final now = DateTime.now();
      if (distanceToNextWaypoint <= waypointThreshold ||
          (currentStepIndex == (qrPath?.length ?? directions!.length) - 1 && distanceToNextWaypoint <= finalThreshold)) {
        if (qrPath != null && qrPath.isNotEmpty) {
          if (currentStepIndex == qrPath.length - 1) {
            // Skip announcement if destination was recently scanned
            if (_lastDetectedQrId == qrPath.last && _lastManualScanTime != null &&
                DateTime.now().difference(_lastManualScanTime!).inSeconds < 10) {
              debugPrint("_startPathNavigation: Skipping destination announcement, handled by handleQRScan");
              await _stopNavigation(silent: true);
              await _positionStream?.cancel();
              _positionStream = null;
              return;
            }
            String destinationName = _qrData[qrPath.last]['name'] ?? 'your destination';
            debugPrint("_startPathNavigation: Reached destination: $destinationName at distance: $distanceToNextWaypoint");
            await _speak("Destination $destinationName has been reached. Navigation has been stopped.", priority: true);
            await _stopNavigation(silent: true);
            await _positionStream?.cancel();
            _positionStream = null;
            return;
          } else {
            String currentQrName = _qrData[qrPath[currentStepIndex]]['name'] ?? qrPath[currentStepIndex];
            String nextQrName = currentStepIndex + 1 < qrPath.length
                ? _qrData[qrPath[currentStepIndex + 1]]['name'] ?? qrPath[currentStepIndex + 1]
                : 'your destination';
            debugPrint("_startPathNavigation: Reached QR: $currentQrName, advancing to $nextQrName");
            await _speak("You have reached $currentQrName by proximity. Proceed to $nextQrName.", priority: true);
            setState(() {
              _lastDetectedQrId = qrPath[currentStepIndex];
              _qrDetected = true;
            });
            _qrDisplayTimer?.cancel();
            _qrDisplayTimer = Timer(const Duration(seconds: 10), () {
              setState(() => _qrDetected = false);
            });
            currentStepIndex++;
            lastDirectionText = null;
          }
        } else {
          if (currentStepIndex == directions!.length - 1) {
            debugPrint("_startPathNavigation: Reached GPS destination at distance: $distanceToNextWaypoint");
            await _speak("You have reached your destination.", priority: true);
            await _stopNavigation(silent: true);
            await _positionStream?.cancel();
            _positionStream = null;
            return;
          } else {
            currentStepIndex++;
            await _speak(_refineDirection(directions![currentStepIndex]), priority: true);
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

        // Skip announcements if TTS is busy with critical speech
        if (_isTtsSpeaking && _currentTtsText != null && _currentTtsText!.contains("detected")) {
          debugPrint("_startPathNavigation: Skipping navigation announcement due to active critical speech");
          return;
        }

        String distanceText = distanceToNextWaypoint < 1000
            ? "${distanceToNextWaypoint.toStringAsFixed(0)} meters"
            : "${(distanceToNextWaypoint / 1000).toStringAsFixed(1)} kilometers";
        String announcement;

        if (qrPath != null && qrPath.isNotEmpty) {
          String nextQrName = _qrData[qrPath[currentStepIndex]]['name'] ?? qrPath[currentStepIndex];
          announcement = "$directionText towards $nextQrName in $distanceText.";
        } else {
          announcement = "$directionText in $distanceText. ${_refineDirection(directions![currentStepIndex])}";
        }

        // Announce if direction changed or time elapsed
        if (lastDirectionText != announcement || now.difference(lastAnnouncement).inSeconds >= updateInterval) {
          debugPrint("_startPathNavigation: Announcing: $announcement");
          await _speak(announcement, priority: true);
          lastDirectionText = announcement;
          lastAnnouncement = now;
        }
      }
    }, onError: (error) async {
      debugPrint("_startPathNavigation: Location stream error: $error");
      await _speak("Error tracking your location. Please ensure GPS is enabled.", priority: true);
    });

    await Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      return _isNavigating;
    });

    debugPrint("_startPathNavigation: Navigation loop ended");
    await _positionStream?.cancel();
    _positionStream = null;
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
        showDialog(
          context: context,
          builder: (BuildContext context) {
            TextEditingController passwordController = TextEditingController();
            return AlertDialog(
              title: const Text('Enter Admin Password'),
              content: TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (passwordController.text == adminPassword) {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => AdminPanelScreen(
                            themeProvider: Provider.of<ThemeProvider>(context, listen: false),
                          ),
                        ),
                      ).then((_) {
                        if (mounted) {
                          _reloadQrData();
                          print('Manual refresh after AdminPanelScreen');
                        }
                      });
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Incorrect password')),
                      );
                      Navigator.of(context).pop();
                    }
                  },
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
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
              onChangeEnd: (value) async {
                await themeProvider.setSpeechRate(value);
                await (context.findAncestorStateOfType<_BlindNavigationAppState>()
                    ?._navigationAssistant
                    ?.updateSpeechRate(value));
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
                border: const OutlineInputBorder(),
                labelText: 'Enter IP Address',
                labelStyle: TextStyle(color: themeProvider.isDarkMode ? Colors.white70 : Colors.black54),
              ),
              style: TextStyle(color: themeProvider.isDarkMode ? Colors.white : Colors.black),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
              _buildDataItem('Version:', 'pro plus', themeProvider), // version checker
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
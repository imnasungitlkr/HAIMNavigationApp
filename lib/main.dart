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
import 'admin_panel.dart';
import 'config.dart';

// Global notifier for QR data changes
final ValueNotifier<bool> qrDataChangedNotifier = ValueNotifier(false);

class ThemeProvider {
  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  Future<void> loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool('isDarkMode') ?? false;
  }

  Future<void> toggleTheme() async {
    _isDarkMode = !_isDarkMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', _isDarkMode);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeProvider = ThemeProvider();
  await themeProvider.loadTheme();
  runApp(MyApp(themeProvider: themeProvider));
}

class MyApp extends StatefulWidget {
  final ThemeProvider themeProvider;
  const MyApp({super.key, required this.themeProvider});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: widget.themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: BlindNavigationApp(themeProvider: widget.themeProvider),
    );
  }
}

class Landmark {
  final String name;
  final LatLng position;

  Landmark(this.name, this.position);
}

class BlindNavigationApp extends StatefulWidget {
  final ThemeProvider themeProvider;
  const BlindNavigationApp({super.key, required this.themeProvider});

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

  final List<Landmark> landmarks = [];

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _initializeTts(); // Ensure TTS is fully initialized first
    await Future.delayed(const Duration(milliseconds: 500)); // Add delay for TTS engine readiness
    _addMarkers();
    await _loadQrData();
    _startLocationUpdates();
    _startDistanceUpdates();
    await _initializeSpeech(); // Speech initialization after TTS
    _setCustomMarkers().then((_) {
      _addMarkers();
    });
    _flutterTts.setCompletionHandler(() {
      print("TTS Speech Completed");
    });
    qrDataChangedNotifier.addListener(_reloadQrData);
  }

  Future<void> _initializeTts() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.5);
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
      if (_speechInitialized) {
        await _startVoiceInteraction(); // Trigger initial prompt on app start
      } else {
        await _speak("Speech recognition could not be initialized.");
      }
    } else {
      await _speak("Microphone permission denied. Voice commands won’t work.");
      print("Microphone permission denied");
    }
  }

  void _stopListeningWithFeedback() async {
    if (_isListening) {
      _speech.stop();
      if (_recognizedText.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _speak("No voice input detected. Please press the microphone button to try again.");
      }
      setState(() {
        _isListening = false;
        _recognizedText = '';
      });
    }
  }

  void _stopListening() {
    if (_isListening) {
      _speech.stop();
      setState(() {
        _isListening = false;
        _recognizedText = '';
      });
    }
  }

  Future<void> _handleGpsSwitchResponse(String response) async {
    _awaitingGpsSwitchResponse = false;
    String normalizedResponse = response.toLowerCase().trim();

    if (normalizedResponse == "yes" && _currentPosition != null && _destination != null) {
      await _speak("Switching to GPS navigation.");
      setState(() {
        _destinationQrId = null; // Disable QR navigation
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

  void _processVoiceCommand(String command) async {
    if (command.isEmpty) return;

    if (_awaitingDestination) {
      await _handleDestinationCommand(command);
      return;
    }

    if (_awaitingGpsSwitchResponse) {
      await _handleGpsSwitchResponse(command);
      return;
    }

    if (command.contains('hello coco')) {
      await _speak("Give Command");
      _stopListening();
      return;
    }

    _stopListening();
    await _processCommand(command);
  }

  Future<void> _startVoiceInteraction() async {
    print("Microphone activated");
    if (_speechInitialized && _ttsInitialized) {
      if (_isListening) {
        _stopListening();
        await Future.delayed(const Duration(milliseconds: 200));
      }
      // Force initial prompt on first call or if not navigating/awaiting
      if (!_isNavigating && !_awaitingDestination) {
        await _speak("How may I help you?");
        await Future.delayed(const Duration(milliseconds: 300));
        await _speak("Microphone is on, speak now.");
        await Future.delayed(const Duration(milliseconds: 300));
      }

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
    } else {
      print("Speech or TTS not initialized yet");
      if (!_speechInitialized) {
        await _speak("Speech recognition is not initialized. Please check permissions.");
      }
    }
  }

  Future<void> _processCommand(String command) async {
    final locationCommands = ['where am i', 'location', 'my position'];
    final destCommands = ['set destination', 'i want to go to', 'go to', 'navigate to'];
    final stopCommands = ['stop navigation', 'end navigation', 'stop'];

    if (locationCommands.any((cmd) => command.contains(cmd))) {
      await _handleWhereAmI();
    } else if (destCommands.any((cmd) => command.contains(cmd))) {
      String dest = command.replaceAll(RegExp(destCommands.join('|'), caseSensitive: false), '').trim();
      if (dest.isNotEmpty) {
        await _handleDestinationCommand(dest);
      } else {
        await _speak("Where to? Say a place like 'Library' or 'Cafeteria.'");
        _awaitingDestination = true;
      }
    } else if (_isNavigating && stopCommands.any((cmd) => command.contains(cmd))) {
      await _stopNavigation();
      await _speak("Navigation stopped.");
    } else {
      await _speak("I didn’t understand that. Please press the microphone button and try again with commands like 'where am I' or 'set destination to Library.'");
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
    double minDistance = double.infinity;
    String nearestQr = '';

    _qrData.forEach((qrId, info) {
      LatLng qrPosition = LatLng(info['current_location'][0], info['current_location'][1]);
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        qrPosition.latitude,
        qrPosition.longitude,
      );
      if (distance < minDistance) {
        minDistance = distance;
        nearestQr = qrId;
      }
    });
    return nearestQr;
  }

  Future<void> _handleDestinationCommand(String destination) async {
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
      await _setDestination(qrId: matchedQrId);
      await _speak("Destination set to ${_qrData[matchedQrId]['name']}. Follow the QR path.");
    } else {
      await _speak("Destination not found. Please press the microphone button and try again with a valid location, like 'Library' or 'Cafeteria.'");
      _awaitingDestination = true;
    }
  }

  Future<void> _speak(String text) async {
    print("Speaking: $text");
    if (!_ttsInitialized) {
      print("TTS not initialized yet, queuing: $text");
      _ttsQueue.add(text);
      return;
    }

    _ttsQueue.add(text);
    await _flutterTts.stop(); // Stop any ongoing speech
    if (_isTtsSpeaking) {
      _isTtsSpeaking = false; // Force reset if stuck
    }

    while (_ttsQueue.isNotEmpty) {
      _isTtsSpeaking = true;
      String next = _ttsQueue.removeFirst();
      Completer<void> completer = Completer<void>();
      _flutterTts.setCompletionHandler(() {
        completer.complete();
      });
      await _flutterTts.speak(next);
      await completer.future.catchError((e) {
        print("TTS error: $e");
        completer.complete();
      });
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _isTtsSpeaking = false;
  }

  Future<void> _loadQrData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? savedQrData = prefs.getString('qrData');
      if (savedQrData != null) {
        setState(() {
          _qrData = jsonDecode(savedQrData);
          buildQrGraph();
        });
      } else {
        String jsonString = await rootBundle.loadString('assets/qrdata.json');
        setState(() {
          _qrData = jsonDecode(jsonString);
          buildQrGraph();
        });
        await prefs.setString('qrData', jsonString);
      }
    } catch (e) {
      print('Error loading QR data: $e');
      _speak("Failed to load QR data.");
    }
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
    _distanceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _fetchDistance();
    });
  }

  Future<void> _fetchDistance() async {
    try {
      final response = await http.get(Uri.parse('http://192.168.46.92:5000/data'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        double newDistance = data['distance_cm'];
        List<String> newDetectedObjects = List<String>.from(data['objects'].map((obj) => obj['object']));

        setState(() {
          _distanceFromSensor = newDistance;
          _detectedObjects = newDetectedObjects;
        });

        if (_distanceFromSensor != null && _distanceFromSensor! < 75) {
          if (await Vibration.hasVibrator()) {
            Vibration.vibrate(duration: 500);
          }
        }

        if (data['qr_codes'] != null && data['qr_codes'].isNotEmpty) {
          for (var qr in data['qr_codes']) {
            if (qr['type'] == "TripuraUni") {
              if (_lastDetectedQrId != qr['qid']) {
                setState(() {
                  _qrDetected = true;
                  _lastDetectedQrId = qr['qid'];
                });
                await handleQRScan(qr['qid']);
              }
              break;
            }
          }
        }
      } else {
        print('Failed to load distance data');
      }
    } catch (e) {
      print('Error fetching distance: $e');
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
        if (path.length > 1) {
          String nextQr = path[1];
          await _speak("You are on the correct path. Next stop: ${_qrData[nextQr]['name']}");
        } else {
          await _speak("You have reached your destination.");
          await _stopNavigation();
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
    } else if (!_isNavigating) {
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

  void handleLocationChange(Position position) {
    if (_destinationQrId != null && _isNavigating) {
      if (_lastDetectedQrId != null) {
        double distanceToLastQR = Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            _qrData[_lastDetectedQrId]['current_location'][0],
            _qrData[_lastDetectedQrId]['current_location'][1]);
        if (distanceToLastQR > 50 && !_awaitingGpsSwitchResponse) {
          _awaitingGpsSwitchResponse = true;
          _speak(
            "You are ${distanceToLastQR.toStringAsFixed(0)} meters away from the QR code. "
                "Please turn back to the QR path, or would you like to switch to GPS navigation? Say 'yes' or 'no'.",
          );
          _startVoiceInteraction();
        }
      } else if (_currentPosition != null) {
        String nearestQr = _findNearestQr(LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
        if (nearestQr.isNotEmpty) {
          double distanceToNearest = Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            _qrData[nearestQr]['current_location'][0],
            _qrData[nearestQr]['current_location'][1],
          );
          if (distanceToNearest < 10) {
            setState(() {
              _lastDetectedQrId = nearestQr;
              _initialQrPosition = LatLng(_qrData[nearestQr]['current_location'][0], _qrData[nearestQr]['current_location'][1]);
            });
            _speak("You are near ${_qrData[nearestQr]['name']}. Using this as your starting QR.");
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
      if (distanceMoved < 2) return; // Existing check
    }

    setState(() {
      _currentPosition = position;
    });

    if (_polylinePoints.isNotEmpty) {
      _updatePolyline(position);
    }

    if (_destination != null && _isNavigating && _destinationQrId == null) {
      // Debounce direction fetching
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
    const double proximityThreshold = 30;
    // Skip if TTS is speaking to avoid overlap with navigation announcements
    if (_isTtsSpeaking) return;

    _qrData.forEach((qrId, qrInfo) {
      LatLng qrPosition = LatLng(qrInfo['current_location'][0], qrInfo['current_location'][1]);
      double distanceToQr = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        qrPosition.latitude,
        qrPosition.longitude,
      );

      if (distanceToQr < proximityThreshold) {
        if (!_visitedLandmarks.contains(qrInfo['name'])) {
          _visitedLandmarks.add(qrInfo['name']);
          _speak("You are near ${qrInfo['name']}.");
          print("Announced QR Location: ${qrInfo['name']}");
        }
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
    _locationTimer?.cancel();
    _distanceTimer?.cancel();
    _qrDisplayTimer?.cancel();
    _stopListening();
    qrDataChangedNotifier.removeListener(_reloadQrData);
    super.dispose();
  }

  Future<void> _fetchAndSpeakDirections(LatLng start, LatLng end) async {
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
          color: Colors.blue,
          width: 5,
        ));
      });

      // Only speak if TTS is not currently speaking
      if (!_isTtsSpeaking) {
        await _speak("Here are your GPS directions:");
      }

      final importantDirections = directions.where((dir) {
        return dir.contains(RegExp(r'turn|continue|merge|exit|left|right|roundabout', caseSensitive: false));
      }).toList();

      for (int i = 0; i < importantDirections.length && _isNavigating; i++) {
        String refinedText = _refineDirection(importantDirections[i]);
        print("Refined Text: $refinedText");
        if (!_isTtsSpeaking) { // Avoid interrupting ongoing speech
          await _speak(refinedText);
          if (i < importantDirections.length - 1 && _isNavigating) {
            await _speak("next");
          }
        }
      }

      if (!_isNavigating) return;
      if (!_isTtsSpeaking) {
        await _speak("over");
      }

      int currentStepIndex = 0;
      double distanceToNextStep = double.infinity;

      while (_isNavigating && currentStepIndex < directions.length) {
        if (_currentPosition == null) {
          await _fetchCurrentLocation();
          continue;
        }

        LatLng currentPos = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
        String step = directions[currentStepIndex];
        String refinedStep = _refineDirection(step);

        if (currentStepIndex < polylinePoints.length) {
          distanceToNextStep = Geolocator.distanceBetween(
            currentPos.latitude,
            currentPos.longitude,
            polylinePoints[currentStepIndex].latitude,
            polylinePoints[currentStepIndex].longitude,
          );
        }

        if (!_isTtsSpeaking) { // Only speak if TTS is idle
          if (distanceToNextStep < 20 || currentStepIndex == 0) {
            await _speak("Now, $refinedStep");
            currentStepIndex++;
          } else {
            await _speak("Continue for ${distanceToNextStep.toStringAsFixed(0)} meters, then $refinedStep");
          }
        }

        await Future.delayed(const Duration(seconds: 5));
        if (_currentPosition != null) {
          _updatePolyline(_currentPosition!);
        }
      }

      if (_isNavigating) {
        if (!_isTtsSpeaking) {
          await _speak("You have arrived at your destination.");
        }
        if (_destinationQrId != null && _currentPosition != null) {
          String nearestQr = _findNearestQr(LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
          if (nearestQr.isNotEmpty) {
            setState(() {
              _lastDetectedQrId = nearestQr;
              _initialQrPosition = LatLng(_qrData[nearestQr]['current_location'][0], _qrData[nearestQr]['current_location'][1]);
            });
            await _navigateThroughQrPath(findShortestPath(nearestQr, _destinationQrId!));
          }
        } else {
          await _stopNavigation();
        }
      }
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

  Future<void> _stopNavigation() async {
    if (_isNavigating) {
      _isNavigating = false;
      await _flutterTts.stop(); // Stop any ongoing TTS
      _ttsQueue.clear(); // Clear all queued messages
      _isTtsSpeaking = false; // Reset speaking flag to force next speak
      setState(() {
        _polylines.clear();
        _markers.removeWhere((marker) => marker.markerId.value == 'destination');
        _destination = null;
        _destinationQrId = null;
        _directionsCache.clear();
        _polylinePoints.clear();
      });
      await _speak("Navigation has been stopped."); // Force this to play immediately
      print("Navigation stopped.");
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
    });

    _loadQrData().then((_) {
      _qrData.forEach((qrId, qrInfo) {
        final position = LatLng(
          qrInfo['current_location'][0],
          qrInfo['current_location'][1],
        );
        setState(() {
          _markers.add(
            Marker(
              markerId: MarkerId(qrId),
              position: position,
              infoWindow: InfoWindow(
                title: qrInfo['name'],
                snippet: qrInfo['context'],
              ),
              icon: qrPinIcon,
            ),
          );
        });
      });
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
      return;
    }

    if (qrId != null && _qrData.containsKey(qrId) && !useGps) {
      if (startQrId != null) {
        await _speak("Starting QR navigation from ${_qrData[startQrId]['name']} to ${_qrData[qrId]['name']}.");
        List<String> qrPath = findShortestPath(startQrId!, qrId);
        if (qrPath.isNotEmpty) {
          await _announceQrPath(qrPath);
          await _speak("Here are your QR directions:");
          for (int i = 0; i < qrPath.length - 1; i++) {
            if (!_isNavigating) return; // Check to exit if stopped
            String currentQr = qrPath[i];
            String nextQr = qrPath[i + 1];
            LatLng currentPos = LatLng(_qrData[currentQr]['current_location'][0], _qrData[currentQr]['current_location'][1]);
            LatLng nextPos = LatLng(_qrData[nextQr]['current_location'][0], _qrData[nextQr]['current_location'][1]);
            var directionsResult = await getDirectionsWithSteps(currentPos, nextPos, apiKey);
            List<String> steps = directionsResult['directions'];

            await _speak("From ${_qrData[currentQr]['name']} to ${_qrData[nextQr]['name']}:");
            for (int j = 0; j < steps.length; j++) {
              if (!_isNavigating) return; // Check to exit if stopped
              String refinedStep = _refineDirection(steps[j]);
              await _speak("Step ${j + 1}: $refinedStep");
              if (j < steps.length - 1) await _speak("next");
            }
            if (i < qrPath.length - 2) await _speak("then proceed to the next QR");
          }
          await _speak("over");
          await _navigateThroughQrPath(qrPath);
        } else {
          await _speak("No direct QR path found from ${_qrData[startQrId]['name']} to ${_qrData[qrId]['name']}. Switching to GPS navigation.");
          await _fetchAndSpeakDirections(start!, _destination!);
        }
      } else if (_currentPosition != null) {
        String nearestQr = _findNearestQr(start!);
        if (nearestQr.isNotEmpty) {
          await _speak("No recent QR detected. Guiding you to the nearest QR: ${_qrData[nearestQr]['name']} to start QR navigation to ${_qrData[qrId]['name']}.");
          await _fetchAndSpeakDirections(
            start!,
            LatLng(_qrData[nearestQr]['current_location'][0], _qrData[nearestQr]['current_location'][1]),
          );
        } else {
          await _speak("No QR codes found nearby. Please scan a QR code to start navigation.");
        }
      } else {
        await _speak("Please scan a QR code or enable GPS to start QR-based navigation to ${_qrData[qrId]['name']}.");
      }
    } else if (gpsDestination != null || useGps) {
      await _speak("Starting GPS navigation from your current location.");
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
      await _speak("You are already at your destination.");
      await _stopNavigation();
      return;
    }

    // Build the polyline for the entire QR path
    List<LatLng> pathPoints = [];
    for (int i = 0; i < qrPath.length - 1; i++) {
      LatLng startPos = LatLng(_qrData[qrPath[i]]['current_location'][0], _qrData[qrPath[i]]['current_location'][1]);
      LatLng endPos = LatLng(_qrData[qrPath[i + 1]]['current_location'][0], _qrData[qrPath[i + 1]]['current_location'][1]);
      var result = await getDirectionsWithSteps(startPos, endPos, apiKey);
      pathPoints.addAll(result['polylinePoints']);
    }

    setState(() {
      _polylines.clear();
      _polylinePoints = pathPoints;
      _polylines.add(Polyline(
        polylineId: const PolylineId('qr_route'),
        points: _polylinePoints,
        color: Colors.green,
        width: 5,
      ));

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

    int currentIndex = qrPath.indexOf(_lastDetectedQrId ?? qrPath[0]);
    if (currentIndex == -1) currentIndex = 0;

    // Start listening to location updates
    StreamSubscription<Position>? positionStream;
    DateTime lastAnnouncement = DateTime.now().subtract(const Duration(seconds: 5));
    double lastDistance = double.infinity;

    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1, // Update every meter
      ),
    ).listen((Position position) async {
      if (!_isNavigating) {
        positionStream?.cancel();
        return;
      }

      _getCurrentLocation(position); // Update current position
      LatLng currentPos = LatLng(position.latitude, position.longitude);

      String nextQrId = qrPath[currentIndex + 1];
      LatLng nextQrPos = LatLng(_qrData[nextQrId]['current_location'][0], _qrData[nextQrId]['current_location'][1]);

      double distanceToNextQr = Geolocator.distanceBetween(
        currentPos.latitude,
        currentPos.longitude,
        nextQrPos.latitude,
        nextQrPos.longitude,
      );

      // Check if user has scanned the next QR code
      if (_lastDetectedQrId == nextQrId) {
        currentIndex++;
        if (currentIndex >= qrPath.length - 1) {
          await _speak("You have reached your destination: ${_qrData[qrPath.last]['name']}.");
          await _stopNavigation();
          positionStream?.cancel();
          return;
        }
        await _speak("QR code ${_qrData[nextQrId]['name']} scanned. Proceeding to next stop.");
        lastAnnouncement = DateTime.now().subtract(const Duration(seconds: 5)); // Force next announcement
        return;
      }

      // Check if user is too far off path
      if (distanceToNextQr > 150) {
        await _speak("You are ${distanceToNextQr.toStringAsFixed(0)} meters off the QR path. Switching to GPS navigation.");
        await _flutterTts.stop(); // Stop any ongoing speech
        _ttsQueue.clear(); // Clear queued speech
        positionStream?.cancel();
        await _fetchAndSpeakDirections(currentPos, _destination!);
        return;
      }

      // Periodic distance updates (every 5 seconds or significant change)
      bool shouldAnnounce = DateTime.now().difference(lastAnnouncement) >= const Duration(seconds: 5) ||
          (lastDistance - distanceToNextQr).abs() > 10;

      if (shouldAnnounce && !_isTtsSpeaking) {
        String announcement;
        if (distanceToNextQr <= 10) {
          announcement = "In ${distanceToNextQr.toStringAsFixed(0)} meters, scan the next QR code at ${_qrData[nextQrId]['name']}.";
        } else {
          announcement = "You are ${distanceToNextQr.toStringAsFixed(0)} meters away from ${_qrData[nextQrId]['name']}. Head forward.";
        }
        await _speak(announcement);
        lastAnnouncement = DateTime.now();
        lastDistance = distanceToNextQr;
      }
    }, onError: (error) {
      print('Location stream error: $error');
      _speak("Error tracking your location. Please ensure GPS is enabled.");
    });

    // Initial announcement
    if (_currentPosition != null) {
      LatLng currentPos = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
      String nextQrId = qrPath[currentIndex + 1];
      double initialDistance = Geolocator.distanceBetween(
        currentPos.latitude,
        currentPos.longitude,
        _qrData[nextQrId]['current_location'][0],
        _qrData[nextQrId]['current_location'][1],
      );
      await _speak("Starting from ${_qrData[qrPath[currentIndex]]['name']}. Your next stop is ${_qrData[nextQrId]['name']} in ${initialDistance.toStringAsFixed(0)} meters.");
    }

    // Wait for navigation to complete or be interrupted
    await Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      return _isNavigating;
    });

    positionStream.cancel();
  }

  // ignore: unused_element: _waitForNextQrOrFallback
  Future<void> _waitForNextQrOrFallback(String expectedQrId, LatLng nextQrPos) async {
    const timeout = Duration(seconds: 120);
    DateTime startTime = DateTime.now();

    while (_isNavigating && _lastDetectedQrId != expectedQrId) {
      if (_currentPosition != null) {
        double distanceToNextQr = Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          nextQrPos.latitude,
          nextQrPos.longitude,
        );
        if (distanceToNextQr > 150) {
          await _speak("You are off the QR path by ${distanceToNextQr.toStringAsFixed(0)} meters. Switching to GPS navigation.");
          await _fetchAndSpeakDirections(
            LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            _destination!,
          );
          return;
        }
      }

      if (DateTime.now().difference(startTime) > timeout) {
        await _speak("No QR detected for 2 minutes. Please scan ${_qrData[expectedQrId]['name']} or I’ll switch to GPS.");
        startTime = DateTime.now();
        await Future.delayed(const Duration(seconds: 10));
        if (_lastDetectedQrId != expectedQrId && _isNavigating) {
          await _fetchAndSpeakDirections(
            _currentPosition != null
                ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
                : nextQrPos,
            _destination!,
          );
          return;
        }
      }

      await Future.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _reloadQrData() async {
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
            builder: (context) => AdminPanelScreen(themeProvider: widget.themeProvider),
          ),
        );
        break;
      case 'Settings':
        Navigator.of(context).push(MaterialPageRoute(
          builder: (context) => SettingsScreen(themeProvider: widget.themeProvider),
        ));
        break;
      case 'Help':
        Navigator.of(context).push(MaterialPageRoute(
          builder: (context) => HelpScreen(themeProvider: widget.themeProvider),
        ));
        break;
      case 'About':
        Navigator.of(context).push(MaterialPageRoute(
          builder: (context) => AboutScreen(themeProvider: widget.themeProvider),
        ));
        break;
    }
  }

  Widget _buildDrawerItem(String title, IconData icon) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      leading: Icon(
        icon,
        color: widget.themeProvider.isDarkMode ? Colors.white : Colors.blue,
      ),
      title: Text(
        title,
        style: TextStyle(color: widget.themeProvider.isDarkMode ? Colors.white : Colors.black),
      ),
      onTap: () => _onDrawerItemTap(title),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Blind Navigation App',
          style: TextStyle(color: Colors.black87),
        ),
        backgroundColor: widget.themeProvider.isDarkMode ? Colors.black87 : Colors.blue,
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
                color: widget.themeProvider.isDarkMode ? Colors.black : Colors.blue,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.7,
                      child: Image.asset('assets/map.png', fit: BoxFit.cover),
                    ),
                  ),
                  Center(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 2.0, sigmaY: 2.0),
                      child: Container(
                        color: Colors.blue.withOpacity(0.2),
                        padding: const EdgeInsets.all(5.0),
                        child: const Text(
                          'Navi App',
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
              markers: _markers,
              polylines: _polylines,
              onTap: (LatLng position) {
                _setDestination(gpsDestination: position);
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
          /*Positioned(
            top: 720,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _recognizedText,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),*/ //removed this for the time being because the need for text bar is low
          Positioned(
            bottom: 5,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: widget.themeProvider.isDarkMode ? Colors.black54 : Colors.black54,
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
                              color: widget.themeProvider.isDarkMode ? Colors.white70 : Colors.white,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _distanceFromSensor != null ? "${_distanceFromSensor!.toStringAsFixed(2)} cm" : "Fetching...",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: widget.themeProvider.isDarkMode ? Colors.white70 : Colors.white,
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
                                color: widget.themeProvider.isDarkMode ? Colors.white70 : Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text("Type: TripuraUni", style: TextStyle(fontSize: 14, color: Colors.white)),
                            Text("ID: $_lastDetectedQrId", style: const TextStyle(fontSize: 14, color: Colors.white)),
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
                              color: widget.themeProvider.isDarkMode ? Colors.white70 : Colors.white,
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
                                    color: widget.themeProvider.isDarkMode ? Colors.white70 : Colors.white,
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
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black87 : Colors.blue,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Customize Your Experience',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.blue,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Adjust settings to suit your preferences.',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: ListTile(
                leading: Icon(
                  Icons.dark_mode,
                  color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.blue,
                  size: 28,
                ),
                title: Text(
                  'Dark Mode',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87,
                  ),
                ),
                trailing: Switch(
                  value: widget.themeProvider.isDarkMode,
                  onChanged: (value) async {
                    await widget.themeProvider.toggleTheme();
                    setState(() {});
                  },
                  activeColor: Colors.blue,
                ),
                tileColor: Theme.of(context).brightness == Brightness.dark ? Colors.grey[800] : Colors.grey[100],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
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
              description: 'For feedback, support, or inquiries, reach out at:\n- Email: imnasungitlkr@gmail.com\n- Email: hasim...... (stay tuned for the full address!)',
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
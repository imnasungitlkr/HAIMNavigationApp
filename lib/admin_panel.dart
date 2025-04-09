import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'main.dart'; // Import ThemeProvider and qrDataChangedNotifier

// AdminPanelScreen: Modern chooser screen for QR Codes and Milestones
class AdminPanelScreen extends StatelessWidget {
  final ThemeProvider themeProvider;

  const AdminPanelScreen({super.key, required this.themeProvider});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: themeProvider.isDarkMode ? Colors.black87 : Colors.blue[700],
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                themeProvider.isDarkMode ? Colors.black54 : Colors.blue[900]!,
                themeProvider.isDarkMode ? Colors.black87 : Colors.blue[500]!,
              ],
            ),
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              themeProvider.isDarkMode ? Colors.grey[850]! : Colors.grey[100]!,
              themeProvider.isDarkMode ? Colors.grey[900]! : Colors.white,
            ],
          ),
        ),
        child: Center(
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            color: themeProvider.isDarkMode ? Colors.grey[800] : Colors.white,
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Select an Option',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: themeProvider.isDarkMode ? Colors.white : Colors.blue[700],
                    ),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => QrCodesScreen(themeProvider: themeProvider),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue[700],
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 4,
                    ),
                    child: const Text('QR Codes', style: TextStyle(fontSize: 18, color: Colors.white)),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => MilestonesScreen(themeProvider: themeProvider),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 4,
                    ),
                    child: const Text('Milestones', style: TextStyle(fontSize: 18, color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// AddQrScreen: Dedicated screen for adding/editing QR codes
class AddQrScreen extends StatefulWidget {
  final ThemeProvider themeProvider;
  final String? editingQrId;
  final Map<String, dynamic>? initialData;

  const AddQrScreen({
    super.key,
    required this.themeProvider,
    this.editingQrId,
    this.initialData,
  });

  @override
  AddQrScreenState createState() => AddQrScreenState();
}

class AddQrScreenState extends State<AddQrScreen> {
  final TextEditingController _qrIdController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lngController = TextEditingController();
  final TextEditingController _contextController = TextEditingController();
  final TextEditingController _neighboursController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.editingQrId != null && widget.initialData != null) {
      _qrIdController.text = widget.editingQrId!;
      _nameController.text = widget.initialData!['name'];
      _latController.text = widget.initialData!['current_location'][0].toString();
      _lngController.text = widget.initialData!['current_location'][1].toString();
      _contextController.text = widget.initialData!['context'];
      _neighboursController.text = (widget.initialData!['neighbours'] as List).join(', ');
    }
  }

  void _saveQr() {
    String qrId = _qrIdController.text.trim();
    String name = _nameController.text.trim();
    String lat = _latController.text.trim();
    String lng = _lngController.text.trim();
    String contextText = _contextController.text.trim();
    String neighbours = _neighboursController.text.trim();

    if (qrId.isEmpty || name.isEmpty || lat.isEmpty || lng.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required fields.')),
      );
      return;
    }

    Navigator.pop(context, {
      'id': qrId,
      'name': name,
      'current_location': [double.parse(lat), double.parse(lng)],
      'context': contextText,
      'neighbours': neighbours.isEmpty ? [] : neighbours.split(',').map((n) => n.trim()).toList(),
    });
  }

  @override
  void dispose() {
    _qrIdController.dispose();
    _nameController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _contextController.dispose();
    _neighboursController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editingQrId == null ? 'Add New QR' : 'Edit QR: ${widget.editingQrId}'),
        backgroundColor: widget.themeProvider.isDarkMode ? Colors.black87 : Colors.blue[700],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Card(
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.all(10.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _qrIdController,
                  decoration: const InputDecoration(
                    labelText: 'QR ID *',
                    hintText: 'e.g., QR001',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name *',
                    hintText: 'e.g., Library',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _latController,
                  decoration: const InputDecoration(
                    labelText: 'Latitude *',
                    hintText: 'e.g., 23.7616',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _lngController,
                  decoration: const InputDecoration(
                    labelText: 'Longitude *',
                    hintText: 'e.g., 91.2621',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _contextController,
                  decoration: const InputDecoration(
                    labelText: 'Context',
                    hintText: 'e.g., Near the main entrance',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _neighboursController,
                  decoration: const InputDecoration(
                    labelText: 'Neighbours (comma-separated IDs)',
                    hintText: 'e.g., QR002, QR003',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _saveQr,
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.cancel),
                      label: const Text('Cancel'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// QrCodesScreen: Dedicated screen for managing QR codes
class QrCodesScreen extends StatefulWidget {
  final ThemeProvider themeProvider;

  const QrCodesScreen({super.key, required this.themeProvider});

  @override
  QrCodesScreenState createState() => QrCodesScreenState();
}

class QrCodesScreenState extends State<QrCodesScreen> {
  Map<String, dynamic> _qrData = {};
  bool _showGraph = false;
  bool _isLoading = true;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  final double _minScale = 0.5;
  final double _maxScale = 3.0;

  @override
  void initState() {
    super.initState();
    _loadQrData();
  }

  Future<void> _loadQrData() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedQrData = prefs.getString('qrData');
    if (savedQrData != null) {
      if (mounted) {
        setState(() {
          _qrData = jsonDecode(savedQrData);
          _isLoading = false;
        });
      }
    } else {
      String jsonString = await rootBundle.loadString('assets/qrdata.json');
      await prefs.setString('qrData', jsonString);
      if (mounted) {
        setState(() {
          _qrData = jsonDecode(jsonString);
          _isLoading = false;
        });
      }
    }
  }

  Future<bool> _saveQrData(Map<String, dynamic> newQrData) async {
    final prefs = await SharedPreferences.getInstance();
    final firestore = FirebaseFirestore.instance;

    if (newQrData['id'].isEmpty || newQrData['name'].isEmpty || newQrData['current_location'][0].isNaN || newQrData['current_location'][1].isNaN) {
      return false;
    }

    String qrId = newQrData['id'];
    if (_qrData.containsKey(qrId) && qrId != _qrData.keys.firstWhere((k) => k == qrId, orElse: () => '')) {
      return false;
    }

    setState(() {
      if (_qrData.containsKey(qrId)) {
        _qrData.remove(qrId);
      }
      _qrData[qrId] = newQrData;
    });

    WriteBatch batch = firestore.batch();
    var docRef = firestore.collection('qr_codes').doc(qrId);
    batch.set(docRef, newQrData, SetOptions(merge: true));
    await batch.commit();

    await prefs.setString('qrData', jsonEncode(_qrData));
    final directory = await getApplicationDocumentsDirectory();
    String saveLocation = '${directory.path}/qr_data.json';
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('QR data saved to cloud and internal storage: $saveLocation')),
      );
    }
    qrDataChangedNotifier.value = !qrDataChangedNotifier.value;
    return true;
  }

  void _editQr(String qrId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddQrScreen(
          themeProvider: widget.themeProvider,
          editingQrId: qrId,
          initialData: _qrData[qrId],
        ),
      ),
    ).then((result) {
      if (result != null && mounted) {
        _saveQrData(result).then((success) {
          if (mounted && !success) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to save QR data due to validation errors.')),
            );
          }
        });
      }
    });
  }

  void _deleteQr(String qrId) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Confirm Deletion'),
          content: Text('Are you sure you want to delete QR code "$qrId"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _qrData.remove(qrId);
                });
                _saveQrData(_qrData);
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  Future<ui.Image> _loadImage(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _showQrDetails(String qrId) {
    var qrInfo = _qrData[qrId];
    String qrDataString = 'TripuraUni:$qrId';

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        final messenger = ScaffoldMessenger.of(context);
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'QR Details: ${qrInfo['name']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Column(
                      children: [
                        QrImageView(
                          data: qrDataString,
                          version: QrVersions.auto,
                          size: 300.0,
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.all(8.0),
                          embeddedImage: const AssetImage('assets/logo.jpeg'),
                          embeddedImageStyle: const QrEmbeddedImageStyle(
                            size: Size(80, 80),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          qrInfo['name'],
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('ID: $qrId', style: const TextStyle(fontSize: 16)),
                  Text('Latitude: ${qrInfo['current_location'][0]}', style: const TextStyle(fontSize: 16)),
                  Text('Longitude: ${qrInfo['current_location'][1]}', style: const TextStyle(fontSize: 16)),
                  Text('Context: ${qrInfo['context']}', style: const TextStyle(fontSize: 16)),
                  Text('Neighbours: ${(qrInfo['neighbours'] as List).join(', ')}', style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () => _editQr(qrId),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                        child: const Text('Edit'),
                      ),
                      ElevatedButton(
                        onPressed: () async {
                          try {
                            final logoImage = await _loadImage('assets/logo.jpeg');
                            final qrPainter = QrPainter(
                              data: qrDataString,
                              version: QrVersions.auto,
                              errorCorrectionLevel: QrErrorCorrectLevel.L,
                              embeddedImage: logoImage,
                              embeddedImageStyle: const QrEmbeddedImageStyle(
                                size: Size(80, 80),
                              ),
                            );
                            final qrImage = await qrPainter.toImage(600);

                            final recorder = ui.PictureRecorder();
                            final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 600, 700));
                            canvas.drawColor(Colors.white, BlendMode.srcOver);
                            canvas.drawImage(qrImage, Offset.zero, Paint());

                            final textPainter = TextPainter(
                              text: TextSpan(
                                text: qrInfo['name'],
                                style: const TextStyle(color: Colors.black, fontSize: 40, fontWeight: FontWeight.bold),
                              ),
                              textDirection: TextDirection.ltr,
                            );
                            textPainter.layout(maxWidth: 600);
                            textPainter.paint(canvas, Offset((600 - textPainter.width) / 2, 620));

                            final picture = recorder.endRecording();
                            final finalImage = await picture.toImage(600, 700);
                            final buffer = await finalImage.toByteData(format: ui.ImageByteFormat.png);
                            final bytes = buffer!.buffer.asUint8List();

                            final directory = await getTemporaryDirectory();
                            final filePath = '${directory.path}/qr_$qrId.jpg';
                            final file = File(filePath);
                            await file.writeAsBytes(bytes);

                            final result = await SaverGallery.saveImage(
                              bytes,
                              fileName: 'qr_$qrId.jpg',
                              skipIfExists: false,
                            );

                            if (result.isSuccess) {
                              messenger.showSnackBar(
                                SnackBar(content: Text('QR code saved to gallery: $filePath')),
                              );
                            } else {
                              messenger.showSnackBar(
                                SnackBar(content: Text('Failed to save QR code: ${result.errorMessage}')),
                              );
                            }
                          } catch (e) {
                            messenger.showSnackBar(
                              SnackBar(content: Text('Error downloading QR code: $e')),
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                        child: const Text('Download QR Code'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _toggleGraph() {
    setState(() {
      _showGraph = !_showGraph;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('QR Codes'),
        backgroundColor: widget.themeProvider.isDarkMode ? Colors.black87 : Colors.blue[700],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.8,
                child: _showGraph ? _buildGraphView() : _buildQrList(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AddQrScreen(themeProvider: widget.themeProvider),
                      ),
                    ).then((result) {
                      if (result != null && mounted) {
                        _saveQrData(result).then((success) {
                          if (mounted && !success) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Failed to save QR data due to validation errors.')),
                            );
                          }
                        });
                      }
                    });
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.purple[300]),
                  child: const Text('Add New QR'),
                ),
                ElevatedButton(
                  onPressed: _toggleGraph,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[400]),
                  child: Text(_showGraph ? 'Show List' : 'Show Graph'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrList() {
    return ListView.builder(
      itemCount: _qrData.length,
      itemBuilder: (context, index) {
        String qrId = _qrData.keys.elementAt(index);
        var qrInfo = _qrData[qrId];
        return ListTile(
          title: Text(qrInfo['name']),
          subtitle: Text('ID: $qrId'),
          onTap: () => _showQrDetails(qrId),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit, color: Colors.blue),
                onPressed: () => _editQr(qrId),
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () => _deleteQr(qrId),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGraphView() {
    return GestureDetector(
      onScaleUpdate: (ScaleUpdateDetails details) {
        setState(() {
          double newScale = (_scale * details.scale).clamp(_minScale, _maxScale);
          Offset delta = details.focalPointDelta / _scale;
          _offset = _offset + delta;
          Offset focalPoint = details.focalPoint;
          _offset = (_offset - focalPoint / _scale) + (focalPoint / newScale);
          _scale = newScale;
        });
      },
      child: CustomPaint(
        painter: GraphPainter(_qrData, _scale, _offset),
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
          ),
        ),
      ),
    );
  }
}

// AddMilestoneScreen: Dedicated screen for adding/editing milestones
class AddMilestoneScreen extends StatefulWidget {
  final ThemeProvider themeProvider;
  final String? editingMilestoneId;
  final Map<String, dynamic>? initialData;

  const AddMilestoneScreen({
    super.key,
    required this.themeProvider,
    this.editingMilestoneId,
    this.initialData,
  });

  @override
  AddMilestoneScreenState createState() => AddMilestoneScreenState();
}

class AddMilestoneScreenState extends State<AddMilestoneScreen> {
  final TextEditingController _milestoneIdController = TextEditingController();
  final TextEditingController _milestoneLatController = TextEditingController();
  final TextEditingController _milestoneLngController = TextEditingController();
  List<Map<String, TextEditingController>> _milestoneContextPairs = [
    {'qrId': TextEditingController(), 'direction': TextEditingController()}
  ];

  @override
  void initState() {
    super.initState();
    if (widget.editingMilestoneId != null && widget.initialData != null) {
      _milestoneIdController.text = widget.editingMilestoneId!;
      _milestoneLatController.text = widget.initialData!['Location'][0].toString();
      _milestoneLngController.text = widget.initialData!['Location'][1].toString();
      _milestoneContextPairs = (widget.initialData!['context'] as List).map((e) {
        return {
          'qrId': TextEditingController(text: e.keys.first),
          'direction': TextEditingController(text: e.values.first),
        };
      }).toList();
      if (_milestoneContextPairs.isEmpty) {
        _milestoneContextPairs.add({'qrId': TextEditingController(), 'direction': TextEditingController()});
      }
    }
  }

  void _saveMilestone() {
    String milestoneId = _milestoneIdController.text.trim();
    String lat = _milestoneLatController.text.trim();
    String lng = _milestoneLngController.text.trim();

    if (milestoneId.isEmpty || lat.isEmpty || lng.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required milestone fields.')),
      );
      return;
    }

    List<Map<String, String>> contextPairs = _milestoneContextPairs
        .where((pair) => pair['qrId']!.text.isNotEmpty && pair['direction']!.text.isNotEmpty)
        .map((pair) => {pair['qrId']!.text.trim(): pair['direction']!.text.trim()})
        .toList();

    Navigator.pop(context, {
      'id': milestoneId,
      'Location': [double.parse(lat), double.parse(lng)],
      'context': contextPairs,
    });
  }

  void _addContextPair() {
    setState(() {
      _milestoneContextPairs.add({'qrId': TextEditingController(), 'direction': TextEditingController()});
    });
  }

  void _removeContextPair(int index) {
    setState(() {
      if (_milestoneContextPairs.length > 1) {
        _milestoneContextPairs[index]['qrId']?.dispose();
        _milestoneContextPairs[index]['direction']?.dispose();
        _milestoneContextPairs.removeAt(index);
      }
    });
  }

  @override
  void dispose() {
    _milestoneIdController.dispose();
    _milestoneLatController.dispose();
    _milestoneLngController.dispose();
    for (var pair in _milestoneContextPairs) {
      pair['qrId']?.dispose();
      pair['direction']?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editingMilestoneId == null ? 'Add New Milestone' : 'Edit Milestone: ${widget.editingMilestoneId}'),
        backgroundColor: widget.themeProvider.isDarkMode ? Colors.black87 : Colors.green[700],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Card(
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.all(10.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _milestoneIdController,
                  decoration: const InputDecoration(
                    labelText: 'Milestone ID *',
                    hintText: 'e.g., QB91',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _milestoneLatController,
                  decoration: const InputDecoration(
                    labelText: 'Latitude *',
                    hintText: 'e.g., 23.2323232',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _milestoneLngController,
                  decoration: const InputDecoration(
                    labelText: 'Longitude *',
                    hintText: 'e.g., 91.123432',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                const Text('Context Pairs', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ..._milestoneContextPairs.asMap().entries.map((entry) {
                  int index = entry.key;
                  var pair = entry.value;
                  return Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: pair['qrId'],
                          decoration: const InputDecoration(
                            labelText: 'QR ID',
                            hintText: 'e.g., QB9',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: pair['direction'],
                          decoration: const InputDecoration(
                            labelText: 'Direction',
                            hintText: 'e.g., STRAIGHT',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove_circle, color: Colors.red),
                        onPressed: () => _removeContextPair(index),
                      ),
                    ],
                  );
                }),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _addContextPair,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Context Pair'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _saveMilestone,
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.cancel),
                      label: const Text('Cancel'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// MilestonesScreen: Dedicated screen for managing milestones
class MilestonesScreen extends StatefulWidget {
  final ThemeProvider themeProvider;

  const MilestonesScreen({super.key, required this.themeProvider});

  @override
  MilestonesScreenState createState() => MilestonesScreenState();
}

class MilestonesScreenState extends State<MilestonesScreen> {
  Map<String, dynamic> _milestoneData = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMilestoneData();
  }

  Future<void> _loadMilestoneData() async {
    final prefs = await SharedPreferences.getInstance();
    final firestore = FirebaseFirestore.instance;
    String? savedMilestoneData = prefs.getString('milestoneData');
    if (savedMilestoneData != null) {
      if (mounted) {
        setState(() {
          _milestoneData = jsonDecode(savedMilestoneData);
          _isLoading = false;
        });
      }
    } else {
      QuerySnapshot milestoneSnapshot = await firestore.collection('milestones').get();
      Map<String, dynamic> tempMilestoneData = {};
      for (var doc in milestoneSnapshot.docs) {
        tempMilestoneData[doc.id] = doc.data() as Map<String, dynamic>;
      }
      if (mounted) {
        setState(() {
          _milestoneData = tempMilestoneData;
          _isLoading = false;
        });
      }
      await prefs.setString('milestoneData', jsonEncode(_milestoneData));
    }
  }

  Future<bool> _saveMilestoneData(Map<String, dynamic> newMilestoneData) async {
    final prefs = await SharedPreferences.getInstance();
    final firestore = FirebaseFirestore.instance;

    if (newMilestoneData['id'].isEmpty || newMilestoneData['Location'][0].isNaN || newMilestoneData['Location'][1].isNaN) {
      return false;
    }

    String milestoneId = newMilestoneData['id'];
    if (_milestoneData.containsKey(milestoneId) && milestoneId != _milestoneData.keys.firstWhere((k) => k == milestoneId, orElse: () => '')) {
      return false;
    }

    setState(() {
      if (_milestoneData.containsKey(milestoneId)) {
        _milestoneData.remove(milestoneId);
      }
      _milestoneData[milestoneId] = newMilestoneData;
    });

    WriteBatch batch = firestore.batch();
    var docRef = firestore.collection('milestones').doc(milestoneId);
    batch.set(docRef, newMilestoneData, SetOptions(merge: true));
    await batch.commit();

    await prefs.setString('milestoneData', jsonEncode(_milestoneData));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Milestone data saved to cloud and local storage')),
      );
    }
    return true;
  }

  void _editMilestone(String milestoneId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddMilestoneScreen(
          themeProvider: widget.themeProvider,
          editingMilestoneId: milestoneId,
          initialData: _milestoneData[milestoneId],
        ),
      ),
    ).then((result) {
      if (result != null && mounted) {
        _saveMilestoneData(result).then((success) {
          if (mounted && !success) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to save milestone data due to validation errors.')),
            );
          }
        });
      }
    });
  }

  void _deleteMilestone(String milestoneId) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Confirm Deletion'),
          content: Text('Are you sure you want to delete milestone "$milestoneId"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _milestoneData.remove(milestoneId);
                });
                _saveMilestoneData(_milestoneData);
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  void _showMilestoneDetails(String milestoneId) {
    var milestoneInfo = _milestoneData[milestoneId];
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Milestone Details: $milestoneId',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  Text('ID: $milestoneId', style: const TextStyle(fontSize: 16)),
                  Text('Latitude: ${milestoneInfo['Location'][0]}', style: const TextStyle(fontSize: 16)),
                  Text('Longitude: ${milestoneInfo['Location'][1]}', style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 8),
                  const Text('Context:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ...((milestoneInfo['context'] as List).map((e) => Text(
                    '${e.keys.first}: ${e.values.first}',
                    style: const TextStyle(fontSize: 16),
                  ))),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () => _editMilestone(milestoneId),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                        child: const Text('Edit'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Milestones'),
        backgroundColor: widget.themeProvider.isDarkMode ? Colors.black87 : Colors.green[700],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.8,
                child: _buildMilestoneList(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AddMilestoneScreen(themeProvider: widget.themeProvider),
                  ),
                ).then((result) {
                  if (result != null && mounted) {
                    _saveMilestoneData(result).then((success) {
                      if (mounted && !success) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Failed to save milestone data due to validation errors.')),
                        );
                      }
                    });
                  }
                });
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green[300]),
              child: const Text('Add New Milestone'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMilestoneList() {
    return ListView.builder(
      itemCount: _milestoneData.length,
      itemBuilder: (context, index) {
        String milestoneId = _milestoneData.keys.elementAt(index);
        var milestoneInfo = _milestoneData[milestoneId];
        return ListTile(
          title: Text('Milestone: $milestoneId'),
          subtitle: Text('Lat: ${milestoneInfo['Location'][0]}, Lng: ${milestoneInfo['Location'][1]}'),
          onTap: () => _showMilestoneDetails(milestoneId),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit, color: Colors.blue),
                onPressed: () => _editMilestone(milestoneId),
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () => _deleteMilestone(milestoneId),
              ),
            ],
          ),
        );
      },
    );
  }
}

// GraphPainter: Reused for QR Codes screen
class GraphPainter extends CustomPainter {
  final Map<String, dynamic> qrData;
  final double scale;
  final Offset offset;

  GraphPainter(this.qrData, this.scale, this.offset);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    double minLat = double.infinity, maxLat = -double.infinity;
    double minLng = double.infinity, maxLng = -double.infinity;
    qrData.forEach((_, info) {
      double lat = info['current_location'][0];
      double lng = info['current_location'][1];
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    });

    canvas.save();
    canvas.translate(offset.dx * scale, offset.dy * scale);
    canvas.scale(scale, scale);

    Map<String, Offset> positions = {};
    qrData.forEach((qrId, info) {
      double lat = info['current_location'][0];
      double lng = info['current_location'][1];
      double x = ((lng - minLng) / (maxLng - minLng)) * size.width;
      double y = size.height - ((lat - minLat) / (maxLat - minLat)) * size.height;
      positions[qrId] = Offset(x, y);

      canvas.drawCircle(positions[qrId]!, 5, paint);

      textPainter.text = TextSpan(
        text: info['name'],
        style: const TextStyle(color: Colors.black),
      );
      textPainter.layout();
      textPainter.paint(canvas, positions[qrId]! + const Offset(10, -5));
    });

    qrData.forEach((qrId, info) {
      List<String> neighbours = List<String>.from(info['neighbours']);
      for (String neighbour in neighbours) {
        if (positions.containsKey(neighbour)) {
          canvas.drawLine(positions[qrId]!, positions[neighbour]!, paint);
        }
      }
    });

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
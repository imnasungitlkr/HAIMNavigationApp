import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui; // Explicitly import for image processing
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart' show rootBundle; // Add this for loading assets

import 'main.dart'; // Import ThemeProvider and qrDataChangedNotifier

class AdminPanelScreen extends StatefulWidget {
  final ThemeProvider themeProvider;
  const AdminPanelScreen({super.key, required this.themeProvider});

  @override
  AdminPanelScreenState createState() => AdminPanelScreenState();
}

class AdminPanelScreenState extends State<AdminPanelScreen> {
  Map<String, dynamic> _qrData = {};
  final TextEditingController _qrIdController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lngController = TextEditingController();
  final TextEditingController _contextController = TextEditingController();
  final TextEditingController _neighboursController = TextEditingController();
  String? _editingQrId;
  bool _showGraph = false;
  bool _isLoading = true;
  bool _showForm = false; // Controls form visibility

  // Variables for zoom and pan functionality
  double _scale = 1.0; // Zoom scale (1.0 is default)
  Offset _offset = Offset.zero; // Pan offset
  final double _minScale = 0.5; // Minimum zoom level
  final double _maxScale = 3.0; // Maximum zoom level

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
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) {
          String jsonString = await DefaultAssetBundle.of(context).loadString('assets/qrdata.json');
          await prefs.setString('qrData', jsonString);
          setState(() {
            _qrData = jsonDecode(jsonString);
            _isLoading = false;
          });
        }
      });
    }
  }

  Future<void> _saveQrData() async {
    final prefs = await SharedPreferences.getInstance();
    final firestore = FirebaseFirestore.instance;

    // Save to Firestore using a batch for efficiency
    WriteBatch batch = firestore.batch();
    _qrData.forEach((qrId, qrInfo) {
      var docRef = firestore.collection('qr_codes').doc(qrId);
      batch.set(docRef, {
        'id': qrId,
        'name': qrInfo['name'],
        'current_location': qrInfo['current_location'],
        'context': qrInfo['context'],
        'neighbours': qrInfo['neighbours'],
      }, SetOptions(merge: true));
    });
    await batch.commit();

    // Save locally
    await prefs.setString('qrData', jsonEncode(_qrData));
    final directory = await getApplicationDocumentsDirectory();
    String saveLocation = '${directory.path}/qr_data.json';
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('QR data saved to cloud and internal storage: $saveLocation')),
      );
    }
    _clearFields();
    qrDataChangedNotifier.value = !qrDataChangedNotifier.value; // Notify listeners of QR data change
  }

  void _clearFields() {
    _qrIdController.clear();
    _nameController.clear();
    _latController.clear();
    _lngController.clear();
    _contextController.clear();
    _neighboursController.clear();
    setState(() {
      _editingQrId = null;
      _showForm = false; // Hide form after saving or canceling
    });
  }

  void _addOrUpdateQr() {
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

    if (_editingQrId != null && _editingQrId != qrId && _qrData.containsKey(qrId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QR ID already exists.')),
      );
      return;
    }

    setState(() {
      if (_editingQrId != null && _editingQrId != qrId) {
        _qrData.remove(_editingQrId);
      }
      _qrData[qrId] = {
        'name': name,
        'current_location': [double.parse(lat), double.parse(lng)],
        'context': contextText,
        'neighbours': neighbours.isEmpty ? [] : neighbours.split(',').map((n) => n.trim()).toList(),
      };
    });

    _saveQrData();
  }

  void _editQr(String qrId) {
    var qrInfo = _qrData[qrId];
    _qrIdController.text = qrId;
    _nameController.text = qrInfo['name'];
    _latController.text = qrInfo['current_location'][0].toString();
    _lngController.text = qrInfo['current_location'][1].toString();
    _contextController.text = qrInfo['context'];
    _neighboursController.text = (qrInfo['neighbours'] as List).join(', ');
    setState(() {
      _editingQrId = qrId;
      _showForm = true; // Show form when editing
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
                _saveQrData();
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
    String qrDataString = 'TripuraUni:$qrId'; // Updated to match previous QR encoding

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        final messenger = ScaffoldMessenger.of(context); // Store ScaffoldMessengerState
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
                          size: 300.0, // Increased for high quality
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.all(8.0),
                          embeddedImage: const AssetImage('assets/logo.jpeg'),
                          embeddedImageStyle: const QrEmbeddedImageStyle(
                            size: Size(80, 80), // Larger logo for clarity
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
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          _editQr(qrId);
                        },
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
                            final qrImage = await qrPainter.toImage(600); // High quality QR

                            // Create canvas to draw QR and text
                            final recorder = ui.PictureRecorder();
                            final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 600, 700)); // Extra height for text
                            canvas.drawColor(Colors.white, BlendMode.srcOver); // White background
                            canvas.drawImage(qrImage, Offset.zero, Paint()); // Draw QR at top

                            // Draw QR name below
                            final textPainter = TextPainter(
                              text: TextSpan(
                                text: qrInfo['name'],
                                style: const TextStyle(color: Colors.black, fontSize: 40, fontWeight: FontWeight.bold),
                              ),
                              textDirection: TextDirection.ltr,
                            );
                            textPainter.layout(maxWidth: 600);
                            textPainter.paint(canvas, Offset((600 - textPainter.width) / 2, 620)); // Center below QR

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
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Admin Panel'),
        backgroundColor: widget.themeProvider.isDarkMode ? Colors.black87 : Colors.blue,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (_showForm)
              Expanded(
                flex: 40, // Step 1: Increase flex to give more space to the form
                child: SingleChildScrollView(
                  child: _buildQrInputForm(),
                ),
              ),
            Expanded(
              flex: 1, // Step 2: Keep list/graph view smaller
              child: _showGraph ? _buildGraphView() : _buildQrList(),
            ),
            if (_showForm) _buildActionButtons(),
            if (!_showForm)
              Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _clearFields();
                          _showForm = true;
                        });
                      },
                      child: const Text('Add New QR'),
                    ),
                    ElevatedButton(
                      onPressed: _toggleGraph,
                      child: Text(_showGraph ? 'Show List' : 'Show Graph'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrInputForm() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _editingQrId == null ? 'Add New QR' : 'Edit QR: $_editingQrId',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
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
          ],
        ),
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
      // Handle both panning and scaling with onScaleUpdate
      onScaleUpdate: (ScaleUpdateDetails details) {
        setState(() {
          // Update scale (zoom)
          double newScale = (_scale * details.scale).clamp(_minScale, _maxScale);

          // Update offset (pan) using focalPointDelta
          Offset delta = details.focalPointDelta / _scale;
          _offset = _offset + delta;

          // Adjust offset to zoom around the focal point
          Offset focalPoint = details.focalPoint;
          _offset = (_offset - focalPoint / _scale) + (focalPoint / newScale);

          // Apply the new scale
          _scale = newScale;
        });
      },
      child: CustomPaint(
        painter: GraphPainter(_qrData, _scale, _offset),
        child: Container(
          width: double.infinity,
          height: double.infinity, // Ensure it fills available space
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons({
    double buttonWidth = 120.0,
    double buttonHeight = 48.0,
    double horizontalPadding = 8.0,
    double verticalPadding = 8.0,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          SizedBox(
            width: buttonWidth,
            height: buttonHeight,
            child: ElevatedButton.icon(
              onPressed: _addOrUpdateQr,
              icon: const Icon(Icons.save),
              label: Text(_editingQrId == null ? 'Save New QR' : 'Update QR'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          if (_editingQrId != null)
            SizedBox(
              width: buttonWidth,
              height: buttonHeight,
              child: ElevatedButton.icon(
                onPressed: _clearFields,
                icon: const Icon(Icons.cancel),
                label: const Text('Cancel Edit'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          SizedBox(
            width: buttonWidth,
            height: buttonHeight,
            child: ElevatedButton.icon(
              onPressed: _clearFields,
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear Fields'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GraphPainter extends CustomPainter {
  final Map<String, dynamic> qrData;
  final double scale; // Zoom scale
  final Offset offset; // Pan offset

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

    // Apply scale and offset transformations
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

    canvas.restore(); // Restore the canvas state after transformations
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:HAIM_Navigation/main.dart'; // Ensure this matches your package name
import 'package:shared_preferences/shared_preferences.dart'; // For mocking SharedPreferences
import 'package:provider/provider.dart'; // Import provider package for ChangeNotifierProvider

void main() {
  // Setup mock for SharedPreferences before all tests
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'isDarkMode': false});
  });

  // Test to verify that BlindNavigationApp loads correctly
  testWidgets('BlindNavigationApp loads correctly', (WidgetTester tester) async {
    // Create and initialize ThemeProvider
    final themeProvider = ThemeProvider();
    await themeProvider.loadTheme(); // Load theme preferences from mock

    // Build the app with ChangeNotifierProvider and trigger a frame
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => themeProvider,
        child: const MyApp(),
      ),
    );
    await tester.pumpAndSettle(); // Wait for all async operations to complete

    // Verify that the app bar title is present
    expect(find.text('Blind Navigation App'), findsOneWidget);

    // Verify that the map type button is present
    expect(find.byIcon(Icons.map), findsOneWidget);

    // Verify that the microphone button is present
    expect(find.byIcon(Icons.mic), findsOneWidget);

    // Verify that the location button is present
    expect(find.byIcon(Icons.my_location), findsOneWidget);
  });
}
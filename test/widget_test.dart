import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:HAIM_Navigation/main.dart'; // Updated to match your package name
import 'package:shared_preferences/shared_preferences.dart'; // For mocking SharedPreferences

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

    // Build the app and trigger a frame
    await tester.pumpWidget(MyApp(themeProvider: themeProvider));
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
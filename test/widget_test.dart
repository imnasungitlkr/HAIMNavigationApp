import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blind_navigation_flutter/main.dart'; // Ensure this matches your file structure
import 'package:shared_preferences/shared_preferences.dart'; // For mocking SharedPreferences

void main() {
  // Setup mock for SharedPreferences
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'isDarkMode': false});
  });

  testWidgets('BlindNavigationApp loads correctly', (WidgetTester tester) async {
    // Create and initialize ThemeProvider
    final themeProvider = ThemeProvider();
    await themeProvider.loadTheme(); // Load theme preferences

    // Build our app and trigger a frame
    await tester.pumpWidget(MyApp(themeProvider: themeProvider));

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
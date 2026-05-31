import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:macino/main.dart';

void main() {
  testWidgets('shows local screen sharing controls', (tester) async {
    await tester.pumpWidget(const LocalScreenShareApp());

    expect(find.text('Macino'), findsOneWidget);
    expect(find.text('Start Sharing'), findsOneWidget);
    expect(find.text('Stop Sharing'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });
}

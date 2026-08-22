import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh_ui/playmesh_ui.dart';

void main() {
  testWidgets('renders only the Playmesh mark and loading indicator', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PlaymeshLoadingView()));

    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Text), findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Playmesh loading')),
      matchesSemantics(label: 'Playmesh loading', isLiveRegion: true),
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privai/ui/theme.dart';
import 'package:privai/ui/voice_conversation_page.dart';

void main() {
  testWidgets('shows the full-screen voice state and stop control',
      (tester) async {
    final status = ValueNotifier('Listening…');
    final level = ValueNotifier(0.5);
    final active = ValueNotifier(true);
    var stopped = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: VoiceConversationPage(
          status: status,
          level: level,
          active: active,
          onStop: () async {
            stopped = true;
            active.value = false;
          },
        ),
      ),
    );

    expect(find.byKey(const ValueKey('voice_orb')), findsOneWidget);
    expect(find.text('Listening…'), findsOneWidget);
    expect(find.text('End conversation'), findsOneWidget);

    status.value = 'Responding…';
    await tester.pump();
    expect(find.text('Responding…'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stop_voice_conversation')));
    await tester.pump();
    expect(stopped, isTrue);

    await tester.pumpWidget(const SizedBox());
    status.dispose();
    level.dispose();
    active.dispose();
  });
}

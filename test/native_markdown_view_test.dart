import 'package:fls_for_android/widgets/native_markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders rich markdown and copies fenced code', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: const NativeMarkdownView(
              data: '''
# Setup

A **formatted** paragraph with `inline code`.

- First item
- Second item

> A note for the reader.

| Name | Value |
| --- | --- |
| Mode | Full |

![Architecture diagram](https://example.com/diagram.png)

```dart
void main() {}
```
''',
            ),
          ),
        ),
      ),
    );

    expect(_selectableText('Setup'), findsOneWidget);
    expect(_selectableText('First item'), findsOneWidget);
    expect(_selectableText('A note for the reader.'), findsOneWidget);
    expect(find.text('Architecture diagram'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data ?? widget.textSpan?.toPlainText()) ==
                'A formatted paragraph with inline code.',
      ),
      findsOneWidget,
    );
    expect(find.byType(Table), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);

    await tester.tap(find.byTooltip('复制代码'));
    await tester.pump();

    expect(clipboardText, 'void main() {}');
    expect(find.text('代码已复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('supports heading anchors and only opens HTTPS links', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final openedLinks = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: NativeMarkdownView(
              data:
                  '''
# Start

[Jump to the details](#details)

[Open safe link](https://example.com/docs)

[Reject unsafe link](javascript:alert(1))

${List.filled(16, 'A paragraph above the target section.').join('\n\n')}

## Details

Target content.
''',
              onOpenExternalLink: (uri) async => openedLinks.add(uri),
            ),
          ),
        ),
      ),
    );

    await tester.tap(_selectableText('Open safe link'));
    expect(openedLinks, [Uri.parse('https://example.com/docs')]);

    await tester.tap(_selectableText('Reject unsafe link'));
    await tester.pump();
    expect(openedLinks, hasLength(1));
    expect(find.text('仅支持打开 HTTPS 链接'), findsOneWidget);

    final targetHeading = _selectableText('Details');
    final topBeforeJump = tester.getTopLeft(targetHeading).dy;
    await tester.tap(_selectableText('Jump to the details'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(targetHeading).dy, lessThan(topBeforeJump));
    expect(find.text('未找到文档章节'), findsNothing);
  });
}

Finder _selectableText(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is SelectableText &&
      (widget.data ?? widget.textSpan?.toPlainText()) == text,
);

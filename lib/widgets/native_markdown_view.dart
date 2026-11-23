import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

class NativeMarkdownView extends StatefulWidget {
  const NativeMarkdownView({
    super.key,
    required this.data,
    this.onOpenExternalLink,
  });

  final String data;
  final Future<void> Function(Uri uri)? onOpenExternalLink;

  @override
  State<NativeMarkdownView> createState() => _NativeMarkdownViewState();
}

class _NativeMarkdownViewState extends State<NativeMarkdownView> {
  Map<String, GlobalKey> _headingKeys = {};

  @override
  void initState() {
    super.initState();
    _rebuildHeadingKeys();
  }

  @override
  void didUpdateWidget(covariant NativeMarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _rebuildHeadingKeys();
  }

  void _rebuildHeadingKeys() {
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubWeb);
    final nodes = document.parse(widget.data);
    final keys = <String, GlobalKey>{};
    final occurrences = <String, int>{};

    void visit(md.Node node) {
      if (node is! md.Element) return;
      if (RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
        final baseId = node.attributes['id'] ?? node.generatedId;
        if (baseId != null && baseId.isNotEmpty) {
          final occurrence = occurrences.update(
            baseId,
            (count) => count + 1,
            ifAbsent: () => 0,
          );
          final id = occurrence == 0 ? baseId : '$baseId-$occurrence';
          keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'markdown-$id'));
        }
      }
      for (final child in node.children ?? const <md.Node>[]) {
        visit(child);
      }
    }

    for (final node in nodes) {
      visit(node);
    }
    _headingKeys = keys;
  }

  Future<void> _handleLink(String? href) async {
    if (href == null || href.isEmpty) return;
    if (href.startsWith('#')) {
      String anchor;
      try {
        anchor = Uri.decodeComponent(href.substring(1));
      } on FormatException {
        _showMessage('文档锚点无效');
        return;
      }
      final context = _headingKeys[anchor]?.currentContext;
      if (context == null) {
        _showMessage('未找到文档章节');
        return;
      }
      await Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: 0.08,
      );
      return;
    }

    final uri = Uri.tryParse(href);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _showMessage('仅支持打开 HTTPS 链接');
      return;
    }
    try {
      if (widget.onOpenExternalLink != null) {
        await widget.onOpenExternalLink!(uri);
      } else if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        _showMessage('无法打开链接');
      }
    } catch (_) {
      _showMessage('无法打开链接');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final headings = _MarkdownHeadingBuilder(_headingKeys);
    final styleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      a: theme.textTheme.bodyMedium?.copyWith(
        color: colors.primary,
        decoration: TextDecoration.underline,
        decorationColor: colors.primary.withValues(alpha: 0.6),
      ),
      p: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
      h1: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      h2: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      h3: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      code: theme.textTheme.bodyMedium?.copyWith(
        color: colors.onSurface,
        backgroundColor: colors.surfaceContainerHigh,
        fontFamily: 'monospace',
      ),
      blockquote: theme.textTheme.bodyMedium?.copyWith(
        color: colors.onSurfaceVariant,
      ),
      blockquotePadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 8,
      ),
      blockquoteDecoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
      ),
      blockSpacing: 12,
      listIndent: 24,
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),
      tableColumnWidth: const FixedColumnWidth(156),
      tableScrollbarThumbVisibility: true,
      tableBorder: TableBorder.all(color: colors.outlineVariant),
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 8,
      ),
      tableCellsDecoration: BoxDecoration(color: colors.surface),
      tableHeadCellsDecoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
    );

    return MarkdownBody(
      data: widget.data,
      selectable: true,
      fitContent: false,
      extensionSet: md.ExtensionSet.gitHubWeb,
      styleSheet: styleSheet,
      builders: {
        for (var level = 1; level <= 6; level++) 'h$level': headings,
        'pre': _MarkdownCodeBlockBuilder(),
      },
      onTapLink: (text, href, title) => _handleLink(href),
      imageBuilder: (uri, title, alt) => Text(
        alt?.trim().isNotEmpty == true ? alt!.trim() : '图片（${uri.host}）',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _MarkdownHeadingBuilder extends MarkdownElementBuilder {
  _MarkdownHeadingBuilder(this.keys);

  final Map<String, GlobalKey> keys;
  final Map<String, int> _occurrences = {};

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final id = element.attributes['id'] ?? element.generatedId;
    final style = preferredStyle ?? Theme.of(context).textTheme.titleMedium;
    if (id == null || id.isEmpty) {
      return SelectableText(element.textContent, style: style);
    }
    final occurrence = _occurrences.update(
      id,
      (count) => count + 1,
      ifAbsent: () => 0,
    );
    final uniqueId = occurrence == 0 ? id : '$id-$occurrence';
    final key = keys[uniqueId];
    return Padding(
      key: key,
      padding: EdgeInsets.only(top: element.tag == 'h1' ? 12 : 8, bottom: 4),
      child: SelectableText(element.textContent, style: style),
    );
  }
}

class _MarkdownCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    String? language;
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'code') continue;
      for (final value in (child.attributes['class'] ?? '').split(
        RegExp(r'\s+'),
      )) {
        if (value.startsWith('language-')) {
          language = value.substring('language-'.length);
          break;
        }
      }
      break;
    }
    return _MarkdownCodeBlock(code: code, language: language);
  }
}

class _MarkdownCodeBlock extends StatelessWidget {
  const _MarkdownCodeBlock({required this.code, this.language});

  final String code;
  final String? language;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('代码已复制'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (language?.isNotEmpty == true)
                Text(
                  language!,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              const Spacer(),
              IconButton(
                tooltip: '复制代码',
                visualDensity: VisualDensity.compact,
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              code,
              softWrap: false,
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurface,
                fontFamily: 'monospace',
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

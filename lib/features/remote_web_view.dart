import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/panel_server.dart';

class RemoteWebView extends StatefulWidget {
  const RemoteWebView({
    super.key,
    required this.server,
    this.initialPath,
    this.pageTitle,
  });

  final PanelServer server;
  final String? initialPath;
  final String? pageTitle;

  @override
  State<RemoteWebView> createState() => _RemoteWebViewState();
}

class _RemoteWebViewState extends State<RemoteWebView> {
  late final WebViewController _controller;
  int _progress = 0;
  String? _error;
  bool _stopping = false;

  Uri get _initialUri {
    final base = Uri.parse(widget.server.url);
    if (widget.initialPath != null) {
      final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
      final relativePath = widget.initialPath!.replaceFirst(RegExp(r'^/+'), '');
      return base.replace(path: '$basePath/$relativePath');
    }
    return base;
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted && !_stopping) setState(() => _progress = progress);
          },
          onPageStarted: (_) {
            _stopping = false;
            if (mounted) setState(() => _error = null);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() => _error = error.description);
            }
          },
        ),
      )
      ..loadRequest(_initialUri);
  }

  Future<void> _refresh() async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    await _controller.reload();
  }

  Future<void> _stopLoading() async {
    _stopping = true;
    try {
      await _controller.runJavaScript('window.stop()');
    } catch (_) {
      await _controller.loadRequest(Uri.parse('about:blank'));
    }
    if (!mounted) return;
    setState(() => _progress = 100);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.pageTitle ?? widget.server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17),
            ),
            Text(
              Uri.parse(widget.server.url).host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _progress < 100 && _error == null ? '停止加载' : '刷新',
            onPressed: _progress < 100 && _error == null
                ? _stopLoading
                : _refresh,
            icon: Icon(
              _progress < 100 && _error == null ? Icons.close : Icons.refresh,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_progress < 100 && _error == null)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress / 100,
              minHeight: 2,
            ),
          if (_error != null)
            ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 36),
                      const SizedBox(height: 12),
                      const Text('无法载入面板'),
                      const SizedBox(height: 6),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

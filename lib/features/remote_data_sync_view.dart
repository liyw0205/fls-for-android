import 'dart:io';

import 'package:flutter/material.dart';

import '../models/panel_server.dart';
import '../services/local_install_manager.dart';
import '../services/local_panel_host.dart';
import '../services/operation_cancellation.dart';
import '../services/remote_data_sync_manager.dart';
import 'remote_web_view.dart';

class RemoteDataSyncView extends StatefulWidget {
  const RemoteDataSyncView({super.key, required this.server});

  final PanelServer server;

  @override
  State<RemoteDataSyncView> createState() => _RemoteDataSyncViewState();
}

class _RemoteDataSyncViewState extends State<RemoteDataSyncView> {
  final _localManager = LocalInstallManager();
  OperationCancellation? _cancellation;
  bool _busy = false;
  bool _complete = false;
  bool _cancelled = false;
  bool _requiresLogin = false;
  bool _wasRunning = false;
  String _stage = '准备同步';
  String? _error;
  double? _progress;
  int _receivedBytes = 0;
  int _totalBytes = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSync());
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _runSync() async {
    if (_busy) return;
    final cancellation = OperationCancellation();
    _cancellation = cancellation;
    setState(() {
      _busy = true;
      _complete = false;
      _cancelled = false;
      _requiresLogin = false;
      _error = null;
      _stage = '检查本机容器';
      _progress = null;
      _receivedBytes = 0;
      _totalBytes = 0;
    });

    final remote = RemoteDataSyncManager();
    File? archive;
    var localServiceStopped = false;
    var dataApplied = false;
    String? restartError;
    try {
      if (!await _localManager.hasRuntime() ||
          !await _localManager.hasProject()) {
        throw StateError('请先安装本机 FLS 容器和面板程序，再同步服务器数据');
      }
      cancellation.throwIfCancelled();

      final status = await LocalPanelHost.status();
      _wasRunning =
          status.state == LocalPanelState.running ||
          status.state == LocalPanelState.starting ||
          status.state == LocalPanelState.retrying;

      archive = await remote.downloadDataArchive(
        server: widget.server,
        destination: await _localManager.root,
        cancellation: cancellation,
        onStatus: (status) {
          if (mounted) setState(() => _stage = status);
        },
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            _totalBytes = total;
            _progress = total > 0 ? received / total : null;
          });
        },
      );
      cancellation.throwIfCancelled();

      if (_wasRunning) {
        setState(() => _stage = '暂停本机 FLS 以替换 data');
        localServiceStopped = true;
        await LocalPanelHost.stop();
      }
      cancellation.throwIfCancelled();

      setState(() {
        _stage = '解包并替换本机 data';
        _progress = null;
      });
      await _localManager.importServerDataArchive(
        archive,
        cancellation: cancellation,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      dataApplied = true;
    } on OperationCancelled {
      _cancelled = true;
    } on RemoteDataSyncException catch (error) {
      _requiresLogin = error.requiresLogin;
      _error = error.message;
    } catch (error) {
      _error = error.toString();
    } finally {
      if (localServiceStopped && _wasRunning) {
        if (mounted) setState(() => _stage = '恢复本机 FLS');
        try {
          await _localManager.startPanel(cancellation: OperationCancellation());
        } catch (error) {
          restartError = error.toString();
        }
      }
      if (archive != null && await archive.exists()) {
        await archive.delete();
      }
      remote.close();
      if (mounted) {
        setState(() {
          _busy = false;
          _complete = dataApplied;
          _stage = dataApplied
              ? '服务器 data 已同步到本机'
              : _cancelled
              ? '同步已取消'
              : '同步未完成';
          if (restartError != null) {
            _error = dataApplied
                ? '数据已同步，但本机 FLS 重启失败：$restartError'
                : '本机 FLS 重启失败：$restartError';
          }
          _cancellation = null;
        });
      }
    }
  }

  void _cancel() {
    final cancellation = _cancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    cancellation.cancel();
    setState(() => _stage = '正在取消同步');
  }

  Future<void> _openLogin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteWebView(server: widget.server),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _busy) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '同步数据 · ${widget.server.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: IconButton(
            tooltip: _busy ? '取消同步' : '返回',
            onPressed: _busy ? _cancel : () => Navigator.pop(context),
            icon: Icon(_busy ? Icons.close : Icons.arrow_back),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _complete
                              ? Icons.check_circle_outline
                              : _error != null
                              ? Icons.error_outline
                              : Icons.sync,
                          color: _error != null
                              ? colorScheme.error
                              : colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _stage,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${Uri.parse(widget.server.url).host} → 本机 data',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_busy) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(value: _progress),
                      if (_totalBytes > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          '${_formatBytes(_receivedBytes)} / ${_formatBytes(_totalBytes)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: colorScheme.error)),
                    ],
                    if (_requiresLogin && !_busy) ...[
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: _openLogin,
                        icon: const Icon(Icons.login),
                        label: const Text('登录远程面板'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_busy)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.close),
                  label: const Text('取消同步'),
                ),
              )
            else if (!_complete && !_cancelled)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _runSync,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新同步'),
                ),
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check),
                  label: const Text('完成'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

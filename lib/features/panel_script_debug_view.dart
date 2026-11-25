import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/panel_script_debug.dart';
import '../services/panel_api_client.dart';
import '../services/panel_script_debug_manager.dart';

class PanelScriptDebugView extends StatefulWidget {
  const PanelScriptDebugView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.initialPath,
    this.initialRunId,
    this.routesToClose = 1,
  }) : assert(initialPath != null || initialRunId != null);

  final PanelScriptDebugManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final String? initialPath;
  final String? initialRunId;
  final int routesToClose;

  @override
  State<PanelScriptDebugView> createState() => _PanelScriptDebugViewState();
}

class _PanelScriptDebugViewState extends State<PanelScriptDebugView> {
  final _logScroll = ScrollController();
  Timer? _pollTimer;
  PanelScriptDebugDetail? _detail;
  String? _error;
  String? _pendingRequestId;
  bool _loading = true;
  bool _starting = false;
  bool _stopping = false;
  bool _polling = false;
  bool _followLog = true;

  @override
  void initState() {
    super.initState();
    _logScroll.addListener(_trackLogPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.initialPath != null) {
        unawaited(_start());
      } else {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _logScroll
      ..removeListener(_trackLogPosition)
      ..dispose();
    super.dispose();
  }

  void _trackLogPosition() {
    if (!_logScroll.hasClients) return;
    _followLog =
        _logScroll.position.maxScrollExtent - _logScroll.position.pixels < 56;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refresh(quiet: true));
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _start({bool newRun = false}) async {
    final path = widget.initialPath ?? _detail?.run.path;
    if (path == null || _starting) return;
    final requestId = newRun
        ? PanelScriptDebugManager.newRequestId()
        : (_pendingRequestId ?? PanelScriptDebugManager.newRequestId());
    _pendingRequestId = requestId;
    setState(() {
      _starting = true;
      _loading = true;
      _error = null;
      if (newRun) _detail = null;
    });
    try {
      final run = await widget.manager.start(path: path, requestId: requestId);
      if (!mounted) return;
      _pendingRequestId = null;
      setState(() {
        _detail = PanelScriptDebugDetail(run: run, log: '');
        _loading = false;
      });
      if (run.isActive) _startPolling();
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _refresh({bool quiet = false}) async {
    final runId = _detail?.run.id ?? widget.initialRunId;
    if (runId == null || _polling) return;
    _polling = true;
    if (!quiet && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final followLog = _followLog;
    try {
      final detail = await widget.manager.fetchRun(runId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        if (!quiet) _error = null;
      });
      if (detail.run.isActive) {
        if (_pollTimer == null) _startPolling();
      } else {
        _stopPolling();
      }
      if (followLog) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logScroll.hasClients) {
            _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
          }
        });
      }
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      if (!quiet) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _stop() async {
    final run = _detail?.run;
    if (run == null || !run.isActive || _stopping) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停止调试运行？'),
        content: Text('将向面板发送停止信号：${run.path}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续运行'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('停止运行'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _stopping = true;
      _error = null;
    });
    try {
      final stopped = await widget.manager.stop(run.id);
      if (!mounted) return;
      setState(() {
        _detail = PanelScriptDebugDetail(run: stopped, log: _detail?.log ?? '');
      });
      if (!stopped.isActive) _stopPolling();
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      setState(() => _error = error.toString());
      await _refresh(quiet: true);
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelScriptDebugHistoryView(
          manager: widget.manager,
          onUnauthorized: widget.onUnauthorized,
          routesToClose: widget.routesToClose + 1,
        ),
      ),
    );
  }

  Future<void> _copyLog() async {
    final log = _detail?.log;
    if (log == null || log.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: log));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('日志已复制')));
    }
  }

  Future<void> _handleUnauthorized(Object error) async {
    final navigator = Navigator.of(context);
    await widget.onUnauthorized(error);
    for (
      var index = 0;
      index < widget.routesToClose && navigator.canPop();
      index++
    ) {
      navigator.pop();
    }
  }

  String _statusLabel(String status) => switch (status) {
    'starting' => '启动中',
    'running' => '运行中',
    'succeeded' => '成功结束',
    'failed' => '运行失败',
    'stopped' => '已停止',
    'unknown' => '结果未知',
    _ => '状态未知',
  };

  IconData _statusIcon(String status) => switch (status) {
    'starting' || 'running' => Icons.sync,
    'succeeded' => Icons.check_circle_outline,
    'failed' => Icons.error_outline,
    'stopped' => Icons.stop_circle_outlined,
    'unknown' => Icons.help_outline,
    _ => Icons.info_outline,
  };

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final run = detail?.run;
    return Scaffold(
      appBar: AppBar(
        title: const Text('脚本调试'),
        actions: [
          IconButton(
            tooltip: '调试记录',
            onPressed: _openHistory,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: '刷新状态与日志',
            onPressed: _polling ? null : () => _refresh(),
            icon: const Icon(Icons.refresh),
          ),
          if (run?.isActive == true)
            IconButton(
              tooltip: '停止调试运行',
              onPressed: _stopping ? null : _stop,
              icon: _stopping
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_loading || _starting)
            const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: detail == null
                      ? (widget.initialPath != null ? () => _start() : _refresh)
                      : _refresh,
                  child: const Text('重试'),
                ),
              ],
            ),
          if (detail == null)
            Expanded(
              child: Center(
                child: _loading || _starting
                    ? const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('正在启动调试运行'),
                        ],
                      )
                    : FilledButton.icon(
                        onPressed: _starting
                            ? null
                            : widget.initialPath != null
                            ? () => _start()
                            : _refresh,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('重试启动'),
                      ),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _statusIcon(run!.status),
                        color: run.status == 'failed'
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _statusLabel(run.status),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (!run.isActive && run.status != 'unknown')
                        TextButton.icon(
                          onPressed: _starting
                              ? null
                              : () => _start(newRun: true),
                          icon: const Icon(Icons.replay),
                          label: const Text('重新运行'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SelectableText(run.path),
                  if (run.returnCode != null) Text('退出码：${run.returnCode}'),
                  if (run.status == 'unknown')
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('面板无法确认进程结果。请检查日志和系统进程后再决定是否重新运行。'),
                    ),
                  if (run.error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SelectableText(
                        run.error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                    child: Row(
                      children: [
                        const Expanded(child: Text('运行日志')),
                        IconButton(
                          tooltip: _followLog ? '暂停自动滚动' : '恢复自动滚动',
                          onPressed: () =>
                              setState(() => _followLog = !_followLog),
                          icon: Icon(
                            _followLog
                                ? Icons.vertical_align_bottom
                                : Icons.pause,
                          ),
                        ),
                        IconButton(
                          tooltip: '复制日志',
                          onPressed: detail.log.isEmpty ? null : _copyLog,
                          icon: const Icon(Icons.copy),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: detail.log.isEmpty
                          ? const Center(child: Text('暂无日志'))
                          : SingleChildScrollView(
                              controller: _logScroll,
                              child: SelectionArea(
                                child: Text(
                                  detail.log,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class PanelScriptDebugHistoryView extends StatefulWidget {
  const PanelScriptDebugHistoryView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.routesToClose = 1,
  });

  final PanelScriptDebugManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final int routesToClose;

  @override
  State<PanelScriptDebugHistoryView> createState() =>
      _PanelScriptDebugHistoryViewState();
}

class _PanelScriptDebugHistoryViewState
    extends State<PanelScriptDebugHistoryView> {
  List<PanelScriptDebugRun> _runs = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final history = await widget.manager.fetchHistory();
      if (!mounted) return;
      setState(() {
        _runs = history.runs;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openRun(PanelScriptDebugRun run) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelScriptDebugView(
          manager: widget.manager,
          initialRunId: run.id,
          onUnauthorized: widget.onUnauthorized,
          routesToClose: widget.routesToClose + 1,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _handleUnauthorized(Object error) async {
    final navigator = Navigator.of(context);
    await widget.onUnauthorized(error);
    for (
      var index = 0;
      index < widget.routesToClose && navigator.canPop();
      index++
    ) {
      navigator.pop();
    }
  }

  String _statusLabel(String status) => switch (status) {
    'starting' => '启动中',
    'running' => '运行中',
    'succeeded' => '成功结束',
    'failed' => '运行失败',
    'stopped' => '已停止',
    'unknown' => '结果未知',
    _ => '状态未知',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('调试记录'),
      actions: [
        IconButton(
          tooltip: '刷新记录',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: _load, child: const Text('重试'))],
          ),
        Expanded(
          child: _runs.isEmpty
              ? Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : const Text('暂无调试记录'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _runs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final run = _runs[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          run.isActive
                              ? Icons.sync
                              : run.status == 'failed'
                              ? Icons.error_outline
                              : run.status == 'unknown'
                              ? Icons.help_outline
                              : Icons.terminal,
                          color: run.status == 'failed'
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                        title: Text(
                          run.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${_statusLabel(run.status)} · ${run.createdAt}'
                          '${run.returnCode == null ? '' : ' · 退出码 ${run.returnCode}'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openRun(run),
                      );
                    },
                  ),
                ),
        ),
      ],
    ),
  );
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/panel_log_cleanup.dart';
import '../models/panel_records.dart';
import '../services/panel_api_client.dart';
import '../services/panel_log_cleanup_manager.dart';

class PanelLogCleanupView extends StatefulWidget {
  const PanelLogCleanupView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.files = const [],
    this.groups = const [],
    this.operation,
  });

  final PanelLogCleanupManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final List<PanelLogFile> files;
  final List<String> groups;
  final PanelLogCleanupOperation? operation;

  @override
  State<PanelLogCleanupView> createState() => _PanelLogCleanupViewState();
}

class _PanelLogCleanupViewState extends State<PanelLogCleanupView>
    with WidgetsBindingObserver {
  PanelLogCleanupPreview? _preview;
  PanelLogCleanupOperation? _operation;
  String? _error;
  bool _busy = false;
  bool _authorized = true;
  bool _background = false;
  bool _unsupported = false;
  bool _confirming = false;
  DialogRoute<bool>? _confirmationRoute;
  int _generation = 0;

  bool get _canAct =>
      !_busy &&
      !_confirming &&
      !_background &&
      _authorized &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bind();
  }

  void _bind() {
    _operation = widget.operation;
    if (_operation != null && !widget.manager.owns(_operation!)) {
      _error = '清理记录不属于当前面板';
      _authorized = false;
      return;
    }
    _preview = _operation?.preview;
    unawaited(_operation == null ? _loadPreview() : _query());
  }

  @override
  void didUpdateWidget(covariant PanelLogCleanupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager ||
        oldWidget.operation != widget.operation ||
        !listEquals(oldWidget.files, widget.files) ||
        !listEquals(oldWidget.groups, widget.groups)) {
      _generation++;
      _closeDialog();
      _preview = null;
      _operation = null;
      _error = null;
      _busy = false;
      _authorized = true;
      _unsupported = false;
      _confirming = false;
      _bind();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() => _background = state != AppLifecycleState.resumed);
    if (_background) _closeDialog();
  }

  @override
  void dispose() {
    _generation++;
    _closeDialog();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _current(int generation) =>
      mounted && _authorized && generation == _generation;

  void _closeDialog() {
    final route = _confirmationRoute;
    _confirmationRoute = null;
    _confirming = false;
    final navigator = route?.navigator;
    if (route == null || navigator == null) return;
    // Paused apps do not produce frames. Invalidate consent before removing it.
    scheduleMicrotask(() {
      if (navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  Future<void> _fail(Object error, int generation) async {
    if (!_current(generation)) return;
    if (error is PanelApiException && error.statusCode == 401) {
      setState(() {
        _authorized = false;
        _busy = false;
        _generation++;
      });
      _closeDialog();
      await widget.onUnauthorized(error);
    } else {
      setState(
        () => _error = error is PanelApiException
            ? error.message
            : error is StateError
            ? error.message.toString()
            : '日志清理操作失败，请查询原请求或重新预检查',
      );
    }
  }

  Future<void> _loadPreview() async {
    if (_busy || !_authorized || _background || _operation != null) return;
    final generation = ++_generation;
    final manager = widget.manager;
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
      _unsupported = false;
    });
    try {
      final capabilities = await manager.capabilities();
      if (!_current(generation)) return;
      if (!capabilities.supported) {
        setState(() => _unsupported = true);
        return;
      }
      final preview = await manager.preview(
        files: widget.files,
        groups: widget.groups,
      );
      if (!_current(generation)) return;
      setState(() => _preview = preview);
    } catch (error) {
      await _fail(error, generation);
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _confirmAndSubmit() async {
    final preview = _preview;
    if (!_canAct || preview == null || _operation != null) return;
    if (preview.expired) {
      setState(() => _error = '预检查已过期，请重新预检查');
      return;
    }
    final generation = _generation;
    final manager = widget.manager;
    setState(() => _confirming = true);
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (context) {
        return AlertDialog(
          scrollable: true,
          title: const Text('确认清理日志'),
          content: Text(
            '${manager.panelLabel}\n${manager.panelId}\n\n'
            '${preview.items.length} 个文件 · ${_bytes(preview.totalBytes)}\n删除后无法恢复。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认删除'),
            ),
          ],
        );
      },
    );
    _confirmationRoute = route;
    final confirmed = await navigator.push<bool>(route);
    if (!identical(_confirmationRoute, route)) return;
    _confirmationRoute = null;
    if (!_current(generation)) return;
    setState(() => _confirming = false);
    if (confirmed != true || !_canAct) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final operation = manager.prepare(preview);
      setState(() => _operation = operation);
      await manager.submit(operation);
      if (_current(generation)) setState(() {});
    } catch (error) {
      await _fail(error, generation);
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _query({bool reconcile = false}) async {
    final operation = _operation;
    if (operation == null || _busy || !_authorized || _background) return;
    final generation = ++_generation;
    final manager = widget.manager;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (reconcile) {
        await manager.reconcile(operation);
      } else {
        await manager.query(operation);
      }
      if (_current(generation)) setState(() {});
    } catch (error) {
      await _fail(error, generation);
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final operation = _operation;
    final preview = _preview;
    final result = operation?.result;
    final items =
        result?.items ?? preview?.items ?? const <PanelLogCleanupItem>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(operation == null ? '日志清理' : '清理结果'),
        actions: [
          IconButton(
            tooltip: operation == null ? '重新预检查' : '查询原请求',
            onPressed: _canAct
                ? operation == null
                      ? _loadPreview
                      : () => _query()
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_authorized || _background
          ? Center(child: Text(!_authorized ? '面板会话不可用，请重新连接' : '日志信息已隐藏'))
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.manager.panelLabel,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          widget.manager.panelId,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        if (_busy) const LinearProgressIndicator(),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (_unsupported) const Text('当前面板不支持日志清理'),
                        if (preview != null) ...[
                          Text(
                            '${preview.items.length} 个文件 · ${_bytes(preview.totalBytes)}',
                          ),
                          if (preview.groups.isNotEmpty)
                            Text('分组：${preview.groups.join('、')}'),
                          if (operation == null)
                            Text(
                              '预检查有效至 ${DateTime.fromMillisecondsSinceEpoch((preview.expiresAt * 1000).round()).toLocal().toString().substring(0, 19)}',
                            ),
                        ],
                        if (operation != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            result?.status == 'completed'
                                ? '处理完成'
                                : result?.status == 'missing'
                                ? '未找到原请求回执，删除结果尚未确认'
                                : '删除结果尚未确认',
                          ),
                          if (result != null && result.status != 'missing')
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                for (final entry in result.counts.entries)
                                  if (entry.value > 0)
                                    Text(
                                      '${logCleanupStatusLabel(entry.key)} ${entry.value}',
                                    ),
                              ],
                            ),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (operation == null && preview != null)
                              FilledButton.icon(
                                onPressed: _canAct ? _confirmAndSubmit : null,
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('确认清理'),
                              ),
                            if (operation != null)
                              OutlinedButton.icon(
                                onPressed: _canAct ? () => _query() : null,
                                icon: const Icon(Icons.refresh),
                                label: const Text('查询原请求'),
                              ),
                            if (operation != null &&
                                result?.status != 'completed' &&
                                result?.status != 'missing')
                              OutlinedButton.icon(
                                onPressed: _canAct
                                    ? () => _query(reconcile: true)
                                    : null,
                                icon: const Icon(Icons.fact_check_outlined),
                                label: const Text('核对未知目标'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: Icon(
                        item.status == 'deleted'
                            ? Icons.check_circle_outline
                            : item.status == 'busy'
                            ? Icons.lock_outline
                            : Icons.description_outlined,
                      ),
                      title: Text(
                        item.filename,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${item.group} · ${_bytes(item.sizeBytes)}\n${logCleanupStatusLabel(operation != null && result == null ? 'unknown' : item.status)}',
                      ),
                      isThreeLine: true,
                    );
                  },
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
    );
  }
}

String logCleanupStatusLabel(String status) => switch (status) {
  'ready' => '可清理',
  'deleted' => '已删除',
  'missing' => '当前缺失',
  'busy' => '正在使用',
  'conflict' => '文件已变化',
  'failed' => '失败',
  _ => '结果未知',
};

String _bytes(int value) => value < 1024
    ? '$value B'
    : value < 1024 * 1024
    ? '${(value / 1024).toStringAsFixed(1)} KB'
    : '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';

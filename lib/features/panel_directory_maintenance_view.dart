import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_directory_maintenance.dart';
import '../services/panel_api_client.dart';
import '../services/panel_backup_manager.dart';

class PanelDirectoryMaintenanceView extends StatefulWidget {
  const PanelDirectoryMaintenanceView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
  });

  final PanelBackupManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<PanelDirectoryMaintenanceView> createState() =>
      _PanelDirectoryMaintenanceViewState();
}

class _PanelDirectoryMaintenanceViewState
    extends State<PanelDirectoryMaintenanceView>
    with WidgetsBindingObserver {
  PanelDirectoryMaintenancePage? _page;
  String? _error;
  String? _pendingId;
  bool _busy = false;
  bool _background = false;
  bool _expired = false;
  bool? _supported;
  bool _finalizationSupported = false;
  PanelDirectoryMaintenance? _pendingFinalization;
  int _generation = 0;
  Route<bool>? _confirmation;

  bool get _canInteract => mounted && !_background && !_expired;
  bool _isCurrent(int generation) => _canInteract && generation == _generation;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _background = state != null && state != AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PanelDirectoryMaintenanceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager)) {
      _generation++;
      _closeConfirmation();
      _page = null;
      _pendingId = null;
      _supported = null;
      _finalizationSupported = false;
      _pendingFinalization = null;
      _error = null;
      _expired = false;
      _busy = false;
      unawaited(_load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() => _background = state != AppLifecycleState.resumed);
    if (_background) {
      _generation++;
      _busy = false;
      _closeConfirmation();
    }
  }

  @override
  void dispose() {
    _generation++;
    _closeConfirmation();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _closeConfirmation() {
    final route = _confirmation;
    _confirmation = null;
    final navigator = route?.navigator;
    if (navigator != null && route != null) {
      scheduleMicrotask(() {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
    }
  }

  Future<bool> _unauthorized(Object error, int generation) async {
    if (!_isCurrent(generation)) return true;
    if (error is PanelApiException && error.statusCode == 401) {
      setState(() => _expired = true);
      _generation++;
      _closeConfirmation();
      await widget.onUnauthorized(error);
      return true;
    }
    return false;
  }

  String _message(Object error) =>
      error is PanelApiException ? error.message : error.toString();

  Future<void> _load({int? offset}) async {
    if (!_canInteract || _busy) return;
    final generation = _generation;
    final manager = widget.manager;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final capabilities = await manager.fetchCapabilities();
      if (!_isCurrent(generation)) return;
      setState(() {
        _supported = capabilities.directoryMaintenanceEnabled;
        _finalizationSupported = capabilities.directoryFinalizationEnabled;
      });
      if (!capabilities.directoryMaintenanceEnabled) return;
      final page = await manager.fetchDirectoryMaintenance(
        offset: offset ?? _page?.offset ?? 0,
        includeFinalized: _finalizationSupported,
      );
      if (!_isCurrent(generation)) return;
      setState(() => _page = page);
    } catch (error) {
      if (await _unauthorized(error, generation)) return;
      if (_isCurrent(generation)) setState(() => _error = _message(error));
    } finally {
      if (_isCurrent(generation)) setState(() => _busy = false);
    }
  }

  void _replace(PanelDirectoryMaintenance row) {
    final page = _page;
    if (page == null) return;
    setState(() {
      _page = PanelDirectoryMaintenancePage(
        items: [
          for (final item in page.items)
            if (item.requestId == row.requestId) row else item,
        ],
        total: page.total,
        limit: page.limit,
        offset: page.offset,
        hasMore: page.hasMore,
      );
    });
  }

  Future<void> _query(String requestId) async {
    if (!_canInteract || _busy) return;
    final generation = _generation;
    final manager = widget.manager;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final row = await manager.fetchDirectoryEvidence(requestId);
      if (!_isCurrent(generation)) return;
      _validatePendingFinalization(row);
      _replace(row);
      if (_pendingId == requestId) {
        setState(() {
          _pendingId = null;
          _pendingFinalization = null;
        });
      }
    } catch (error) {
      if (await _unauthorized(error, generation)) return;
      if (_isCurrent(generation)) setState(() => _error = _message(error));
    } finally {
      if (_isCurrent(generation)) setState(() => _busy = false);
    }
  }

  void _validatePendingFinalization(PanelDirectoryMaintenance row) {
    final original = _pendingFinalization;
    if (original != null &&
        row.requestId == original.requestId &&
        (row.outcome != original.outcome ||
            row.restoreItems.join(',') != original.restoreItems.join(','))) {
      throw const FormatException('现场查询结果与原结束请求不一致');
    }
  }

  Future<void> _maintain(
    PanelDirectoryMaintenance row, {
    bool finalize = false,
  }) async {
    if (!_canInteract || _busy || _pendingId != null || _confirmation != null) {
      return;
    }
    if (finalize && (!_finalizationSupported || !row.finalizeAllowed)) return;
    final generation = _generation;
    final manager = widget.manager;
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(finalize ? '确认结束现场维护' : '确认恢复目录现场'),
        content: Text(
          finalize
              ? '请先核对目录结果。结束后将归档原事务清单和损坏回执，'
                    '保留目录副本，并解除本次目录写入限制。'
                    '此次维护不会安装依赖或重新加载调度器。'
              : '将按原事务清单回滚中断的目录替换，或核对已经提交的目录。'
                    '原恢复回执无法读取，记录和副本将保留，维护完成前继续限制写入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(finalize ? '确认结束维护' : '确认恢复现场'),
          ),
        ],
      ),
    );
    _confirmation = route;
    final confirmed = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(route);
    final current = identical(_confirmation, route);
    if (current) _confirmation = null;
    if (!_isCurrent(generation) || !current || confirmed != true || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _pendingId = row.requestId;
      _pendingFinalization = finalize ? row : null;
      _error = null;
    });
    try {
      final result = finalize
          ? await manager.finalizeOrphanDirectory(row)
          : await manager.recoverOrphanDirectory(row);
      if (!_isCurrent(generation)) return;
      _replace(result);
      setState(() {
        _pendingId = null;
        _pendingFinalization = null;
      });
    } catch (error) {
      if (await _unauthorized(error, generation)) return;
      try {
        final result = await manager.fetchDirectoryEvidence(row.requestId);
        if (!_isCurrent(generation)) return;
        _validatePendingFinalization(result);
        _replace(result);
        setState(() {
          _pendingId = null;
          _pendingFinalization = null;
          _error = '操作响应未能确认，已读取原目录现场；请核对当前结果。';
        });
      } catch (queryError) {
        if (await _unauthorized(queryError, generation)) return;
        if (_isCurrent(generation)) {
          setState(() => _error = '操作结果尚未确认；请查询原现场，不能重新提交。');
        }
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_background || _expired) return const SizedBox.shrink();
    final page = _page;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(child: Text('目录现场维护')),
            IconButton(
              tooltip: '刷新目录现场',
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (_pendingId != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _query(_pendingId!),
              icon: const Icon(Icons.sync),
              label: const Text('查询原现场'),
            ),
          ),
        if (_supported == false) const Text('此面板版本尚不支持独立目录现场维护'),
        if (page != null) ...[
          if (page.items.isEmpty) const Text('当前没有待处理的目录现场'),
          for (final row in page.items) ...[
            const Divider(),
            SelectableText(row.requestId),
            const SizedBox(height: 8),
            Text(switch (row.outcome) {
              'restored' => '清单记录：目录已提交',
              'not_applied' => '清单记录：原目录已回滚',
              _ => row.state == 'unavailable' ? '目录事务证据无法读取' : '目录替换中断，等待核对',
            }),
            if (row.restoreItems.isNotEmpty)
              Text('范围：${row.restoreItems.join('、')}'),
            Text(switch (row.receiptState) {
              'available' => '原恢复回执可读，请在恢复记录中处理',
              'missing' => '原恢复回执缺失',
              _ => '原恢复回执无法读取',
            }),
            Text(
              row.state == 'finalized'
                  ? '本次目录维护已结束；原始证据和目录副本保留。'
                  : '事务清单和副本保留；结束维护前仍限制写入。',
            ),
            if (row.state == 'finalized' && row.outcome == 'restored')
              const Text('此次维护未执行依赖安装或调度器重载。'),
            if (row.state == 'finalizing') const Text('证据归档尚未结束，请查询后确认继续。'),
            if (row.active) const Text('恢复或后续处理仍在执行'),
            Wrap(
              spacing: 8,
              children: [
                if (row.recoverAllowed)
                  OutlinedButton.icon(
                    onPressed: _busy || _pendingId != null
                        ? null
                        : () => _maintain(row),
                    icon: const Icon(Icons.restore),
                    label: const Text('恢复目录现场'),
                  ),
                if (_finalizationSupported && row.finalizeAllowed)
                  OutlinedButton.icon(
                    onPressed: _busy || _pendingId != null
                        ? null
                        : () => _maintain(row, finalize: true),
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('结束现场维护'),
                  ),
                IconButton(
                  tooltip: '查询目录现场',
                  onPressed: _busy ? null : () => _query(row.requestId),
                  icon: const Icon(Icons.sync),
                ),
              ],
            ),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一页现场',
                onPressed: !_busy && page.offset > 0
                    ? () => _load(offset: page.offset - page.limit)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${page.offset ~/ page.limit + 1}'),
              IconButton(
                tooltip: '下一页现场',
                onPressed: !_busy && page.hasMore
                    ? () => _load(offset: page.offset + page.limit)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

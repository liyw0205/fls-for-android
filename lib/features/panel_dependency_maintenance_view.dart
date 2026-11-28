import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_dependency_maintenance.dart';
import '../services/panel_api_client.dart';
import '../services/panel_backup_manager.dart';

class PanelDependencyMaintenanceView extends StatefulWidget {
  const PanelDependencyMaintenanceView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
  });

  final PanelBackupManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<PanelDependencyMaintenanceView> createState() =>
      _PanelDependencyMaintenanceViewState();
}

class _PanelDependencyMaintenanceViewState
    extends State<PanelDependencyMaintenanceView>
    with WidgetsBindingObserver {
  PanelDependencyMaintenancePage? _page;
  PanelDependencyMaintenance? _pending;
  bool? _supported;
  bool _busy = false;
  bool _background = false;
  bool _expired = false;
  String? _error;
  int _generation = 0;
  Route<bool>? _confirmation;

  bool get _canInteract => mounted && !_background && !_expired;
  bool _current(int generation) => _canInteract && generation == _generation;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _background = lifecycle != null && lifecycle != AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PanelDependencyMaintenanceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager)) {
      _generation++;
      _closeConfirmation();
      _page = null;
      _pending = null;
      _supported = null;
      _busy = false;
      _expired = false;
      _error = null;
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
    if (!_current(generation)) return true;
    if (error is PanelApiException && error.statusCode == 401) {
      setState(() => _expired = true);
      _generation++;
      _closeConfirmation();
      await widget.onUnauthorized(error);
      return true;
    }
    return false;
  }

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
      if (!_current(generation)) return;
      setState(() => _supported = capabilities.dependencyMaintenanceEnabled);
      if (!_supported!) return;
      final page = await manager.fetchDependencyMaintenance(
        offset: offset ?? _page?.offset ?? 0,
      );
      if (_current(generation)) setState(() => _page = page);
    } catch (error) {
      if (await _unauthorized(error, generation)) return;
      if (_current(generation)) {
        setState(
          () => _error = error is PanelApiException
              ? error.message
              : error.toString(),
        );
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  void _replace(PanelDependencyMaintenance row) {
    final page = _page;
    if (page == null) return;
    setState(
      () => _page = PanelDependencyMaintenancePage(
        items: [
          for (final item in page.items)
            if (item.identity == row.identity) row else item,
        ],
        total: page.total,
        limit: page.limit,
        offset: page.offset,
        hasMore: page.hasMore,
      ),
    );
  }

  Future<void> _observe(
    PanelBackupManager manager,
    PanelDependencyMaintenance row,
    int generation,
  ) async {
    for (var attempt = 0; attempt < 9; attempt++) {
      if (!_current(generation)) return;
      _replace(row);
      if (row.state != 'unavailable' && !row.awaitingOwner) {
        if (_pending?.identity == row.identity) setState(() => _pending = null);
        return;
      }
      if (row.state == 'unavailable' || attempt == 8) break;
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (!_current(generation)) return;
      row = await manager.fetchDependencyEvidence(
        row.requestId,
        row.operationId,
      );
    }
    if (_current(generation)) setState(() => _error = '结果尚未确认，请查询原依赖现场。');
  }

  Future<void> _query(PanelDependencyMaintenance original) async {
    if (!_canInteract || _busy) return;
    final generation = _generation;
    final manager = widget.manager;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final row = await manager.fetchDependencyEvidence(
        original.requestId,
        original.operationId,
      );
      if (!_current(generation)) return;
      await _observe(manager, row, generation);
    } catch (error) {
      if (await _unauthorized(error, generation)) return;
      if (_current(generation)) {
        setState(() => _error = '原依赖现场尚未确认，请保留记录后继续查询。');
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _cleanup(PanelDependencyMaintenance original) async {
    if (!_canInteract ||
        _busy ||
        _pending != null ||
        _confirmation != null ||
        !original.cleanupAllowed) {
      return;
    }
    final generation = _generation;
    final manager = widget.manager;
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清理依赖资源'),
        content: const SingleChildScrollView(
          child: Text(
            '将清理原操作遗留的进程、输出和临时目录，随后归档损坏的恢复记录。'
            '原始证据保留；不会重新安装依赖或恢复目录。原安装与恢复结果仍未知。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清理资源'),
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
    if (!_current(generation) || !current || confirmed != true || _busy) return;
    setState(() {
      _busy = true;
      _pending = original;
      _error = null;
    });
    try {
      final row = await manager.cleanupOrphanDependency(original);
      if (!_current(generation)) return;
      await _observe(manager, row, generation);
    } catch (error) {
      if (await _unauthorized(error, generation)) return;
      try {
        final row = await manager.fetchDependencyEvidence(
          original.requestId,
          original.operationId,
        );
        if (!_current(generation)) return;
        await _observe(manager, row, generation);
      } catch (queryError) {
        if (await _unauthorized(queryError, generation)) return;
        if (_current(generation)) setState(() => _error = '清理结果尚未确认，请查询原依赖现场。');
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
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
            const Expanded(child: Text('依赖资源维护')),
            IconButton(
              tooltip: '刷新依赖现场',
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (_pending != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _query(_pending!),
              icon: const Icon(Icons.sync),
              label: const Text('查询原依赖现场'),
            ),
          ),
        if (_supported == false) const Text('此面板版本尚不支持独立依赖现场维护'),
        if (page != null) ...[
          if (page.items.isEmpty) const Text('当前没有依赖资源记录'),
          for (final row in page.items) ...[
            const Divider(),
            SelectableText(row.requestId),
            Text('依赖操作：${row.operationId}'),
            const SizedBox(height: 8),
            Text(switch (row.state) {
              'active' => '依赖安装仍在执行',
              'requested' => '已请求原作业清理资源',
              'cleaning' => '正在清理依赖资源',
              'cleanup_failed' => '上次清理未完成，请核对后重试',
              'finalizing' => '资源已清理，证据归档尚未结束',
              'finalized' => '依赖资源维护已结束，原始证据保留',
              'unavailable' => '依赖资源证据无法读取',
              _ => row.resourceState == 'cleaned' ? '依赖资源已清理' : '依赖资源等待核对',
            }),
            Text(switch (row.receiptState) {
              'available' => '原恢复记录可读，请在恢复记录中处理',
              'missing' => '原恢复记录缺失',
              _ => '原恢复记录无法读取',
            }),
            const Text('原安装与恢复结果未知'),
            Wrap(
              spacing: 8,
              children: [
                if (row.cleanupAllowed)
                  OutlinedButton.icon(
                    onPressed: _busy || _pending != null
                        ? null
                        : () => _cleanup(row),
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: Text(
                      row.resourceState == 'cleaned' ? '完成资源维护' : '清理依赖资源',
                    ),
                  ),
                IconButton(
                  tooltip: '查询依赖现场',
                  onPressed: _busy ? null : () => _query(row),
                  icon: const Icon(Icons.sync),
                ),
              ],
            ),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一页依赖现场',
                onPressed: !_busy && page.offset > 0
                    ? () => _load(offset: page.offset - page.limit)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${page.offset ~/ page.limit + 1}'),
              IconButton(
                tooltip: '下一页依赖现场',
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

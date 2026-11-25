import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/panel_environment.dart';
import '../services/panel_api_client.dart';
import '../services/panel_runtime_deps_manager.dart';

enum _EnvironmentSection { dependencies, runtimes, history }

class PanelRuntimeDepsView extends StatefulWidget {
  const PanelRuntimeDepsView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.routesToClose = 1,
  });

  final PanelRuntimeDepsManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final int routesToClose;

  @override
  State<PanelRuntimeDepsView> createState() => _PanelRuntimeDepsViewState();
}

class _PanelRuntimeDepsViewState extends State<PanelRuntimeDepsView> {
  final _packageController = TextEditingController();
  final _searchController = TextEditingController();
  Timer? _searchTimer;
  _EnvironmentSection _section = _EnvironmentSection.dependencies;
  PanelDependencyPage? _packagePage;
  PanelDependencyChecks? _checks;
  List<PanelRuntime> _runtimes = const [];
  PanelInstallHistory? _history;
  String _historyKind = '';
  String _query = '';
  String? _error;
  _PendingEnvironmentAction? _pendingAction;
  bool _packagesLoading = true;
  bool _runtimesLoading = false;
  bool _historyLoading = false;
  bool _checksLoading = false;
  bool _busy = false;
  int _packageRequest = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPackages());
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _packageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshSection() async {
    switch (_section) {
      case _EnvironmentSection.dependencies:
        await _loadPackages(page: _packagePage?.page ?? 1);
        if (_checks != null) await _loadChecks();
      case _EnvironmentSection.runtimes:
        await _loadRuntimes();
      case _EnvironmentSection.history:
        await _loadHistory();
    }
  }

  Future<void> _loadPackages({int page = 1}) async {
    final request = ++_packageRequest;
    setState(() {
      _packagesLoading = true;
      _error = null;
    });
    try {
      final result = await widget.manager.fetchPackages(
        query: _query,
        page: page,
      );
      if (!mounted || request != _packageRequest) return;
      setState(() {
        _packagePage = result;
        _packagesLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _packageRequest) return;
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _packagesLoading = false;
      });
    }
  }

  Future<void> _loadRuntimes() async {
    setState(() {
      _runtimesLoading = true;
      _error = null;
    });
    try {
      final result = await widget.manager.fetchRuntimes();
      if (!mounted) return;
      setState(() {
        _runtimes = result;
        _runtimesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _runtimesLoading = false;
      });
    }
  }

  Future<void> _loadHistory() async {
    setState(() {
      _historyLoading = true;
      _error = null;
    });
    try {
      final result = await widget.manager.fetchHistory(kind: _historyKind);
      if (!mounted) return;
      setState(() {
        _history = result;
        _historyLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _historyLoading = false;
      });
    }
  }

  Future<void> _loadChecks() async {
    setState(() {
      _checksLoading = true;
      _error = null;
    });
    try {
      final result = await widget.manager.refreshCoreDependencies();
      if (!mounted) return;
      setState(() {
        _checks = result;
        _checksLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _checksLoading = false;
      });
    }
  }

  Future<bool> _handleUnauthorized(Object error) async {
    if (error is! PanelApiException || error.statusCode != 401) return false;
    final navigator = Navigator.of(context);
    await widget.onUnauthorized(error);
    if (!mounted) return true;
    for (var index = 0; index < widget.routesToClose; index++) {
      if (!navigator.canPop()) break;
      navigator.pop();
    }
    return true;
  }

  void _searchChanged(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _query = value.trim();
      unawaited(_loadPackages());
    });
  }

  Future<void> _startInstall({
    required String name,
    required String kind,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || _busy) return;
    if (kind == 'dependency' &&
        (normalizedName.startsWith('-') ||
            normalizedName.length > 200 ||
            normalizedName.codeUnits.any((unit) => unit < 32 || unit == 127))) {
      setState(() => _error = '依赖需求格式无效');
      return;
    }
    final action = _PendingEnvironmentAction(
      kind: kind,
      operation: 'install',
      name: normalizedName,
      requestId: PanelRuntimeDepsManager.newRequestId(),
    );
    await _submit(action);
  }

  Future<void> _submit(_PendingEnvironmentAction action) async {
    setState(() {
      _busy = true;
      _error = null;
      _pendingAction = action;
    });
    try {
      final job = await _sendAction(action);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pendingAction = null;
        if (action.kind == 'dependency' && action.operation == 'install') {
          _packageController.clear();
        }
      });
      await _openJob(job.id);
    } catch (error) {
      if (!mounted) return;
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  Future<PanelInstallJob> _sendAction(_PendingEnvironmentAction action) {
    if (action.kind == 'runtime') {
      return widget.manager.installRuntime(
        action.name,
        requestId: action.requestId,
      );
    }
    if (action.operation == 'uninstall') {
      return widget.manager.uninstallDependency(
        action.name,
        requestId: action.requestId,
      );
    }
    return widget.manager.installDependency(
      action.name,
      requestId: action.requestId,
    );
  }

  Future<void> _confirmUninstall(PanelDependency package) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('卸载依赖？'),
        content: Text('将从此面板的 Python 环境卸载 ${package.name}。依赖关系中的其他包或脚本可能受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _submit(
      _PendingEnvironmentAction(
        kind: 'dependency',
        operation: 'uninstall',
        name: package.name,
        requestId: PanelRuntimeDepsManager.newRequestId(),
      ),
    );
  }

  Future<void> _openJob(String installId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelInstallJobView(
          manager: widget.manager,
          installId: installId,
          onUnauthorized: widget.onUnauthorized,
          routesToClose: widget.routesToClose + 1,
        ),
      ),
    );
    if (!mounted) return;
    await _loadPackages(page: _packagePage?.page ?? 1);
    if (_section == _EnvironmentSection.runtimes) await _loadRuntimes();
    if (_section == _EnvironmentSection.history) await _loadHistory();
  }

  Future<void> _openHistoryJob(PanelInstallJob job) => _openJob(job.id);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行环境'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _refreshSection,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SegmentedButton<_EnvironmentSection>(
              segments: const [
                ButtonSegment(
                  value: _EnvironmentSection.dependencies,
                  label: Text('依赖'),
                  icon: Icon(Icons.extension_outlined),
                ),
                ButtonSegment(
                  value: _EnvironmentSection.runtimes,
                  label: Text('运行器'),
                  icon: Icon(Icons.terminal_outlined),
                ),
                ButtonSegment(
                  value: _EnvironmentSection.history,
                  label: Text('历史'),
                  icon: Icon(Icons.history),
                ),
              ],
              selected: {_section},
              onSelectionChanged: (selection) {
                setState(() => _section = selection.single);
                switch (selection.single) {
                  case _EnvironmentSection.dependencies:
                    unawaited(_loadPackages());
                  case _EnvironmentSection.runtimes:
                    unawaited(_loadRuntimes());
                  case _EnvironmentSection.history:
                    unawaited(_loadHistory());
                }
              },
            ),
          ),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(onPressed: _refreshSection, child: const Text('重试')),
              ],
            ),
          if (_pendingAction != null)
            MaterialBanner(
              content: Text(
                '操作结果未知。使用同一请求标识恢复，不会重复提交已记录的操作。请求 ID：${_pendingAction!.requestId}',
              ),
              actions: [
                TextButton(
                  onPressed: _busy ? null : () => _submit(_pendingAction!),
                  child: const Text('恢复提交'),
                ),
                TextButton(
                  onPressed: () => _openJob(_pendingAction!.requestId),
                  child: const Text('查询状态'),
                ),
              ],
            ),
          Expanded(
            child: switch (_section) {
              _EnvironmentSection.dependencies => _buildDependencies(),
              _EnvironmentSection.runtimes => _buildRuntimes(),
              _EnvironmentSection.history => _buildHistory(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDependencies() {
    final page = _packagePage;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _packageController,
                    enabled: !_busy,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '依赖包名',
                      hintText: 'requests',
                      prefixIcon: Icon(Icons.extension_outlined),
                    ),
                    onSubmitted: (value) =>
                        _startInstall(name: value, kind: 'dependency'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _startInstall(
                                  name: _packageController.text,
                                  kind: 'dependency',
                                ),
                          icon: _busy
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download),
                          label: const Text('安装依赖'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '检测核心依赖',
                        onPressed: _checksLoading ? null : _loadChecks,
                        icon: _checksLoading
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.fact_check_outlined),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_checks != null) _buildChecks(_checks!),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '搜索已安装依赖',
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () {
                        _searchController.clear();
                        _searchChanged('');
                      },
                      icon: const Icon(Icons.close),
                    ),
              isDense: true,
            ),
            onChanged: _searchChanged,
          ),
        ),
        Expanded(
          child: _packagesLoading && page == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _refreshSection,
                  child: page == null || page.items.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 100),
                            Center(
                              child: Text(
                                _query.isEmpty ? '暂无已安装依赖' : '没有匹配的依赖',
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: page.items.length + 1,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  4,
                                ),
                                child: Text(
                                  '${page.total} 个依赖',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                              );
                            }
                            final package = page.items[index - 1];
                            return ListTile(
                              title: Text(package.name),
                              subtitle: Text('版本 ${package.version}'),
                              trailing: IconButton(
                                tooltip: '卸载 ${package.name}',
                                onPressed: _busy
                                    ? null
                                    : () => _confirmUninstall(package),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            );
                          },
                        ),
                ),
        ),
        if (page != null && page.pages > 1)
          _DependencyPageControls(
            page: page.page,
            pages: page.pages,
            onPage: (value) => _loadPackages(page: value),
          ),
      ],
    );
  }

  Widget _buildChecks(PanelDependencyChecks checks) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('核心依赖检测')),
              Text(checks.time, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final entry in checks.packages.entries)
                Chip(
                  avatar: Icon(
                    entry.value.startsWith('不可用')
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    size: 16,
                    color: entry.value.startsWith('不可用')
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.tertiary,
                  ),
                  label: Text('${entry.key} · ${entry.value}'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRuntimes() {
    if (_runtimesLoading && _runtimes.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_runtimes.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadRuntimes,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            Center(child: Text('未读取到运行器状态')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadRuntimes,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _runtimes.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final runtime = _runtimes[index];
          final available = runtime.status == 'available';
          final statusLabel = switch (runtime.status) {
            'available' => '已安装',
            'missing' => '未安装',
            'timeout' => '检测超时',
            _ => '检测失败',
          };
          return ListTile(
            title: Text(runtime.name),
            subtitle: Text(
              [
                runtime.suffix,
                if (available && runtime.version.isNotEmpty) runtime.version,
                if (!available && runtime.detail.isNotEmpty) runtime.detail,
                if (!runtime.installable && runtime.installError.isNotEmpty)
                  runtime.installError,
              ].join(' · '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            leading: Icon(
              available ? Icons.check_circle_outline : Icons.terminal,
              color: available
                  ? Theme.of(context).colorScheme.tertiary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            trailing: available
                ? Text(statusLabel)
                : runtime.installable
                ? IconButton(
                    tooltip: '安装${runtime.name}',
                    onPressed: _busy
                        ? null
                        : () =>
                              _startInstall(name: runtime.key, kind: 'runtime'),
                    icon: const Icon(Icons.download),
                  )
                : const Icon(Icons.block_outlined),
          );
        },
      ),
    );
  }

  Widget _buildHistory() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '', label: Text('全部')),
              ButtonSegment(value: 'dependency', label: Text('依赖')),
              ButtonSegment(value: 'runtime', label: Text('运行器')),
            ],
            selected: {_historyKind},
            onSelectionChanged: (values) {
              setState(() => _historyKind = values.single);
              unawaited(_loadHistory());
            },
          ),
        ),
        Expanded(
          child: _historyLoading && _history == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _loadHistory,
                  child: _history == null || _history!.items.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            Center(child: Text('暂无安装历史')),
                          ],
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _history!.items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final job = _history!.items[index];
                            return ListTile(
                              title: Text(_jobTitle(job)),
                              subtitle: Text(
                                [
                                  job.statusLabel,
                                  if (job.cancelStatusLabel.isNotEmpty)
                                    job.cancelStatusLabel,
                                  if (job.updatedAt.isNotEmpty) job.updatedAt,
                                  if (job.error.isNotEmpty) job.error,
                                  if (job.retryConfirmationRequired)
                                    '需确认原进程已停止',
                                ].join(' · '),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _openHistoryJob(job),
                            );
                          },
                        ),
                ),
        ),
      ],
    );
  }

  String _jobTitle(PanelInstallJob job) {
    final kind = job.kind == 'runtime' ? '运行器' : '依赖';
    final operation = job.operation == 'uninstall' ? '卸载' : '安装';
    return '$kind$operation · ${job.package}';
  }
}

class _PendingEnvironmentAction {
  const _PendingEnvironmentAction({
    required this.kind,
    required this.operation,
    required this.name,
    required this.requestId,
  });

  final String kind;
  final String operation;
  final String name;
  final String requestId;
}

class _DependencyPageControls extends StatelessWidget {
  const _DependencyPageControls({
    required this.page,
    required this.pages,
    required this.onPage,
  });

  final int page;
  final int pages;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: page > 1 ? () => onPage(page - 1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Text('$page / $pages'),
        IconButton(
          tooltip: '下一页',
          onPressed: page < pages ? () => onPage(page + 1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
}

class PanelInstallJobView extends StatefulWidget {
  const PanelInstallJobView({
    super.key,
    required this.manager,
    required this.installId,
    required this.onUnauthorized,
    this.routesToClose = 1,
  });

  final PanelRuntimeDepsManager manager;
  final String installId;
  final Future<void> Function(Object error) onUnauthorized;
  final int routesToClose;

  @override
  State<PanelInstallJobView> createState() => _PanelInstallJobViewState();
}

class _PanelInstallJobViewState extends State<PanelInstallJobView> {
  final _logController = ScrollController();
  Timer? _pollTimer;
  String _installId = '';
  String? _pendingCancelId;
  String? _pendingRetryId;
  PanelInstallJob? _job;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _followLog = true;

  @override
  void initState() {
    super.initState();
    _installId = widget.installId;
    _logController.addListener(_trackLogPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _logController
      ..removeListener(_trackLogPosition)
      ..dispose();
    super.dispose();
  }

  void _trackLogPosition() {
    if (!_logController.hasClients) return;
    _followLog =
        _logController.position.maxScrollExtent -
            _logController.position.pixels <
        56;
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

  Future<void> _refresh({bool quiet = false}) async {
    if (_busy || (_loading && quiet)) return;
    setState(() {
      if (!quiet) _loading = true;
      _error = null;
    });
    try {
      final result = await widget.manager.fetchInstall(_installId);
      if (!mounted) return;
      setState(() {
        _job = result;
        _loading = false;
      });
      _pendingCancelId = result.cancelStatus == 'requested'
          ? (result.cancelRequestId.isNotEmpty
                ? result.cancelRequestId
                : _pendingCancelId)
          : null;
      if (result.running ||
          result.receiptPending ||
          result.cancelStatus == 'requested') {
        _startPolling();
      } else {
        _stopPolling();
      }
      if (_followLog && _logController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logController.hasClients && _followLog) {
            _logController.jumpTo(_logController.position.maxScrollExtent);
          }
        });
      }
    } catch (error) {
      if (!mounted) return;
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<bool> _handleUnauthorized(Object error) async {
    if (error is! PanelApiException || error.statusCode != 401) return false;
    final navigator = Navigator.of(context);
    await widget.onUnauthorized(error);
    if (!mounted) return true;
    for (var index = 0; index < widget.routesToClose; index++) {
      if (!navigator.canPop()) break;
      navigator.pop();
    }
    return true;
  }

  Future<void> _cancel() async {
    final job = _job;
    if (job == null || !job.running || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消安装？'),
        content: Text(
          '将请求面板终止${job.operation == 'uninstall' ? '卸载' : '安装'} ${job.package}。软件包管理器可能已完成部分修改，取消后请刷新环境状态。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续运行'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('请求取消'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final requestId =
        _pendingCancelId ?? PanelRuntimeDepsManager.newRequestId();
    _pendingCancelId = requestId;
    setState(() {
      _busy = true;
      _error = null;
    });
    var shouldRefresh = false;
    try {
      final result = await widget.manager.cancel(_installId, requestId);
      if (!mounted) return;
      setState(() => _job = result);
      shouldRefresh = true;
    } catch (error) {
      if (!mounted) return;
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      try {
        final result = await widget.manager.fetchCancelStatus(
          _installId,
          requestId,
        );
        if (!mounted) return;
        _pendingCancelId = result.cancelStatus == 'requested'
            ? requestId
            : null;
        shouldRefresh = true;
      } catch (statusError) {
        if (!mounted) return;
        if (await _handleUnauthorized(statusError)) return;
        if (!mounted) return;
        setState(() => _error = statusError.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && shouldRefresh) await _refresh(quiet: true);
  }

  Future<void> _confirmRetrySafety() async {
    final job = _job;
    if (job == null || !job.retryConfirmationRequired || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认原进程已停止'),
        content: const Text(
          '面板重启后无法确认原进程状态。请先在服务器确认此安装/卸载进程已经停止；否则可能同时修改同一 Python 环境。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('我已确认进程停止'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runJobAction(() => widget.manager.confirmRetrySafety(_installId));
  }

  Future<void> _retry() async {
    final job = _job;
    if (job == null || !job.canRetry || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(job.operation == 'uninstall' ? '重试卸载？' : '重试安装？'),
        content: Text(
          '将对 ${job.package} 再次执行${job.operation == 'uninstall' ? '卸载' : '安装'}。请先检查上一次日志，避免覆盖仍在进行的包管理操作。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认重试'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final retryId = _pendingRetryId ?? PanelRuntimeDepsManager.newRequestId();
    _pendingRetryId = retryId;
    await _runJobAction(
      () => widget.manager.retry(_installId, retryId),
      recover: () => widget.manager.fetchRetryStatus(_installId, retryId),
    );
  }

  Future<void> _runJobAction(
    Future<PanelInstallJob> Function() action, {
    Future<PanelInstallJob> Function()? recover,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() {
        _job = result;
        _installId = result.id;
        _pendingRetryId = null;
        _busy = false;
      });
      await _refresh(quiet: true);
    } catch (error) {
      if (!mounted) return;
      if (await _handleUnauthorized(error)) return;
      if (recover != null) {
        try {
          final result = await recover();
          if (!mounted) return;
          setState(() {
            _job = result;
            _installId = result.id;
            _pendingRetryId = null;
            _busy = false;
          });
          await _refresh(quiet: true);
          return;
        } catch (recoveryError) {
          if (!mounted) return;
          if (await _handleUnauthorized(recoveryError)) return;
          if (!mounted) return;
          setState(() => _error = recoveryError.toString());
        }
      } else {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyLog() async {
    final log = _job?.log ?? '';
    if (log.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: log));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('日志已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    final title = job == null
        ? '作业状态'
        : '${job.kind == 'runtime' ? '运行器' : '依赖'}${job.operation == 'uninstall' ? '卸载' : '安装'}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: '刷新状态与日志',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '复制日志',
            onPressed: job?.log.isNotEmpty == true ? _copyLog : null,
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
      body: _loading && job == null
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(job),
    );
  }

  Widget _buildBody(PanelInstallJob? job) {
    return Column(
      children: [
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(
                onPressed: () => _refresh(),
                child: const Text('重试查询'),
              ),
            ],
          ),
        if (_loading || job?.running == true)
          const LinearProgressIndicator(minHeight: 2),
        if (job == null)
          const Expanded(child: Center(child: Text('尚未读取到此作业')))
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Text(
                  job.package.isEmpty ? '未知项目' : job.package,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text('${job.statusLabel} · ${job.status}'),
                if (job.returnCode != null) Text('退出码 ${job.returnCode}'),
                if (job.cancelStatusLabel.isNotEmpty)
                  Text(job.cancelStatusLabel),
                if (job.receiptPending)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('作业状态回执尚未保存。页面会继续查询，不能重复提交新的操作。'),
                  ),
                if (job.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      job.error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (job.retryConfirmationRequired)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '面板重启后无法确认原进程结果。确认服务器进程已停止后，才可进行安全恢复。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (job.running)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _cancel,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('取消作业'),
                      ),
                    if (job.retryConfirmationRequired)
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _confirmRetrySafety,
                        icon: const Icon(Icons.fact_check_outlined),
                        label: const Text('确认进程已停止'),
                      ),
                    if (job.canRetry)
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _retry,
                        icon: const Icon(Icons.replay),
                        label: const Text('明确重试'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Expanded(child: Text('执行日志')),
                    IconButton(
                      tooltip: _followLog ? '暂停自动跟随' : '继续自动跟随',
                      onPressed: () => setState(() => _followLog = !_followLog),
                      icon: Icon(
                        _followLog ? Icons.vertical_align_bottom : Icons.pause,
                      ),
                    ),
                  ],
                ),
                Container(
                  constraints: const BoxConstraints(minHeight: 220),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: SingleChildScrollView(
                    controller: _logController,
                    child: SelectableText(
                      job.log.isEmpty ? '暂无日志' : job.log,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '作业 ID：$_installId',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

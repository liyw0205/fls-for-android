import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/panel_server.dart';
import '../models/panel_dashboard_snapshot.dart';
import '../models/panel_task_summary.dart';
import '../services/panel_api_client.dart';
import '../services/panel_credential_store.dart';
import '../services/panel_dashboard_manager.dart';
import '../services/panel_tasks_manager.dart';
import 'panel_collections_view.dart';
import 'panel_task_detail_view.dart';
import 'panel_task_editor_view.dart';
import 'remote_web_view.dart';

enum _TaskFilter { all, running, disabled }

class PanelTasksView extends StatefulWidget {
  const PanelTasksView({
    super.key,
    required this.server,
    PanelCredentialStore? credentialStore,
    this.client,
    this.allowInsecureHttp = false,
  }) : credentialStore = credentialStore ?? const SecurePanelCredentialStore();

  final PanelServer server;
  final PanelCredentialStore credentialStore;
  final http.Client? client;
  final bool allowInsecureHttp;

  @override
  State<PanelTasksView> createState() => _PanelTasksViewState();
}

class _PanelTasksViewState extends State<PanelTasksView> {
  final _searchController = TextEditingController();
  final _collectionsKey = GlobalKey<PanelCollectionsViewState>();
  PanelApiClient? _api;
  PanelDashboardManager? _dashboardManager;
  PanelTasksManager? _manager;
  PanelDashboardSnapshot? _dashboard;
  List<PanelTaskSummary> _tasks = const [];
  int _selectedPanelTab = 0;
  _TaskFilter _filter = _TaskFilter.all;
  String _query = '';
  String? _error;
  String? _busyTaskId;
  bool _loading = true;
  bool _dashboardLoading = false;
  bool _hasCredential = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSavedCredential());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _api?.close();
    super.dispose();
  }

  Future<void> _loadSavedCredential() async {
    try {
      final credentials = await widget.credentialStore.read(widget.server.url);
      if (!mounted) return;
      if (credentials == null) {
        setState(() {
          _loading = false;
          _hasCredential = false;
        });
        return;
      }
      setState(() => _hasCredential = true);
      await _connectWithSession(
        credentials,
        allowInsecureHttp: widget.allowInsecureHttp,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取安全凭据失败：$error';
      });
    }
  }

  Future<void> _connectWithSession(
    PanelSessionCredentials credentials, {
    bool allowInsecureHttp = false,
  }) async {
    final api = PanelApiClient(
      baseUrl: widget.server.url,
      credentials: credentials,
      allowInsecureHttp: allowInsecureHttp,
      client: widget.client,
    );
    await _loadTasksWithApi(api);
  }

  Future<void> _loadTasksWithApi(PanelApiClient api) async {
    final manager = PanelTasksManager(api);
    final dashboardManager = PanelDashboardManager(api);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tasks = await manager.fetchTasks();
      if (!mounted) {
        api.close();
        return;
      }
      if (!identical(_api, api)) _api?.close();
      setState(() {
        _api = api;
        _manager = manager;
        _dashboardManager = dashboardManager;
        _tasks = tasks;
        _loading = false;
        _hasCredential = true;
        _error = null;
      });
      unawaited(_refreshDashboard());
    } catch (error) {
      if (!mounted) {
        api.close();
        return;
      }
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireSession(error, candidate: api);
        return;
      }
      if (!identical(_api, api)) _api?.close();
      setState(() {
        _loading = false;
        _hasCredential = true;
        _api = api;
        _manager = manager;
        _dashboardManager = dashboardManager;
        _error = error.toString();
      });
    }
  }

  Future<void> _authenticate(
    String token, {
    required bool remember,
    required bool allowInsecureHttp,
  }) async {
    final api = PanelApiClient(
      baseUrl: widget.server.url,
      allowInsecureHttp: allowInsecureHttp,
      client: widget.client,
    );
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await api.authenticate(token, remember: remember);
      if (result.requiresVerification) {
        final verified = await _showVerificationDialog(
          api,
          verificationType: result.verificationType,
        );
        if (!verified) {
          try {
            await api.logout();
          } catch (_) {}
          api.close();
          if (mounted) setState(() => _loading = false);
          return;
        }
      }
      if (!mounted) {
        api.close();
        return;
      }
      await widget.credentialStore.write(
        widget.server.url,
        api.sessionCredentials,
      );
      await _loadTasksWithApi(api);
    } catch (error) {
      api.close();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _hasCredential = _api != null;
        _error = error.toString();
      });
    }
  }

  Future<void> _signIn() async {
    final controller = TextEditingController();
    final insecureHttp =
        Uri.parse(widget.server.url).scheme == 'http' &&
        !widget.allowInsecureHttp;
    var trustInsecureHttp = false;
    var remember = true;
    final token = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('连接 FLS 面板'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '管理员 Token'),
                  onChanged: (_) => setDialogState(() {}),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: remember,
                  onChanged: (value) =>
                      setDialogState(() => remember = value ?? false),
                  title: const Text('保持登录 14 天'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                if (insecureHttp) ...[
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: trustInsecureHttp,
                    onChanged: (value) => setDialogState(
                      () => trustInsecureHttp = value ?? false,
                    ),
                    title: const Text('我确认此地址位于可信网络'),
                    subtitle: const Text('HTTP 会以明文传输 Token'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  controller.text.trim().isEmpty ||
                      (insecureHttp && !trustInsecureHttp)
                  ? null
                  : () => Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('连接'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (token == null || !mounted) return;
    await _authenticate(
      token,
      remember: remember,
      allowInsecureHttp: widget.allowInsecureHttp || trustInsecureHttp,
    );
  }

  Future<bool> _showVerificationDialog(
    PanelApiClient api, {
    required String? verificationType,
  }) async {
    final controller = TextEditingController();
    var busy = false;
    String? error;
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> verify() async {
            final code = controller.text.trim();
            if (code.isEmpty || busy) return;
            setDialogState(() {
              busy = true;
              error = null;
            });
            try {
              await api.verifySecondFactor(code);
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext, true);
              }
            } catch (exception) {
              setDialogState(() => error = exception.toString());
            } finally {
              if (dialogContext.mounted) setDialogState(() => busy = false);
            }
          }

          Future<void> resend() async {
            if (busy) return;
            setDialogState(() {
              busy = true;
              error = null;
            });
            try {
              await api.resendVerificationCode();
              setDialogState(() => error = '验证码已重新发送');
            } catch (exception) {
              setDialogState(() => error = exception.toString());
            } finally {
              if (dialogContext.mounted) setDialogState(() => busy = false);
            }
          }

          final isEmailCode = verificationType == 'code';
          return AlertDialog(
            title: Text(isEmailCode ? '输入安全验证码' : '输入身份验证器代码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  maxLength: 12,
                  onChanged: (_) => setDialogState(() {}),
                  onSubmitted: (_) => verify(),
                  decoration: InputDecoration(
                    labelText: isEmailCode ? '验证码' : 'TOTP 验证码',
                    counterText: '',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: TextStyle(
                      color: error == '验证码已重新发送'
                          ? Theme.of(dialogContext).colorScheme.primary
                          : Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              if (isEmailCode)
                TextButton(
                  onPressed: busy ? null : resend,
                  child: const Text('重新发送'),
                ),
              FilledButton(
                onPressed: busy || controller.text.trim().isEmpty
                    ? null
                    : verify,
                child: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('验证'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return verified == true;
  }

  Future<void> _refresh() async {
    final manager = _manager;
    if (manager == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tasks = await manager.fetchTasks();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (await _expireSession(error)) return;
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refreshDashboard() async {
    final manager = _dashboardManager;
    if (manager == null || _dashboardLoading) return;
    setState(() => _dashboardLoading = true);
    try {
      final dashboard = await manager.fetch();
      if (!mounted) return;
      setState(() {
        _dashboard = dashboard;
        _dashboardLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (await _expireSession(error)) return;
      if (!mounted) return;
      setState(() {
        _dashboardLoading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _refreshSelectedTab() async {
    if (_selectedPanelTab == 0) {
      await _refresh();
      await _refreshDashboard();
    } else if (_selectedPanelTab == 1) {
      await _refresh();
    } else {
      await _collectionsKey.currentState?.refresh();
    }
  }

  Future<void> _perform(PanelTaskSummary task, String action) async {
    final manager = _manager;
    if (manager == null || _busyTaskId != null) return;
    if (action != 'toggle') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(action == 'run' ? '运行任务？' : '停止任务？'),
          content: Text('将对“${task.name}”执行${action == 'run' ? '运行' : '停止'}。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _busyTaskId = task.id);
    try {
      await manager.performAction(
        action,
        task.id,
        enabled: action == 'toggle' ? !task.enabled : null,
      );
      await _refreshAfterAction(manager);
    } catch (error) {
      if (mounted) {
        if (!await _expireSession(error) && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    } finally {
      if (mounted) setState(() => _busyTaskId = null);
    }
  }

  void _openTaskDetails(PanelTaskSummary task) {
    final manager = _manager;
    if (manager == null) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelTaskDetailView(
          manager: manager,
          taskId: task.id,
          taskName: task.name,
          onUnauthorized: (error) async {
            if (await _expireSession(error) && mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );
  }

  Future<void> _refreshAfterAction(PanelTasksManager manager) async {
    final tasks = await manager.fetchTasks();
    if (mounted) setState(() => _tasks = tasks);
  }

  Future<bool> _expireSession(Object error, {PanelApiClient? candidate}) async {
    if (error is! PanelApiException || error.statusCode != 401) return false;
    try {
      await widget.credentialStore.delete(widget.server.url);
    } catch (_) {}
    final active = _api;
    candidate?.close();
    active?.close();
    if (!mounted) return true;
    setState(() {
      _api = null;
      _dashboardManager = null;
      _manager = null;
      _tasks = const [];
      _dashboard = null;
      _dashboardLoading = false;
      _loading = false;
      _hasCredential = false;
      _error = '面板会话已过期，请重新连接';
    });
    return true;
  }

  Future<void> _openWebPanel() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteWebView(server: widget.server),
      ),
    );
    if (mounted && _manager != null) await _refresh();
  }

  Future<void> _createTask() async {
    final manager = _manager;
    if (manager == null) return;
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PanelTaskEditorView(
          manager: manager,
          onUnauthorized: (error) async {
            if (await _expireSession(error) && mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );
    if (created == true && mounted) await _refresh();
  }

  List<PanelTaskSummary> get _visibleTasks {
    return _tasks.where((task) {
      if (_filter == _TaskFilter.running && !task.running) return false;
      if (_filter == _TaskFilter.disabled && task.enabled) return false;
      if (_query.isEmpty) return true;
      return task.name.toLowerCase().contains(_query) ||
          task.command.toLowerCase().contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.server.name),
        actions: [
          IconButton(
            tooltip: _selectedPanelTab == 0 ? '刷新概览' : '刷新任务',
            onPressed: _manager == null || _loading || _dashboardLoading
                ? null
                : _refreshSelectedTab,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '打开 Web 面板',
            onPressed: _openWebPanel,
            icon: const Icon(Icons.open_in_browser),
          ),
          PopupMenuButton<String>(
            tooltip: '面板选项',
            onSelected: (value) async {
              if (value == 'auth') await _signIn();
              if (value == 'logout') {
                final api = _api;
                if (api != null) {
                  try {
                    await api.logout();
                  } catch (_) {}
                  api.close();
                }
                await widget.credentialStore.delete(widget.server.url);
                if (!mounted) return;
                setState(() {
                  _api = null;
                  _dashboardManager = null;
                  _manager = null;
                  _tasks = const [];
                  _dashboard = null;
                  _hasCredential = false;
                  _selectedPanelTab = 0;
                  _error = null;
                });
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'auth', child: Text('更换 Token')),
              if (_hasCredential)
                const PopupMenuItem(value: 'logout', child: Text('断开原生连接')),
            ],
          ),
        ],
      ),
      body: _buildBody(context),
      floatingActionButton:
          _hasCredential && _manager != null && _selectedPanelTab == 1
          ? FloatingActionButton.small(
              tooltip: '新建任务',
              onPressed: _createTask,
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: _hasCredential
          ? NavigationBar(
              selectedIndex: _selectedPanelTab,
              onDestinationSelected: (index) {
                setState(() => _selectedPanelTab = index);
                if (index == 0) {
                  unawaited(_refreshDashboard());
                } else if (index == 1) {
                  unawaited(_refresh());
                } else {
                  unawaited(_collectionsKey.currentState?.refresh());
                }
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: '概览',
                ),
                NavigationDestination(
                  icon: Icon(Icons.checklist_outlined),
                  selectedIcon: Icon(Icons.checklist),
                  label: '任务',
                ),
                NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: '合集',
                ),
              ],
            )
          : null,
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _tasks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_hasCredential) return _buildSignInPrompt(context);
    if (_manager == null && _error != null) {
      return _buildConnectionError(context);
    }
    if (_selectedPanelTab == 0) return _buildDashboardBody(context);
    if (_selectedPanelTab == 2) {
      final manager = _manager;
      if (manager == null) return _buildConnectionError(context);
      return PanelCollectionsView(
        key: _collectionsKey,
        manager: manager,
        onUnauthorized: (error) async {
          await _expireSession(error);
        },
      );
    }

    final visible = _visibleTasks;
    return Column(
      children: [
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: _refresh, child: const Text('重试'))],
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            children: [
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: '搜索任务',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<_TaskFilter>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _TaskFilter.all, label: Text('全部')),
                    ButtonSegment(
                      value: _TaskFilter.running,
                      label: Text('运行中'),
                    ),
                    ButtonSegment(
                      value: _TaskFilter.disabled,
                      label: Text('已停用'),
                    ),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (value) =>
                      setState(() => _filter = value.first),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: visible.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 80),
                      Icon(
                        _tasks.isEmpty ? Icons.task_alt : Icons.search_off,
                        size: 36,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Center(child: Text(_tasks.isEmpty ? '暂无任务' : '没有匹配的任务')),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) =>
                        _buildTaskRow(context, visible[index]),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildDashboardBody(BuildContext context) {
    final dashboard = _dashboard;
    final running = _tasks.where((task) => task.running).length;
    final enabled = _tasks.where((task) => task.enabled).length;
    final runCount = _tasks.fold<int>(0, (sum, task) => sum + task.runCount);

    return Column(
      children: [
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(
                onPressed: _refreshSelectedTab,
                child: const Text('重试'),
              ),
            ],
          ),
        if (_dashboardLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshSelectedTab,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (dashboard != null) ...[
                  Text(
                    dashboard.currentTime,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    dashboard.timezone,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else if (!_dashboardLoading)
                  Text(
                    '尚无面板运行信息',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = (constraints.maxWidth - 8) / 2;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _dashboardMetric(
                          context,
                          width,
                          '任务总数',
                          '${_tasks.length}',
                          Icons.checklist,
                        ),
                        _dashboardMetric(
                          context,
                          width,
                          '运行中',
                          '$running',
                          Icons.play_circle_outline,
                        ),
                        _dashboardMetric(
                          context,
                          width,
                          '已启用',
                          '$enabled',
                          Icons.toggle_on_outlined,
                        ),
                        _dashboardMetric(
                          context,
                          width,
                          '累计运行',
                          '$runCount',
                          Icons.history,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                Text('调度器', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    dashboard?.schedulerStatus == 'succeeded'
                        ? Icons.check_circle_outline
                        : Icons.schedule,
                    color: dashboard?.schedulerStatus == 'failed'
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(dashboard?.schedulerStatusLabel ?? '读取中'),
                  subtitle: Text(
                    dashboard == null
                        ? '等待服务端状态'
                        : '${dashboard.scheduledCount} 个任务已加入调度',
                  ),
                ),
                if (dashboard?.schedulerError case final error?
                    when error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (dashboard != null) ...[
                  const Divider(height: 20),
                  Text('面板运行', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Text('已运行 ${dashboard.panelUptime}'),
                  const SizedBox(height: 4),
                  Text(
                    '系统 CPU ${dashboard.systemCpuPercent}  ·  面板 CPU ${dashboard.panelCpuCurrent}（峰值 ${dashboard.panelCpuPeak}）',
                  ),
                  const SizedBox(height: 20),
                  Text('近期调度', style: Theme.of(context).textTheme.titleSmall),
                  if (dashboard.jobs.isEmpty)
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('当前没有待运行的调度任务'),
                    )
                  else
                    ...dashboard.jobs
                        .take(8)
                        .map(
                          (job) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.schedule_outlined),
                            title: Text(
                              job.id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [job.trigger, job.nextRunTime]
                                  .where((value) => value.isNotEmpty)
                                  .join('  ·  '),
                            ),
                          ),
                        ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dashboardMetric(
    BuildContext context,
    double width,
    String label,
    String value,
    IconData icon,
  ) => SizedBox(
    width: width,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildTaskRow(BuildContext context, PanelTaskSummary task) {
    final busy = _busyTaskId == task.id;
    final status = task.running
        ? '运行中${task.pid == null ? '' : ' · PID ${task.pid}'}'
        : task.enabled
        ? '已启用'
        : '已停用';
    final detail = [
      if (task.cron.trim().isNotEmpty) task.cron.trim(),
      '运行 ${task.runCount} 次',
      status,
    ].join('  ·  ');
    return Card(
      child: ListTile(
        onTap: () => _openTaskDetails(task),
        title: Text(task.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
        leading: Icon(
          task.running ? Icons.play_circle_fill : Icons.task_alt,
          color: task.running
              ? Theme.of(context).colorScheme.tertiary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        trailing: busy
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : PopupMenuButton<String>(
                tooltip: '任务操作',
                onSelected: (action) => _perform(task, action),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: task.running ? 'stop' : 'run',
                    child: Text(task.running ? '停止运行' : '立即运行'),
                  ),
                  PopupMenuItem(
                    value: 'toggle',
                    child: Text(task.enabled ? '停用任务' : '启用任务'),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildSignInPrompt(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 36),
            const SizedBox(height: 12),
            Text('连接到 ${widget.server.name}', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _signIn,
              icon: const Icon(Icons.lock_open),
              label: const Text('连接面板'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _buildConnectionError(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 36),
          const SizedBox(height: 12),
          Text(_error ?? '无法连接到面板', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _signIn,
                icon: const Icon(Icons.key),
                label: const Text('更换 Token'),
              ),
              FilledButton.tonalIcon(
                onPressed: _loadSavedCredential,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

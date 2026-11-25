import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/panel_server.dart';
import '../models/panel_collection.dart';
import '../models/panel_dashboard_snapshot.dart';
import '../models/panel_task_page.dart';
import '../models/panel_task_summary.dart';
import '../services/panel_api_client.dart';
import '../services/panel_credential_store.dart';
import '../services/panel_dashboard_manager.dart';
import '../services/panel_online_scripts_manager.dart';
import '../services/panel_records_manager.dart';
import '../services/panel_tasks_manager.dart';
import 'panel_collections_view.dart';
import 'panel_online_scripts_view.dart';
import 'panel_records_view.dart';
import 'panel_task_detail_view.dart';
import 'panel_task_editor_view.dart';
import 'remote_web_view.dart';

enum _TaskFilter { all, running, enabled, disabled }

class _PendingTaskAction {
  const _PendingTaskAction({
    required this.action,
    required this.taskIds,
    required this.requestId,
    this.targetCollectionId,
    this.expectedCollections = const {},
  });

  final String action;
  final List<String> taskIds;
  final String requestId;
  final String? targetCollectionId;
  final Map<String, String> expectedCollections;
}

class _TaskPageControls extends StatelessWidget {
  const _TaskPageControls({
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
  final _onlineScriptsKey = GlobalKey<PanelOnlineScriptsViewState>();
  final _recordsKey = GlobalKey<PanelRecordsViewState>();
  PanelApiClient? _api;
  PanelDashboardManager? _dashboardManager;
  PanelTasksManager? _manager;
  PanelDashboardSnapshot? _dashboard;
  List<PanelTaskSummary> _tasks = const [];
  PanelTaskPage? _taskPage;
  int _selectedPanelTab = 0;
  _TaskFilter _filter = _TaskFilter.all;
  String _sort = 'default';
  String _sortOrder = 'desc';
  String _query = '';
  String? _error;
  String? _taskError;
  String? _busyTaskId;
  bool _taskPageLoading = false;
  int _taskPageRequest = 0;
  final Set<String> _selectedTaskIds = {};
  final Map<String, PanelTaskSummary> _selectedTaskSnapshots = {};
  _PendingTaskAction? _pendingTaskAction;
  Map<String, dynamic>? _lastTaskAction;
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
      await _loadTaskPage(page: _taskPage?.page ?? 1);
    } else if (_selectedPanelTab == 2) {
      await _collectionsKey.currentState?.refresh();
    } else if (_selectedPanelTab == 3) {
      await _recordsKey.currentState?.refresh();
    } else {
      await _onlineScriptsKey.currentState?.refresh();
    }
  }

  Future<void> _loadTaskPage({int page = 1}) async {
    final manager = _manager;
    if (manager == null) return;
    final request = ++_taskPageRequest;
    setState(() {
      _taskPageLoading = true;
      _taskError = null;
    });
    try {
      final data = await manager.fetchTaskPage(
        query: _query,
        status: switch (_filter) {
          _TaskFilter.all => 'all',
          _TaskFilter.running => 'running',
          _TaskFilter.enabled => 'enabled',
          _TaskFilter.disabled => 'disabled',
        },
        sort: _sort,
        order: _sortOrder,
        page: page,
      );
      if (!mounted || request != _taskPageRequest) return;
      setState(() {
        _taskPage = data;
        _taskPageLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _taskPageRequest) return;
      if (await _expireSession(error)) return;
      if (!mounted) return;
      setState(() {
        _taskError = error.toString();
        _taskPageLoading = false;
      });
    }
  }

  Future<bool> _confirmTaskAction(String action, List<String> taskIds) async {
    if (!{'run', 'stop', 'delete'}.contains(action)) return true;
    final label = switch (action) {
      'run' => '立即运行',
      'stop' => '停止运行',
      _ => '删除',
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$label ${taskIds.length} 个任务？'),
        content: Text(
          action == 'delete'
              ? '删除会停止正在运行的任务并从面板移除，无法从 APP 撤销。'
              : '将对已选的 ${taskIds.length} 个任务执行$label。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(label),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  Future<void> _performTaskAction(String action, List<String> taskIds) async {
    final manager = _manager;
    if (manager == null || _busyTaskId != null || taskIds.isEmpty) return;
    if (!await _confirmTaskAction(action, taskIds)) return;
    final pending = _PendingTaskAction(
      action: action,
      taskIds: List.unmodifiable(taskIds),
      requestId: PanelTasksManager.newRequestId(),
    );
    setState(() {
      _busyTaskId = taskIds.length == 1 ? taskIds.single : '*';
      _lastTaskAction = null;
    });
    await _sendTaskAction(pending);
  }

  Future<void> _sendTaskAction(_PendingTaskAction pending) async {
    final manager = _manager;
    if (manager == null) return;
    if (_busyTaskId == null && mounted) {
      setState(
        () => _busyTaskId = pending.taskIds.length == 1
            ? pending.taskIds.single
            : '*',
      );
    }
    try {
      final result = pending.action == 'pin' || pending.action == 'unpin'
          ? await manager.performAction(
              'pin',
              pending.taskIds.single,
              pinned: pending.action == 'pin',
              requestId: pending.requestId,
            )
          : pending.action == 'assign_collection'
          ? await manager.addTasksToCollection(
              collectionId: pending.targetCollectionId!,
              taskIds: pending.taskIds,
              expectedCollections: pending.expectedCollections,
              requestId: pending.requestId,
            )
          : pending.action == 'clear_collection'
          ? await manager.removeTasksFromCollections(
              taskIds: pending.taskIds,
              expectedCollections: pending.expectedCollections,
              requestId: pending.requestId,
            )
          : await manager.performBulkAction(
              pending.action,
              pending.taskIds,
              requestId: pending.requestId,
            );
      if (!mounted) return;
      final completed = _stringList(result['completed_ids']);
      final unknown = _stringList(result['unknown_ids']);
      setState(() {
        _pendingTaskAction = unknown.isEmpty ? null : pending;
        _lastTaskAction = result;
        _busyTaskId = null;
        _selectedTaskIds.removeAll(completed);
        for (final id in completed) {
          _selectedTaskSnapshots.remove(id);
        }
        if (result['ok'] == true && completed.isEmpty) {
          _selectedTaskIds.removeAll(pending.taskIds);
          for (final id in pending.taskIds) {
            _selectedTaskSnapshots.remove(id);
          }
        }
      });
      unawaited(_refresh());
      await _loadTaskPage(page: _taskPage?.page ?? 1);
    } catch (error) {
      if (!mounted) return;
      if (await _expireSession(error)) return;
      if (!mounted) return;
      final hasServerResult = error is PanelApiException && error.data != null;
      setState(() {
        _pendingTaskAction = hasServerResult ? null : pending;
        _lastTaskAction = hasServerResult ? error.data : null;
        _busyTaskId = null;
      });
      if (hasServerResult) {
        unawaited(_refresh());
        unawaited(_loadTaskPage(page: _taskPage?.page ?? 1));
      }
    }
  }

  Future<void> _retryFailedTaskItems() async {
    final result = _lastTaskAction;
    final action = result?['action']?.toString();
    final ids = _stringList(result?['retry_ids']);
    if (action == null || ids.isEmpty || _busyTaskId != null) return;
    await _performTaskAction(action, ids);
  }

  List<String> _stringList(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const [];

  void _toggleTaskSelection(PanelTaskSummary task, bool selected) {
    setState(() {
      if (selected) {
        _selectedTaskIds.add(task.id);
        _selectedTaskSnapshots[task.id] = task;
      } else {
        _selectedTaskIds.remove(task.id);
        _selectedTaskSnapshots.remove(task.id);
      }
    });
  }

  Future<PanelCollection?> _chooseCollection() async {
    final manager = _manager;
    if (manager == null) return null;
    try {
      var page = await manager.fetchCollections(limit: 100);
      final collections = [...page.items];
      for (var index = 2; index <= page.pages; index++) {
        page = await manager.fetchCollections(page: index, limit: 100);
        collections.addAll(page.items);
      }
      if (!mounted) return null;
      if (collections.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先创建任务合集')));
        return null;
      }
      return await showDialog<PanelCollection>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('加入任务合集'),
          children: collections
              .map(
                (collection) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, collection),
                  child: Text(
                    '${collection.name} · ${collection.memberCount} 个任务',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(growable: false),
        ),
      );
    } catch (error) {
      if (await _expireSession(error)) return null;
      if (!mounted) return null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
      return null;
    }
  }

  Future<void> _performMembershipAction(String action) async {
    final ids = _selectedTaskIds.toList(growable: false);
    if (ids.isEmpty || _busyTaskId != null) return;
    String? targetCollectionId;
    var targetIds = ids;
    if (action == 'assign_collection') {
      final collection = await _chooseCollection();
      if (collection == null || !mounted) return;
      targetCollectionId = collection.id;
    } else {
      targetIds = ids
          .where(
            (id) => (_selectedTaskSnapshots[id]?.collectionId ?? '').isNotEmpty,
          )
          .toList(growable: false);
      if (targetIds.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('所选任务不属于任何合集')));
        return;
      }
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(action == 'assign_collection' ? '加入合集？' : '移出合集？'),
        content: Text(
          action == 'assign_collection'
              ? '将 ${targetIds.length} 个任务加入所选合集。'
              : '将 ${targetIds.length} 个任务从各自所属的合集移出，任务仍会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action == 'assign_collection' ? '加入' : '移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final expected = {
      for (final id in targetIds)
        id: _selectedTaskSnapshots[id]?.collectionId ?? '',
    };
    final pending = _PendingTaskAction(
      action: action,
      taskIds: targetIds,
      requestId: PanelTasksManager.newRequestId(),
      targetCollectionId: targetCollectionId,
      expectedCollections: expected,
    );
    setState(() {
      _busyTaskId = '*';
      _lastTaskAction = null;
    });
    await _sendTaskAction(pending);
  }

  Future<void> _reloadScheduler() async {
    final manager = _manager;
    if (manager == null) return;
    try {
      await manager.reloadScheduler();
      if (!mounted) return;
      setState(() => _lastTaskAction = null);
      await _refresh();
      await _loadTaskPage(page: _taskPage?.page ?? 1);
    } catch (error) {
      if (!mounted) return;
      if (!await _expireSession(error) && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _openTaskDetails(PanelTaskSummary task) async {
    final manager = _manager;
    if (manager == null) return;
    await Navigator.of(context).push<void>(
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
    if (mounted) await _loadTaskPage(page: _taskPage?.page ?? 1);
  }

  Future<void> _performTaskMenu(PanelTaskSummary task, String action) async {
    await _performTaskAction(action, [task.id]);
  }

  Widget _taskActionBanner() {
    final pending = _pendingTaskAction;
    final result = _lastTaskAction;
    if (pending == null && result == null) return const SizedBox.shrink();
    final unknown = _stringList(result?['unknown_ids']);
    final retry = _stringList(result?['retry_ids']);
    final message = pending != null
        ? '请求结果未知。使用同一提交标识恢复，不会重复已完成的操作。'
        : (result?['msg']?.toString() ?? '任务操作已返回');
    return MaterialBanner(
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            unknown.isEmpty
                ? message
                : '$message；${unknown.length} 项结果仍未知，请先核对任务状态或历史。',
          ),
          if (_stringList(result?['unknown_ids']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '待核对 ID：${_stringList(result?['unknown_ids']).take(5).join('、')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (result?['results'] is List) ...[
            const SizedBox(height: 4),
            ...((result!['results'] as List)
                .whereType<Map>()
                .take(3)
                .map(
                  (row) => Text(
                    '${row['task_id'] ?? '任务'} · ${row['status'] ?? 'unknown'} · ${row['msg'] ?? ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )),
          ],
        ],
      ),
      actions: [
        if (pending != null)
          TextButton.icon(
            onPressed: _busyTaskId != null
                ? null
                : () => _sendTaskAction(pending),
            icon: const Icon(Icons.replay),
            label: const Text('恢复同一请求'),
          ),
        if (pending == null &&
            retry.isNotEmpty &&
            !{
              'assign_collection',
              'clear_collection',
            }.contains(result?['action']))
          TextButton(
            onPressed: _busyTaskId != null ? null : _retryFailedTaskItems,
            child: Text('重试 ${retry.length} 项'),
          ),
        if (pending == null && result?['reload_required'] == true)
          TextButton(onPressed: _reloadScheduler, child: const Text('重新加载调度器')),
        if (pending == null)
          TextButton(
            onPressed: () => setState(() => _lastTaskAction = null),
            child: const Text('关闭'),
          ),
      ],
    );
  }

  Future<void> _perform(PanelTaskSummary task, String action) async {
    if (action == 'details') {
      await _openTaskDetails(task);
      return;
    }
    await _performTaskMenu(task, action);
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
      _taskPage = null;
      _selectedTaskIds.clear();
      _selectedTaskSnapshots.clear();
      _pendingTaskAction = null;
      _lastTaskAction = null;
      _busyTaskId = null;
      _taskPageRequest++;
      _taskPageLoading = false;
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
    if (created == true && mounted) {
      await _refresh();
      await _loadTaskPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.server.name),
        actions: [
          IconButton(
            tooltip: switch (_selectedPanelTab) {
              0 => '刷新概览',
              1 => '刷新任务',
              2 => '刷新合集',
              3 => '刷新记录',
              _ => '刷新脚本',
            },
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
                  _taskPage = null;
                  _selectedTaskIds.clear();
                  _selectedTaskSnapshots.clear();
                  _pendingTaskAction = null;
                  _lastTaskAction = null;
                  _busyTaskId = null;
                  _taskPageRequest++;
                  _taskPageLoading = false;
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
                  unawaited(_loadTaskPage());
                } else if (index == 2) {
                  unawaited(_collectionsKey.currentState?.refresh());
                } else if (index == 3) {
                  unawaited(_recordsKey.currentState?.refresh());
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
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long),
                  label: '记录',
                ),
                NavigationDestination(
                  icon: Icon(Icons.terminal_outlined),
                  selectedIcon: Icon(Icons.terminal),
                  label: '脚本',
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
    if (_selectedPanelTab == 3) {
      final api = _api;
      if (api == null) return _buildConnectionError(context);
      return PanelRecordsView(
        key: _recordsKey,
        manager: PanelRecordsManager(api),
        onUnauthorized: (error) async {
          await _expireSession(error);
        },
      );
    }
    if (_selectedPanelTab == 4) {
      final api = _api;
      if (api == null) return _buildConnectionError(context);
      return PanelOnlineScriptsView(
        key: _onlineScriptsKey,
        manager: PanelOnlineScriptsManager(api),
        onUnauthorized: (error) async {
          await _expireSession(error);
        },
      );
    }

    final taskPage = _taskPage;
    final visible = taskPage?.items ?? const <PanelTaskSummary>[];
    final visibleIds = visible.map((task) => task.id).toSet();
    final allVisibleSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selectedTaskIds.contains);
    return Column(
      children: [
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: _refresh, child: const Text('重试'))],
          ),
        if (_loading || _taskPageLoading)
          const LinearProgressIndicator(minHeight: 2),
        if (_taskError != null)
          MaterialBanner(
            content: Text(_taskError!),
            actions: [
              TextButton(
                onPressed: () => _loadTaskPage(page: taskPage?.page ?? 1),
                child: const Text('重试'),
              ),
            ],
          ),
        _taskActionBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            children: [
              TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
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
                            unawaited(_loadTaskPage());
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
                onSubmitted: (value) {
                  setState(() => _query = value.trim());
                  unawaited(_loadTaskPage());
                },
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
                      value: _TaskFilter.enabled,
                      label: Text('已启用'),
                    ),
                    ButtonSegment(
                      value: _TaskFilter.disabled,
                      label: Text('已停用'),
                    ),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (value) {
                    setState(() => _filter = value.first);
                    unawaited(_loadTaskPage());
                  },
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        taskPage == null ? '' : '${taskPage.total} 个任务',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  Text(_sortLabel(_sort)),
                  IconButton(
                    tooltip: _sortOrder == 'desc' ? '降序' : '升序',
                    onPressed: () {
                      setState(
                        () =>
                            _sortOrder = _sortOrder == 'desc' ? 'asc' : 'desc',
                      );
                      unawaited(_loadTaskPage());
                    },
                    icon: Icon(
                      _sortOrder == 'desc' ? Icons.south : Icons.north,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '任务排序',
                    onSelected: (value) {
                      setState(() => _sort = value);
                      unawaited(_loadTaskPage());
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'default', child: Text('默认排序')),
                      PopupMenuItem(value: 'name', child: Text('按名称')),
                      PopupMenuItem(value: 'recent_run', child: Text('最近运行')),
                      PopupMenuItem(value: 'last_run', child: Text('最后运行')),
                      PopupMenuItem(value: 'created', child: Text('创建时间')),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.sort, size: 20),
                    ),
                  ),
                ],
              ),
              if (visible.isNotEmpty)
                Row(
                  children: [
                    Checkbox(
                      value: allVisibleSelected,
                      onChanged: _busyTaskId != null
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _selectedTaskIds.addAll(visibleIds);
                                for (final task in visible) {
                                  _selectedTaskSnapshots[task.id] = task;
                                }
                              } else {
                                _selectedTaskIds.removeAll(visibleIds);
                                _selectedTaskSnapshots.removeWhere(
                                  (id, _) => visibleIds.contains(id),
                                );
                              }
                            }),
                    ),
                    Expanded(
                      child: Text(
                        _selectedTaskIds.isEmpty
                            ? '选择当前页'
                            : '已选 ${_selectedTaskIds.length} 个任务',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_selectedTaskIds.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: '批量操作',
                        enabled: _busyTaskId == null,
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'enable', child: Text('启用')),
                          PopupMenuItem(value: 'disable', child: Text('停用')),
                          PopupMenuItem(value: 'run', child: Text('立即运行')),
                          PopupMenuItem(value: 'stop', child: Text('停止运行')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                          PopupMenuItem(
                            value: 'assign_collection',
                            child: Text('加入合集'),
                          ),
                          PopupMenuItem(
                            value: 'clear_collection',
                            child: Text('移出合集'),
                          ),
                        ],
                        onSelected: (action) {
                          if (action == 'assign_collection' ||
                              action == 'clear_collection') {
                            _performMembershipAction(action);
                          } else {
                            _performTaskAction(
                              action,
                              _selectedTaskIds.toList(growable: false),
                            );
                          }
                        },
                      ),
                  ],
                ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _loadTaskPage(page: taskPage?.page ?? 1),
            child: visible.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 80),
                      Icon(
                        taskPage?.total == 0
                            ? Icons.task_alt
                            : Icons.search_off,
                        size: 36,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          taskPage == null
                              ? '正在读取任务'
                              : taskPage.total == 0
                              ? '没有匹配的任务'
                              : '暂无任务',
                        ),
                      ),
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
        if (taskPage != null && taskPage.pages > 1)
          _TaskPageControls(
            page: taskPage.page,
            pages: taskPage.pages,
            onPage: (page) => _loadTaskPage(page: page),
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
    final busy = _busyTaskId == task.id || _busyTaskId == '*';
    final selected = _selectedTaskIds.contains(task.id);
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
        onTap: () => _selectedTaskIds.isNotEmpty
            ? _toggleTaskSelection(task, !selected)
            : _openTaskDetails(task),
        onLongPress: () => _toggleTaskSelection(task, !selected),
        title: Row(
          children: [
            Expanded(
              child: Text(
                task.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (task.pinned) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.push_pin,
                size: 16,
                color: Theme.of(context).colorScheme.tertiary,
              ),
            ],
          ],
        ),
        subtitle: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
        leading: Checkbox(
          value: selected,
          onChanged: busy
              ? null
              : (value) => _toggleTaskSelection(task, value == true),
        ),
        trailing: busy
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : PopupMenuButton<String>(
                tooltip: '任务操作',
                enabled: _busyTaskId == null,
                onSelected: (action) => _perform(task, action),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'details', child: const Text('查看详情')),
                  PopupMenuItem(
                    value: task.running ? 'stop' : 'run',
                    child: Text(task.running ? '停止运行' : '立即运行'),
                  ),
                  PopupMenuItem(
                    value: task.enabled ? 'disable' : 'enable',
                    child: Text(task.enabled ? '停用任务' : '启用任务'),
                  ),
                  PopupMenuItem(
                    value: task.pinned ? 'unpin' : 'pin',
                    child: Text(task.pinned ? '取消置顶' : '置顶任务'),
                  ),
                  const PopupMenuItem(value: 'copy', child: Text('复制任务')),
                  const PopupMenuItem(value: 'delete', child: Text('删除任务')),
                ],
              ),
      ),
    );
  }

  String _sortLabel(String sort) => switch (sort) {
    'name' => '名称',
    'recent_run' => '最近运行',
    'last_run' => '最后运行',
    'created' => '创建时间',
    _ => '默认排序',
  };

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

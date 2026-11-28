import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/panel_backup.dart';
import '../services/local_file_bridge.dart';
import '../services/panel_api_client.dart';
import '../services/panel_backup_manager.dart';
import 'panel_directory_maintenance_view.dart';
import 'panel_dependency_maintenance_view.dart';

class PanelBackupView extends StatelessWidget {
  const PanelBackupView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
  });

  final PanelBackupManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  Widget build(BuildContext context) => _PanelBackupSession(
    key: ObjectKey(manager),
    manager: manager,
    onUnauthorized: onUnauthorized,
  );
}

class _PanelBackupSession extends StatefulWidget {
  const _PanelBackupSession({
    super.key,
    required this.manager,
    required this.onUnauthorized,
  });

  final PanelBackupManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_PanelBackupSession> createState() => _PanelBackupViewState();
}

class _PanelBackupViewState extends State<_PanelBackupSession>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabs;
  PanelBackupCapabilities? _capabilities;
  PanelBackupFilesPage? _files;
  PanelBackupJobsPage? _jobs;
  PanelBackupPreflight? _preflight;
  PanelBackupRestore? _restore;
  PanelBackupRestoresPage? _restoreHistory;
  PanelBackupMaintenance? _restoreMaintenance;
  String? _restoreHistoryError;
  bool _restoreHistoryLoading = false;
  int _restoreHistoryRequest = 0;
  bool _sessionExpired = false;
  bool _background = false;
  int _foregroundGeneration = 0;
  Route<dynamic>? _confirmationRoute;
  String? _preflightRequestId;
  String? _restoreRequestId;
  String? _preflightError;
  bool _preflightQueryAvailable = false;
  final Set<String> _restoreItems = {};
  bool _restoreDependencies = false;
  bool _stagingArchive = false;
  int _uploadSentBytes = 0;
  int _uploadTotalBytes = 0;
  String? _error;
  String? _busy;
  String? _downloadName;
  int _downloadedBytes = 0;
  int? _downloadTotalBytes;
  int _filePage = 1;
  int _jobPage = 1;
  bool _loading = true;
  bool _refreshing = false;

  bool get _canInteract => mounted && !_sessionExpired && !_background;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _background = lifecycle != null && lifecycle != AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _tabs = TabController(length: 4, vsync: this);
    unawaited(_load());
  }

  @override
  void dispose() {
    _closeConfirmation();
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() => _background = state != AppLifecycleState.resumed);
    if (_background) {
      _foregroundGeneration++;
      _closeConfirmation();
    }
  }

  void _closeConfirmation() {
    final route = _confirmationRoute;
    _confirmationRoute = null;
    final navigator = route?.navigator;
    if (route == null || navigator == null) return;
    scheduleMicrotask(() {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
    });
  }

  Future<T?> _confirm<T>({required WidgetBuilder builder}) async {
    if (!_canInteract ||
        _confirmationRoute != null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return null;
    }
    final route = DialogRoute<T>(context: context, builder: builder);
    _confirmationRoute = route;
    try {
      final result = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      return _canInteract && identical(_confirmationRoute, route)
          ? result
          : null;
    } finally {
      if (identical(_confirmationRoute, route)) _confirmationRoute = null;
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      if (!refresh) _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait<Object>([
        widget.manager.fetchCapabilities(),
        widget.manager.fetchFiles(page: _filePage),
        widget.manager.fetchJobs(page: _jobPage),
      ]);
      final capabilities = values[0] as PanelBackupCapabilities;
      PanelBackupMaintenance? maintenance;
      if (capabilities.restoreEnabled) {
        try {
          maintenance = await widget.manager.fetchRestoreMaintenance();
        } catch (error) {
          if (await _handleUnauthorized(error)) return;
        }
      }
      if (!mounted || _sessionExpired) return;
      setState(() {
        _capabilities = capabilities;
        _files = values[1] as PanelBackupFilesPage;
        _jobs = values[2] as PanelBackupJobsPage;
        _restoreMaintenance = maintenance;
        _loading = false;
      });
      if (capabilities.restoreEnabled) await _loadRestoreHistory();
    } catch (error) {
      if (!mounted) return;
      if (await _handleUnauthorized(error)) return;
      setState(() {
        _error = _messageFor(error);
        _loading = false;
      });
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<bool> _handleUnauthorized(Object error) async {
    if (!mounted || _sessionExpired) return true;
    if (error is PanelApiException && error.statusCode == 401) {
      setState(() => _sessionExpired = true);
      _restoreHistoryRequest++;
      _closeConfirmation();
      await widget.onUnauthorized(error);
      return true;
    }
    return false;
  }

  String _messageFor(Object error) =>
      error is PanelApiException ? error.message : error.toString();

  void _notice(String message) {
    if (!_canInteract) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createBackup() async {
    final capabilities = _capabilities;
    if (capabilities == null || _busy != null) return;
    final selected = await _confirm<List<String>>(
      builder: (context) => _BackupScopeDialog(available: capabilities.items),
    );
    if (!mounted || selected == null || selected.isEmpty) return;
    final requestId = PanelBackupManager.newRequestId();
    setState(() => _busy = 'create');
    var message = '备份请求已提交';
    try {
      final response = await widget.manager.create(
        requestId: requestId,
        items: selected,
      );
      if (response['accepted'] != true) message = '备份请求状态待确认';
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      try {
        final request = await widget.manager.requestStatus(requestId);
        message = switch (request.status) {
          'succeeded' => '备份已完成',
          'failed' => '备份创建失败',
          'running' || 'preparing' || 'cancelling' => '备份任务仍在运行',
          _ => '备份请求状态未知，请稍后查看作业列表',
        };
      } catch (queryError) {
        if (await _handleUnauthorized(queryError)) return;
        message = '无法确认原请求；未重复提交，请检查作业列表';
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!mounted) return;
    _notice(message);
    await _load(refresh: true);
  }

  Future<void> _deleteBackup(PanelBackupFile file) async {
    final confirmed = await _confirm<bool>(
      builder: (context) => AlertDialog(
        title: const Text('删除备份'),
        content: Text('${file.name}\n${_formatBytes(file.sizeBytes)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _busy != null) return;
    final requestId = PanelBackupManager.newRequestId();
    setState(() => _busy = 'delete:${file.name}');
    var message = '备份已删除';
    try {
      final response = await widget.manager.deleteFile(
        requestId: requestId,
        file: file,
      );
      if (response['deleted'] != true) message = '删除状态待确认';
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      try {
        final request = await widget.manager.requestStatus(requestId);
        message = request.status == 'succeeded'
            ? '备份已删除'
            : '删除结果未知；未重复操作，请刷新核对';
      } catch (queryError) {
        if (await _handleUnauthorized(queryError)) return;
        message = '无法确认删除结果；未重复操作，请刷新核对';
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!mounted) return;
    _notice(message);
    await _load(refresh: true);
  }

  Future<void> _downloadBackup(PanelBackupFile file) async {
    if (_busy != null) return;
    setState(() {
      _busy = 'download:${file.name}';
      _downloadName = file.name;
      _downloadedBytes = 0;
      _downloadTotalBytes = file.sizeBytes;
    });
    String? temporaryPath;
    var saved = false;
    try {
      final directory = await getTemporaryDirectory();
      if (!_canInteract) return;
      temporaryPath = p.join(
        directory.path,
        'fls-backup-${DateTime.now().microsecondsSinceEpoch}.tar.gz',
      );
      await widget.manager.downloadFile(
        file: file,
        destinationPath: temporaryPath,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _downloadedBytes = received;
            _downloadTotalBytes = total;
          });
        },
      );
      if (!_canInteract) return;
      saved = await LocalFileBridge.saveFile(
        path: temporaryPath,
        filename: file.name,
      );
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      _notice(_messageFor(error));
    } finally {
      if (temporaryPath != null) {
        try {
          await File(temporaryPath).delete();
        } on FileSystemException {
          // Partial downloads are removed by PanelApiClient.
        }
      }
      if (mounted) {
        setState(() {
          _busy = null;
          _downloadName = null;
          _downloadTotalBytes = null;
        });
      }
    }
    if (mounted && saved) _notice('备份已导出');
  }

  Future<void> _cancelJob(PanelBackupJob job) async {
    if (_busy != null || !job.cancelAllowed) return;
    setState(() => _busy = 'cancel:${job.id}');
    var message = '已请求取消，等待作业终态';
    try {
      final response = await widget.manager.cancel(job.id);
      if (response['accepted'] != true) message = '作业当前不可取消';
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      try {
        final current = await widget.manager.fetchJob(job.id);
        message = switch (current.status) {
          'cancelled' => '备份已取消',
          'succeeded' => '备份已完成，取消未生效',
          'failed' => '备份已失败',
          _ => '取消状态未知，请查看作业状态',
        };
      } catch (queryError) {
        if (await _handleUnauthorized(queryError)) return;
        message = '无法确认取消结果，请刷新作业状态';
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!mounted) return;
    _notice(message);
    await _load(refresh: true);
  }

  Future<void> _selectRestoreArchive() async {
    final capabilities = _capabilities;
    if (capabilities == null ||
        !capabilities.preflightEnabled ||
        _busy != null) {
      return;
    }
    if (_restoreRequestId != null &&
        (_restore == null ||
            _restore!.active ||
            _restore!.restoreOutcomeUnknown)) {
      _notice('先查询并核对原恢复请求，再选择新的备份');
      return;
    }
    final picked = await LocalFileBridge.pickScriptImport();
    if (!mounted || _sessionExpired || _busy != null || picked == null) return;
    final lower = picked.name.toLowerCase();
    if (!const ['.tar.gz', '.tgz', '.tar', '.zip'].any(lower.endsWith)) {
      _notice('仅支持 TAR.GZ、TGZ、TAR 或 ZIP 备份');
      return;
    }

    final requestId = PanelBackupManager.newRequestId();
    String? temporaryPath;
    setState(() {
      _busy = 'preflight';
      _preflight = null;
      _restore = null;
      _restoreRequestId = null;
      _restoreItems.clear();
      _restoreDependencies = false;
      _preflightRequestId = requestId;
      _preflightError = null;
      _preflightQueryAvailable = false;
      _stagingArchive = true;
      _uploadSentBytes = 0;
      _uploadTotalBytes = 0;
    });
    try {
      final directory = await getTemporaryDirectory();
      temporaryPath = p.join(directory.path, 'fls-preflight-$requestId.upload');
      final copied = await LocalFileBridge.copyUriToPath(
        uri: picked.uri,
        path: temporaryPath,
        maxBytes: capabilities.uploadLimitBytes,
      );
      if (!copied) throw const PanelApiException('无法读取所选备份文件');
      final size = await File(temporaryPath).length();
      if (!_canInteract) return;
      setState(() {
        _stagingArchive = false;
        _uploadTotalBytes = size;
      });
      _preflightQueryAvailable = true;
      final result = await widget.manager.createPreflight(
        filePath: temporaryPath,
        filename: picked.name,
        requestId: requestId,
        maxBytes: capabilities.uploadLimitBytes,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _uploadSentBytes = sent;
            _uploadTotalBytes = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _preflight = result;
      });
      final finalResult = result.active
          ? await _waitForPreflight(result)
          : result;
      if (!mounted) return;
      setState(() {
        _preflight = finalResult;
        _restoreItems
          ..clear()
          ..addAll(finalResult.items);
        _restoreDependencies = false;
        if (finalResult.status == 'failed' ||
            finalResult.status == 'cancelled') {
          _preflightError = _preflightErrorLabel(finalResult.errorCode);
        }
      });
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      if (!_preflightQueryAvailable ||
          (error is PanelApiException &&
              error.statusCode != null &&
              error.statusCode! >= 400 &&
              error.statusCode! < 500 &&
              error.statusCode != 422)) {
        setState(() => _preflightError = _messageFor(error));
        return;
      }
      try {
        var result = await widget.manager.fetchPreflight(requestId);
        if (result.active) result = await _waitForPreflight(result);
        if (!mounted || _sessionExpired) return;
        setState(() {
          _preflight = result;
          _restoreItems
            ..clear()
            ..addAll(result.items);
          _restoreDependencies = false;
          _preflightError =
              result.status == 'failed' || result.status == 'cancelled'
              ? _preflightErrorLabel(result.errorCode)
              : null;
        });
      } catch (queryError) {
        if (await _handleUnauthorized(queryError)) return;
        if (!mounted) return;
        setState(() => _preflightError = '无法确认原预检查结果；未重复上传。可查询原请求或重新选择文件。');
      }
    } finally {
      if (temporaryPath != null) {
        try {
          await File(temporaryPath).delete();
        } on FileSystemException {
          // Temporary archive content is not retained in operation history.
        }
      }
      if (mounted) {
        setState(() {
          _busy = null;
          _stagingArchive = false;
        });
      }
    }
  }

  Future<void> _queryPreflight() async {
    final requestId = _preflightRequestId;
    if (requestId == null || _busy != null) return;
    setState(() {
      _busy = 'preflight-query';
      _preflightError = null;
    });
    try {
      var result = await widget.manager.fetchPreflight(requestId);
      if (result.active) result = await _waitForPreflight(result);
      if (!mounted) return;
      setState(() {
        _preflight = result;
        _restoreItems
          ..clear()
          ..addAll(result.items);
        _restoreDependencies = false;
        if (result.status == 'failed' || result.status == 'cancelled') {
          _preflightError = _preflightErrorLabel(result.errorCode);
        }
      });
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      setState(() => _preflightError = '原预检查暂不可查询；没有重新上传。');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<PanelBackupPreflight> _waitForPreflight(
    PanelBackupPreflight initial,
  ) async {
    var result = initial;
    while (result.active && mounted) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) break;
      result = await widget.manager.fetchPreflight(result.requestId);
      if (!mounted) break;
      setState(() {
        _preflight = result;
        if (result.status == 'ready') {
          _restoreItems
            ..clear()
            ..addAll(result.items);
          _restoreDependencies = false;
        }
      });
    }
    return result;
  }

  Future<void> _cancelPreflight() async {
    final requestId = _preflightRequestId;
    if (requestId == null) return;
    try {
      final result = await widget.manager.cancelPreflight(requestId);
      if (!mounted) return;
      setState(() {
        _preflight = result;
        _preflightError = '已请求取消，等待面板确认结果。';
      });
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      if (!mounted) return;
      setState(() => _preflightError = '无法确认取消请求；请查询原预检查状态。');
    }
  }

  Future<void> _submitRestore() async {
    final preflight = _preflight;
    final selected = _restoreItems.toList(growable: false);
    if (preflight == null ||
        preflight.status != 'ready' ||
        selected.isEmpty ||
        _busy != null ||
        _capabilities?.restoreEnabled != true ||
        _restoreRequestId != null) {
      return;
    }
    final restoreDependencies = _restoreDependencies;
    final confirmed = await _confirm<bool>(
      builder: (context) => AlertDialog(
        title: const Text('确认恢复'),
        content: Text(
          '归档：${preflight.filename}\n'
          '范围：${selected.map(_scopeLabel).join('、')}\n'
          '${selected.contains('data') ? '配置恢复可能改变面板访问、安全验证和任务配置。当前原生会话及签名密钥会保留。\n' : ''}'
          '${restoreDependencies ? '目录恢复后可另行确认并启动依赖安装，最长 30 分钟。\n' : ''}'
          '恢复期间不可取消。结果未知时只查询原请求，不要重新导入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回检查'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('提交恢复'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final requestId = PanelBackupManager.newRequestId();
    setState(() {
      _busy = 'restore';
      _restoreRequestId = requestId;
      _restore = null;
      _preflightError = null;
    });
    try {
      var result = await widget.manager.createRestore(
        requestId: requestId,
        preflight: preflight,
        items: selected,
        restoreDependencies: restoreDependencies,
        confirmDataImpact: selected.contains('data'),
      );
      result = await _observeRestore(result);
      if (!mounted) return;
      setState(() => _restore = result);
    } catch (error) {
      if (!mounted || _sessionExpired) return;
      if (await _handleUnauthorized(error)) return;
      try {
        final result = await _observeRestore(
          await widget.manager.fetchRestore(requestId),
        );
        if (!mounted) return;
        setState(() => _restore = result);
        _notice(
          result.restoreOutcomeUnknown
              ? '恢复结果未知；请核对面板状态，不要重新导入'
              : '已查询原恢复请求，没有重新提交',
        );
      } catch (queryError) {
        if (await _handleUnauthorized(queryError)) return;
        if (!mounted) return;
        _notice('无法确认恢复结果；原请求 $requestId 保留，请稍后查询，不要重复恢复');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
      unawaited(_loadRestoreHistory());
    }
  }

  Future<PanelBackupRestore> _waitForRestore(PanelBackupRestore initial) async {
    var result = initial;
    while (result.active && mounted && !_sessionExpired) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted || _sessionExpired) break;
      result = await widget.manager.fetchRestore(result.requestId);
      if (!mounted) break;
      setState(() => _restore = result);
    }
    return result;
  }

  Future<PanelBackupRestore> _observeRestore(PanelBackupRestore initial) async {
    var result = initial;
    if (result.active) result = await _waitForRestore(result);
    if (mounted && !_sessionExpired && result.scheduler.state == 'running') {
      result = await _waitForFollowup(result, dependencies: false);
    }
    if (mounted && !_sessionExpired && result.dependencies.state == 'running') {
      result = await _waitForFollowup(result, dependencies: true);
    }
    return result;
  }

  Future<void> _queryRestore() async {
    final requestId = _restoreRequestId;
    if (requestId == null || _busy != null) return;
    setState(() => _busy = 'restore-query');
    try {
      final result = await _observeRestore(
        await widget.manager.fetchRestore(requestId),
      );
      if (!mounted) return;
      setState(() => _restore = result);
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      if (mounted) _notice('原恢复请求暂不可查询；没有重新提交');
    } finally {
      if (mounted) setState(() => _busy = null);
      unawaited(_loadRestoreHistory());
    }
  }

  Future<void> _loadRestoreHistory({int? offset}) async {
    if (!mounted || _sessionExpired) return;
    final request = ++_restoreHistoryRequest;
    final targetOffset = offset ?? _restoreHistory?.offset ?? 0;
    setState(() {
      _restoreHistoryLoading = true;
      _restoreHistoryError = null;
    });
    try {
      final result = await widget.manager.fetchRestores(
        limit: 25,
        offset: targetOffset,
      );
      if (!mounted || _sessionExpired || request != _restoreHistoryRequest) {
        return;
      }
      setState(() => _restoreHistory = result);
    } catch (error) {
      if (!mounted || _sessionExpired || request != _restoreHistoryRequest) {
        return;
      }
      if (await _handleUnauthorized(error)) return;
      if (mounted) setState(() => _restoreHistoryError = '恢复历史暂不可用，请重试');
    } finally {
      if (mounted && request == _restoreHistoryRequest) {
        setState(() => _restoreHistoryLoading = false);
      }
    }
  }

  Future<void> _queryHistoryItem(PanelBackupRestore restore) async {
    if (_busy != null) return;
    setState(() {
      _busy = 'restore-query';
      _restoreRequestId = restore.requestId;
    });
    try {
      final result = await _observeRestore(
        await widget.manager.fetchRestore(restore.requestId),
      );
      if (mounted) setState(() => _restore = result);
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      if (mounted) _notice('原恢复请求暂不可查询');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _resolveUnknownRestore(
    PanelBackupRestore restore, {
    required bool directoriesRestored,
  }) async {
    if (restore.directoryRecoveryRequired || _sessionExpired || _busy != null) {
      return;
    }
    final confirmed = await _confirm<bool>(
      builder: (context) => AlertDialog(
        title: const Text('人工确认恢复结果'),
        content: Text(
          directoriesRestored
              ? '请先在面板实际检查所选目录。确认归档内容已完整替换目标目录后，才可选择此项；这不会再写入目录。'
              : '请先检查配置和脚本目录。仅当确认恢复没有应用且原目录完整保留时，才可选择此项。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续检查'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('我已检查并确认'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _busy != null) return;
    setState(() => _busy = 'restore-resolve');
    try {
      final result = await widget.manager.resolveRestore(
        requestId: restore.requestId,
        restored: directoriesRestored,
      );
      if (mounted) setState(() => _restore = result);
      unawaited(_loadRestoreHistory());
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      if (mounted) _notice('人工确认未能保存；请查询原恢复请求');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _runFollowup({required bool dependencies}) async {
    final restore = _restore;
    if (restore == null ||
        _busy != null ||
        !restore.committed ||
        restore.directoryRecoveryRequired ||
        restore.dependencies.cleanupRequired ||
        restore.restoreOutcomeUnknown) {
      return;
    }
    final current = dependencies ? restore.dependencies : restore.scheduler;
    final isRetry = const {
      'failed',
      'unknown',
      'succeeded',
    }.contains(current.state);
    final confirmed = await _confirm<bool>(
      builder: (context) => AlertDialog(
        title: Text(dependencies ? '安装恢复依赖' : '重新加载调度器'),
        content: Text(
          dependencies
              ? '这会在面板环境运行依赖清单中的 pip 安装。请检查作业输出；不得因结果未知而自动重试。'
              : '这只重新加载当前任务调度器，不会再次覆盖目录。请先核对已恢复任务。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认执行'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = dependencies ? 'dependencies' : 'scheduler');
    try {
      final operationId = PanelBackupManager.newRequestId();
      var result = dependencies
          ? await widget.manager.installRestoreDependencies(
              requestId: restore.requestId,
              operationId: operationId,
              confirmRetry: isRetry,
            )
          : await widget.manager.reloadScheduler(
              requestId: restore.requestId,
              operationId: operationId,
              confirmRetry: isRetry,
            );
      if ((dependencies ? result.dependencies : result.scheduler).state ==
          'running') {
        result = await _waitForFollowup(result, dependencies: dependencies);
      }
      if (mounted) setState(() => _restore = result);
    } catch (error) {
      if (!mounted || _sessionExpired) return;
      if (await _handleUnauthorized(error)) return;
      try {
        var result = await widget.manager.fetchRestore(restore.requestId);
        if ((dependencies ? result.dependencies : result.scheduler).state ==
            'running') {
          result = await _waitForFollowup(result, dependencies: dependencies);
        }
        if (mounted) setState(() => _restore = result);
        _notice('后续操作结果已通过原恢复请求查询');
      } catch (queryError) {
        if (await _handleUnauthorized(queryError)) return;
        if (mounted) _notice('后续操作结果未知；只查询原恢复请求，不要重复恢复目录');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _recoverRestoreDirectories(PanelBackupRestore restore) async {
    if (!restore.directoryRecoveryRequired ||
        _busy != null ||
        _sessionExpired) {
      return;
    }
    final confirmed = await _confirm<bool>(
      builder: (context) => AlertDialog(
        title: const Text('恢复目录现场'),
        content: const Text(
          '面板将根据原恢复记录核对目录和实例身份。未完成的替换会回滚，已完成的替换会保留；核对失败时保留现场供后续处理。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认恢复现场'),
          ),
        ],
      ),
    );
    if (!mounted || _sessionExpired || confirmed != true || _busy != null) {
      return;
    }
    setState(() => _busy = 'directory-recovery');
    try {
      final result = await widget.manager.recoverRestoreDirectories(
        restore.requestId,
      );
      if (!mounted || _sessionExpired) return;
      setState(() => _restore = result);
      _notice(
        result.directoryRecoveryRequired ? '目录现场仍需处理，请查询原请求' : '目录现场已核对并恢复',
      );
    } catch (error) {
      if (!mounted || _sessionExpired) return;
      if (await _handleUnauthorized(error)) return;
      try {
        final result = await widget.manager.fetchRestore(restore.requestId);
        if (!mounted || _sessionExpired) return;
        setState(() => _restore = result);
        _notice(
          result.directoryRecoveryRequired
              ? '目录现场尚未恢复完成，请核对后重试'
              : '现场恢复结果已通过原请求查询',
        );
      } catch (queryError) {
        if (await _handleUnauthorized(queryError)) return;
        if (mounted && !_sessionExpired) _notice('现场恢复结果未知，请查询原恢复请求');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
      unawaited(_loadRestoreHistory());
    }
  }

  Future<void> _cleanupRestoreDependencies() async {
    final restore = _restore;
    if (restore == null ||
        _busy != null ||
        !restore.dependencies.cleanupRequired) {
      return;
    }
    final confirmed = await _confirm<bool>(
      builder: (context) => AlertDialog(
        title: const Text('清理依赖作业'),
        content: const Text('终止原依赖作业的残留进程并清理其临时文件。此操作不会再次安装依赖或恢复目录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (!mounted || _sessionExpired || confirmed != true) return;
    final foregroundGeneration = _foregroundGeneration;
    setState(() => _busy = 'dependency-cleanup');
    try {
      var result = await widget.manager.cleanupRestoreDependencies(
        requestId: restore.requestId,
        operationId: restore.dependencies.operationId,
      );
      if (!mounted || _sessionExpired) return;
      setState(() => _restore = result);
      final accepted = result.dependencyCleanupRequested;
      if (accepted && result.dependencies.cleanupRequired) {
        result = await _waitForDependencyCleanup(
          result,
          foregroundGeneration: foregroundGeneration,
        );
        if (!mounted || _sessionExpired) return;
        setState(() => _restore = result);
      }
      _notice(
        result.dependencies.cleanupRequired
            ? accepted
                  ? '清理已受理，仍在等待面板确认；可查询原作业'
                  : '清理尚未确认，请查询原作业'
            : '依赖作业已清理，请核对原安装结果',
      );
    } catch (error) {
      if (!mounted || _sessionExpired) return;
      if (await _handleUnauthorized(error)) return;
      if (!_canInteract || foregroundGeneration != _foregroundGeneration) {
        return;
      }
      try {
        final result = await widget.manager.fetchRestore(
          restore.requestId,
          expectedDependencyOperationId: restore.dependencies.operationId,
        );
        if (!mounted || _sessionExpired) return;
        setState(() => _restore = result);
        _notice(
          result.dependencies.cleanupRequired
              ? '清理尚未完成，可查询原作业后再次清理'
              : '依赖清理结果已通过原请求查询',
        );
      } catch (queryError) {
        if (await _handleUnauthorized(queryError)) return;
        if (mounted && !_sessionExpired) _notice('清理结果未知，请查询原恢复请求');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<PanelBackupRestore> _waitForDependencyCleanup(
    PanelBackupRestore initial, {
    required int foregroundGeneration,
  }) async {
    bool isCurrent() =>
        _canInteract && foregroundGeneration == _foregroundGeneration;
    var result = initial;
    for (
      var attempt = 0;
      attempt < 15 && result.dependencies.cleanupRequired && isCurrent();
      attempt++
    ) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!isCurrent()) break;
      final next = await widget.manager.fetchRestore(
        initial.requestId,
        expectedDependencyOperationId: initial.dependencies.operationId,
      );
      if (!isCurrent()) break;
      result = next;
      setState(() => _restore = result);
    }
    return result;
  }

  Future<PanelBackupRestore> _waitForFollowup(
    PanelBackupRestore initial, {
    required bool dependencies,
  }) async {
    var result = initial;
    while ((dependencies ? result.dependencies : result.scheduler).state ==
            'running' &&
        mounted &&
        !_sessionExpired) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted || _sessionExpired) break;
      result = await widget.manager.fetchRestore(result.requestId);
      if (mounted) setState(() => _restore = result);
    }
    return result;
  }

  String _preflightErrorLabel(String code) => switch (code) {
    'preflight_checking' => '面板正在校验归档…',
    'preflight_cancelled' => '预检查已取消，暂存归档已清理',
    'archive_limit_exceeded' => '备份超过面板的上传、展开或条目限制',
    'insufficient_storage' => '面板剩余空间不足，未展开或写入备份数据',
    'unsafe_archive_entry' => '备份包含不安全的路径、链接或文件类型',
    'missing_backup_scope' => '归档中未找到 data 或 scripts 备份目录',
    'unsupported_format' => '备份格式不受支持',
    'preflight_expired' => '预检查已过期，请重新选择备份文件',
    _ => '备份校验失败，请检查归档后重试',
  };

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    if (_background || _sessionExpired) {
      return Scaffold(appBar: AppBar(title: const Text('备份恢复')));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份恢复'),
        actions: [
          if (_capabilities?.preflightEnabled == true)
            IconButton(
              tooltip: '预检查备份',
              onPressed: _busy == null ? _selectRestoreArchive : null,
              icon: const Icon(Icons.upload_file_outlined),
            ),
          IconButton(
            tooltip: '创建备份',
            onPressed: _busy == null ? _createBackup : null,
            icon: const Icon(Icons.add_to_drive_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _refreshing ? null : () => _load(refresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            Tab(text: '文件${_files == null ? '' : ' · ${_files!.total}'}'),
            Tab(text: '作业${_jobs == null ? '' : ' · ${_jobs!.total}'}'),
            const Tab(text: '恢复'),
            const Tab(text: '现场维护'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_downloadName != null) _downloadProgress(),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: () => _load(refresh: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          Expanded(
            child: _loading && _files == null
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabs,
                    children: [
                      _filesTab(),
                      _jobsTab(),
                      _restoreTab(),
                      DefaultTabController(
                        key: ObjectKey(widget.manager),
                        length: 2,
                        child: Column(
                          children: [
                            const TabBar(
                              tabs: [
                                Tab(text: '目录现场'),
                                Tab(text: '依赖资源'),
                              ],
                            ),
                            Expanded(
                              child: TabBarView(
                                children: [
                                  PanelDirectoryMaintenanceView(
                                    manager: widget.manager,
                                    onUnauthorized: (error) async {
                                      await _handleUnauthorized(error);
                                    },
                                  ),
                                  PanelDependencyMaintenanceView(
                                    manager: widget.manager,
                                    onUnauthorized: (error) async {
                                      await _handleUnauthorized(error);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _downloadProgress() {
    final total = _downloadTotalBytes;
    final fraction = total == null || total <= 0
        ? null
        : (_downloadedBytes / total).clamp(0.0, 1.0);
    final amount = total == null
        ? '${_formatBytes(_downloadedBytes)} / 总量未知'
        : '${_formatBytes(_downloadedBytes)} / ${_formatBytes(total)}'
              '${fraction == null ? '' : ' · ${(fraction * 100).round()}%'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_downloadName!, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 4),
          Text(amount, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _filesTab() {
    final page = _files;
    if (page == null) return const SizedBox.shrink();
    if (page.items.isEmpty) {
      return const Center(child: Text('暂无备份文件'));
    }
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: page.items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final file = page.items[index];
              final deleting = _busy == 'delete:${file.name}';
              final downloading = _busy == 'download:${file.name}';
              return ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_formatBytes(file.sizeBytes)} · ${file.modifiedAt}',
                ),
                trailing: PopupMenuButton<String>(
                  tooltip: deleting
                      ? '正在删除'
                      : downloading
                      ? '正在导出'
                      : '备份操作',
                  enabled: _busy == null,
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) {
                    if (action == 'download') unawaited(_downloadBackup(file));
                    if (action == 'delete') unawaited(_deleteBackup(file));
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'download',
                      child: Row(
                        children: [
                          Icon(Icons.download_outlined),
                          SizedBox(width: 12),
                          Text('导出'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline),
                          SizedBox(width: 12),
                          Text('删除'),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        _PageControl(
          page: page.page,
          pages: page.pages,
          onPage: (value) {
            setState(() => _filePage = value);
            unawaited(_load(refresh: true));
          },
        ),
      ],
    );
  }

  Widget _jobsTab() {
    final page = _jobs;
    if (page == null) return const SizedBox.shrink();
    if (page.items.isEmpty) {
      return const Center(child: Text('暂无备份作业'));
    }
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: page.items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final job = page.items[index];
              final scope = job.items.map(_scopeLabel).join(' + ');
              return ListTile(
                leading: Icon(job.active ? Icons.downloading : Icons.history),
                title: Text(_statusLabel(job.status)),
                subtitle: Text(
                  [
                    scope,
                    if (job.filename.isNotEmpty) job.filename,
                    if (job.sizeBytes > 0) _formatBytes(job.sizeBytes),
                    if (job.cleanupRequired) '需清理暂存归档',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: job.cancelAllowed
                    ? IconButton(
                        tooltip: '取消备份',
                        onPressed: _busy == null ? () => _cancelJob(job) : null,
                        icon: const Icon(Icons.cancel_outlined),
                      )
                    : null,
              );
            },
          ),
        ),
        _PageControl(
          page: page.page,
          pages: page.pages,
          onPage: (value) {
            setState(() => _jobPage = value);
            unawaited(_load(refresh: true));
          },
        ),
      ],
    );
  }

  Widget _restoreTab() {
    if (_capabilities?.preflightEnabled != true) {
      return const Center(child: Text('此面板尚不支持原生归档预检查'));
    }
    final preflight = _preflight;
    final busy = _busy == 'preflight' || _busy == 'preflight-query';
    if (preflight == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (busy) _preflightProgress(),
          if (_preflightError != null) ...[
            Text(_preflightError!),
            const SizedBox(height: 8),
            if (_preflightQueryAvailable)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy == null ? _queryPreflight : null,
                  icon: const Icon(Icons.sync),
                  label: const Text('查询原预检查'),
                ),
              ),
          ],
          if (!busy)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy == null ? _selectRestoreArchive : null,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('选择备份文件'),
              ),
            ),
          _restoreMaintenanceWidget(),
          if (_restore != null) ...[
            const SizedBox(height: 16),
            _restoreResultWidget(_restore!),
          ],
          const SizedBox(height: 16),
          _restoreHistoryWidget(),
        ],
      );
    }
    if (preflight.status != 'ready') {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            preflight.filename,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            _preflightError ??
                switch (preflight.status) {
                  'uploading' => '面板正在接收归档…',
                  'checking' => '面板正在校验归档…',
                  'unknown' => '无法确认面板是否完成预检查；查询原请求不会重复上传。',
                  _ => _preflightErrorLabel(preflight.errorCode),
                },
          ),
          const SizedBox(height: 8),
          if (busy) _preflightProgress(),
          if (preflight.cancelAllowed)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _cancelPreflight,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('取消预检查'),
              ),
            ),
          _restoreMaintenanceWidget(),
          if (_restore != null) ...[
            const SizedBox(height: 16),
            _restoreResultWidget(_restore!),
          ],
          if (preflight.status == 'unknown' ||
              (preflight.status == 'checking' && !preflight.active))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy == null ? _queryPreflight : null,
                icon: const Icon(Icons.sync),
                label: const Text('查询原预检查'),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy == null ? _selectRestoreArchive : null,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('选择其他备份'),
            ),
          ),
          const SizedBox(height: 16),
          _restoreHistoryWidget(),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          preflight.filename,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          '${_formatBytes(preflight.archiveSizeBytes)} · ${preflight.format.toUpperCase()} · ${preflight.entryCount} 项 · 展开 ${_formatBytes(preflight.expandedBytes)}',
        ),
        const SizedBox(height: 8),
        SelectableText('SHA-256  ${preflight.archiveSha256}'),
        const SizedBox(height: 16),
        Text('恢复范围', style: Theme.of(context).textTheme.titleSmall),
        for (final item in preflight.items)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _restoreItems.contains(item),
            title: Text(item == 'data' ? '配置数据' : '脚本'),
            onChanged: busy
                ? null
                : (checked) => setState(() {
                    if (checked == true) {
                      _restoreItems.add(item);
                    } else {
                      _restoreItems.remove(item);
                    }
                  }),
          ),
        if (preflight.dependencyFiles.isNotEmpty)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _restoreDependencies,
            title: const Text('恢复依赖'),
            subtitle: Text(preflight.dependencyFiles.join(' · ')),
            onChanged: busy
                ? null
                : (checked) =>
                      setState(() => _restoreDependencies = checked == true),
          ),
        for (final warning in preflight.warnings)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(_preflightWarningLabel(warning)),
          ),
        const SizedBox(height: 8),
        if (_capabilities?.restoreEnabled == true) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                _busy == null &&
                    _restoreItems.isNotEmpty &&
                    _restoreRequestId == null
                ? _submitRestore
                : null,
            icon: const Icon(Icons.restore),
            label: const Text('检查并提交恢复'),
          ),
          if (_restore != null) ...[
            const SizedBox(height: 16),
            _restoreResultWidget(_restore!),
          ],
        ] else
          const Text('预检查完成，但此面板尚未开放原生恢复提交。'),
        if (busy) ...[const SizedBox(height: 16), _preflightProgress()],
        if (_restoreRequestId != null && _restore == null)
          TextButton.icon(
            onPressed: _busy == null ? _queryRestore : null,
            icon: const Icon(Icons.sync),
            label: const Text('查询原恢复请求'),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy == null ? _selectRestoreArchive : null,
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('选择其他备份'),
          ),
        ),
        const SizedBox(height: 16),
        _restoreMaintenanceWidget(),
        const SizedBox(height: 16),
        _restoreHistoryWidget(),
      ],
    );
  }

  Widget _restoreResultWidget(PanelBackupRestore restore) {
    final status = switch (restore.state) {
      'accepted' => '已受理',
      'extracting' => '校验归档',
      'staging' => '准备替换目录',
      'committing' => '正在提交目录',
      'restored' => '目录已恢复',
      'failed' => restore.liveStateUnchanged ? '恢复失败，原目录未变' : '恢复状态未知',
      _ => '恢复结果未知',
    };
    final children = <Widget>[
      Text(status, style: Theme.of(context).textTheme.titleSmall),
      Text(restore.items.map(_scopeLabel).join(' + ')),
      if (restore.error.isNotEmpty) Text(restore.error),
      if (restore.directoryRecoveryRequired) ...[
        const Text('面板检测到中断的目录恢复记录，请先恢复现场。'),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy == null
                ? () => _recoverRestoreDirectories(restore)
                : null,
            icon: const Icon(Icons.restore),
            label: const Text('恢复目录现场'),
          ),
        ),
      ],
      if (restore.restoreOutcomeUnknown &&
          !restore.directoryRecoveryRequired) ...[
        const Text('请检查实际目录结果；不得自动重新导入。'),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton(
              onPressed: _busy == null
                  ? () => _resolveUnknownRestore(
                      restore,
                      directoriesRestored: true,
                    )
                  : null,
              child: const Text('确认归档已应用'),
            ),
            OutlinedButton(
              onPressed: _busy == null
                  ? () => _resolveUnknownRestore(
                      restore,
                      directoriesRestored: false,
                    )
                  : null,
              child: const Text('确认原目录未变'),
            ),
          ],
        ),
      ],
      if (restore.active) ...[
        const SizedBox(height: 8),
        const LinearProgressIndicator(),
        const Text('恢复不可取消，请保持此请求并等待面板确认。'),
      ],
      if (restore.committed && restore.scheduler.required) ...[
        const SizedBox(height: 8),
        Text('调度器：${_followupLabel(restore.scheduler.state)}'),
        if (restore.scheduler.error.isNotEmpty) Text(restore.scheduler.error),
        if (restore.scheduler.state != 'succeeded' &&
            restore.scheduler.state != 'running')
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed:
                  _busy == null &&
                      !restore.directoryRecoveryRequired &&
                      !restore.dependencies.cleanupRequired
                  ? () => _runFollowup(dependencies: false)
                  : null,
              icon: const Icon(Icons.refresh),
              label: const Text('仅重新加载调度器'),
            ),
          ),
      ],
      if (restore.committed && restore.restoreDependencies) ...[
        const SizedBox(height: 8),
        Text('依赖安装：${_followupLabel(restore.dependencies.state)}'),
        if (_busy == 'dependency-cleanup' &&
            restore.dependencies.cleanupRequired) ...[
          const LinearProgressIndicator(),
          const Text('正在清理原依赖作业…'),
        ],
        if (restore.dependencies.error.isNotEmpty)
          Text(restore.dependencies.error),
        if (restore.dependencies.output.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(
            restore.dependencies.output,
            maxLines: 10,
            scrollPhysics: const AlwaysScrollableScrollPhysics(),
          ),
        ],
        if (restore.dependencies.state != 'succeeded' &&
            restore.dependencies.state != 'running' &&
            !restore.dependencies.cleanupRequired)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy == null && !restore.directoryRecoveryRequired
                  ? () => _runFollowup(dependencies: true)
                  : null,
              icon: const Icon(Icons.build_outlined),
              label: const Text('单独安装恢复依赖'),
            ),
          ),
        if (restore.dependencies.cleanupRequired)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy == null ? _cleanupRestoreDependencies : null,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清理原依赖作业'),
            ),
          ),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _busy == null ? _queryRestore : null,
          icon: const Icon(Icons.sync),
          label: const Text('查询原恢复请求'),
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _restoreHistoryWidget() {
    final history = _restoreHistory;
    if (history == null &&
        !_restoreHistoryLoading &&
        _restoreHistoryError == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('恢复历史', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            IconButton(
              tooltip: '刷新恢复历史',
              onPressed: _busy == null && !_restoreHistoryLoading
                  ? () => _loadRestoreHistory()
                  : null,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_restoreHistoryLoading) const LinearProgressIndicator(),
        if (_restoreHistoryError != null) Text(_restoreHistoryError!),
        if (history != null && history.items.isEmpty)
          const Text('暂无恢复记录')
        else if (history != null)
          for (final restore in history.items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                restore.restoreOutcomeUnknown
                    ? Icons.help_outline
                    : restore.committed
                    ? Icons.check_circle_outline
                    : Icons.history,
              ),
              title: Text(
                '${_restoreStatusLabel(restore.state)} · ${restore.filename}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${restore.items.map(_scopeLabel).join(' + ')} · ${restore.requestId}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '查询此恢复请求',
                onPressed: _busy == null
                    ? () => _queryHistoryItem(restore)
                    : null,
                icon: const Icon(Icons.sync),
              ),
            ),
        if (history != null && history.total > 25)
          _PageControl(
            page: history.offset ~/ 25 + 1,
            pages: (history.total / 25).ceil(),
            enabled: _busy == null && !_restoreHistoryLoading,
            onPage: (page) =>
                unawaited(_loadRestoreHistory(offset: (page - 1) * 25)),
          ),
      ],
    );
  }

  Widget _restoreMaintenanceWidget() {
    final maintenance = _restoreMaintenance;
    if (maintenance == null || maintenance.eventId.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(maintenance.notice),
        if (maintenance.required)
          const Text('维护未完成；恢复记录与目录均保留，请先修复并重新核对。')
        else if (!maintenance.acknowledged)
          TextButton.icon(
            onPressed: _busy == null
                ? () => _acknowledgeRestoreMaintenance(maintenance)
                : null,
            icon: const Icon(Icons.check),
            label: const Text('确认维护已核对'),
          ),
      ],
    );
  }

  Future<void> _acknowledgeRestoreMaintenance(
    PanelBackupMaintenance maintenance,
  ) async {
    final confirmed = await _confirm<bool>(
      builder: (context) => AlertDialog(
        title: const Text('确认维护记录'),
        content: Text(maintenance.notice),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认已核对'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _busy != null) return;
    setState(() => _busy = 'maintenance-ack');
    try {
      final result = await widget.manager.acknowledgeRestoreMaintenance(
        maintenance.eventId,
      );
      if (mounted) setState(() => _restoreMaintenance = result);
    } catch (error) {
      if (await _handleUnauthorized(error)) return;
      if (mounted) _notice('维护确认未能保存；请刷新状态后重试');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  String _followupLabel(String state) => switch (state) {
    'not_required' || 'not_requested' => '无需处理',
    'pending' => '待处理',
    'running' => '处理中',
    'succeeded' => '已完成',
    'failed' => '失败',
    _ => '结果未知',
  };

  String _restoreStatusLabel(String status) => switch (status) {
    'accepted' => '已受理',
    'extracting' => '校验归档',
    'staging' => '准备目录',
    'committing' => '提交中',
    'restored' => '已恢复',
    'failed' => '失败',
    _ => '未知',
  };

  Widget _preflightProgress() {
    final fraction = _uploadTotalBytes > 0
        ? (_uploadSentBytes / _uploadTotalBytes).clamp(0.0, 1.0)
        : null;
    final uploaded = fraction != null && fraction >= 1;
    final amount = _stagingArchive
        ? '读取本机文件'
        : uploaded
        ? '上传完成，面板正在校验归档'
        : _uploadTotalBytes > 0
        ? '${_formatBytes(_uploadSentBytes)} / ${_formatBytes(_uploadTotalBytes)} · ${(fraction! * 100).round()}%'
        : '等待面板接收';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: _stagingArchive || uploaded ? null : fraction,
        ),
        const SizedBox(height: 6),
        Text(amount, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  String _preflightWarningLabel(String warning) => switch (warning) {
    'data_restore_may_change_panel_access' => '恢复配置数据可能改变面板登录、安全验证或服务配置。',
    'contains_native_session_store' => '归档包含原生会话数据库；本次预检查不会修改当前会话。',
    _ => '备份包含需要注意的内容。',
  };

  String _scopeLabel(String item) => switch (item) {
    'data' => '配置数据',
    'scripts' => '脚本',
    _ => item,
  };

  String _statusLabel(String status) => switch (status) {
    'preparing' => '准备中',
    'running' => '备份中',
    'cancelling' => '正在取消',
    'succeeded' => '已完成',
    'cancelled' => '已取消',
    'failed' => '失败',
    _ => '状态未知',
  };
}

class _BackupScopeDialog extends StatefulWidget {
  const _BackupScopeDialog({required this.available});

  final List<String> available;

  @override
  State<_BackupScopeDialog> createState() => _BackupScopeDialogState();
}

class _BackupScopeDialogState extends State<_BackupScopeDialog> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.available.toSet();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('创建备份'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in widget.available)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _selected.contains(item),
            title: Text(item == 'data' ? '配置数据' : '脚本'),
            onChanged: (value) => setState(() {
              if (value == true) {
                _selected.add(item);
              } else {
                _selected.remove(item);
              }
            }),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.pop(context, _selected.toList()),
        child: const Text('开始备份'),
      ),
    ],
  );
}

class _PageControl extends StatelessWidget {
  const _PageControl({
    required this.page,
    required this.pages,
    required this.onPage,
    this.enabled = true,
  });

  final int page;
  final int pages;
  final ValueChanged<int> onPage;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: enabled && page > 1 ? () => onPage(page - 1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Text('$page / $pages'),
        IconButton(
          tooltip: '下一页',
          onPressed: enabled && page < pages ? () => onPage(page + 1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
}

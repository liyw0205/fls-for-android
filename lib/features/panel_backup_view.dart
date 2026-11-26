import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/panel_backup.dart';
import '../services/local_file_bridge.dart';
import '../services/panel_api_client.dart';
import '../services/panel_backup_manager.dart';

class PanelBackupView extends StatefulWidget {
  const PanelBackupView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
  });

  final PanelBackupManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<PanelBackupView> createState() => _PanelBackupViewState();
}

class _PanelBackupViewState extends State<PanelBackupView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  PanelBackupCapabilities? _capabilities;
  PanelBackupFilesPage? _files;
  PanelBackupJobsPage? _jobs;
  PanelBackupPreflight? _preflight;
  String? _preflightRequestId;
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

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
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
      if (!mounted) return;
      setState(() {
        _capabilities = values[0] as PanelBackupCapabilities;
        _files = values[1] as PanelBackupFilesPage;
        _jobs = values[2] as PanelBackupJobsPage;
        _loading = false;
      });
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
    if (error is PanelApiException && error.statusCode == 401) {
      await widget.onUnauthorized(error);
      return true;
    }
    return false;
  }

  String _messageFor(Object error) =>
      error is PanelApiException ? error.message : error.toString();

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createBackup() async {
    final capabilities = _capabilities;
    if (capabilities == null || _busy != null) return;
    final selected = await showDialog<List<String>>(
      context: context,
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
    final confirmed = await showDialog<bool>(
      context: context,
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
    final picked = await LocalFileBridge.pickScriptImport();
    if (!mounted || picked == null) return;
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
      if (!mounted) return;
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
                    children: [_filesTab(), _jobsTab(), _restoreTab()],
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
        const Text('预检查完成。恢复提交接口尚未开放，当前不会写入面板数据。'),
        if (busy) ...[const SizedBox(height: 16), _preflightProgress()],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy == null ? _selectRestoreArchive : null,
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('选择其他备份'),
          ),
        ),
      ],
    );
  }

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

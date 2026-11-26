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
    _tabs = TabController(length: 2, vsync: this);
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
          tabs: [
            Tab(text: '文件${_files == null ? '' : ' · ${_files!.total}'}'),
            Tab(text: '作业${_jobs == null ? '' : ' · ${_jobs!.total}'}'),
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
                    children: [_filesTab(), _jobsTab()],
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

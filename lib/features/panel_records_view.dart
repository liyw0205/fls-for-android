import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/panel_records.dart';
import '../services/local_file_bridge.dart';
import '../services/panel_api_client.dart';
import '../services/panel_log_cleanup_manager.dart';
import '../services/panel_records_manager.dart';
import 'panel_log_cleanup_view.dart';

typedef PanelFileSaver =
    Future<bool> Function({required List<int> bytes, required String filename});

class PanelRecordsView extends StatefulWidget {
  const PanelRecordsView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.saveFile,
    this.cleanupManager,
  });

  final PanelRecordsManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final PanelFileSaver? saveFile;
  final PanelLogCleanupManager? cleanupManager;

  @override
  State<PanelRecordsView> createState() => PanelRecordsViewState();
}

class PanelRecordsViewState extends State<PanelRecordsView>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  String _view = 'history';
  String _query = '';
  String _status = '';
  PanelHistoryPage? _history;
  PanelLogFilePage? _logs;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  int _request = 0;
  bool _selecting = false;
  bool _groupsMode = false;
  bool _background = false;
  bool _checkingCleanup = false;
  bool _authorized = true;
  int _maxFiles = 200;
  int _maxGroups = 20;
  final Map<String, PanelLogFile> _selectedFiles = {};
  final Set<String> _selectedGroups = {};
  BuildContext? _cleanupHistoryContext;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant PanelRecordsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager ||
        oldWidget.cleanupManager != widget.cleanupManager) {
      _request++;
      _closeCleanupHistory();
      _history = null;
      _logs = null;
      _selecting = false;
      _checkingCleanup = false;
      _authorized = true;
      _selectedFiles.clear();
      _selectedGroups.clear();
      unawaited(_load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() => _background = state != AppLifecycleState.resumed);
    if (_background) _closeCleanupHistory();
  }

  void _closeCleanupHistory() {
    final sheet = _cleanupHistoryContext;
    _cleanupHistoryContext = null;
    if (sheet == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (sheet.mounted && ModalRoute.of(sheet)?.isCurrent == true) {
        Navigator.of(sheet).pop();
      }
    });
  }

  @override
  void dispose() {
    _request++;
    _closeCleanupHistory();
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> refresh() =>
      _load(page: _view == 'history' ? _history?.page ?? 1 : _logs?.page ?? 1);

  Future<void> _load({int page = 1}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_view == 'history') {
        final data = await widget.manager.fetchHistory(
          query: _query,
          status: _status,
          page: page,
        );
        if (!mounted || request != _request) return;
        setState(() {
          _history = data;
          _loading = false;
        });
      } else {
        final data = await widget.manager.fetchLogFiles(
          query: _query,
          page: page,
        );
        if (!mounted || request != _request) return;
        setState(() {
          _logs = data;
          _loading = false;
        });
      }
    } catch (error) {
      if (!mounted || request != _request) return;
      if (error is PanelApiException && error.statusCode == 401) {
        setState(() => _authorized = false);
        await widget.onUnauthorized(error);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _selectView(String view) {
    if (_view == view) return;
    setState(() {
      _view = view;
      _error = null;
      _selecting = false;
      _selectedFiles.clear();
      _selectedGroups.clear();
    });
    unawaited(_load());
  }

  void _submitSearch(String value) {
    setState(() => _query = value.trim());
    unawaited(_load());
  }

  Future<void> _exportHistory() async {
    if (_saving || _background || !_authorized) return;
    final manager = widget.manager;
    setState(() => _saving = true);
    try {
      final bytes = await widget.manager.exportHistory(
        query: _query,
        status: _status,
      );
      if (!mounted || _background || !identical(widget.manager, manager)) {
        return;
      }
      final saved = await (widget.saveFile ?? _savePanelFile)(
        bytes: bytes,
        filename: 'fls-history-export.csv',
      );
      if (!mounted || !identical(widget.manager, manager)) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '历史记录已导出' : '已取消导出')));
    } catch (error) {
      if (!mounted || !identical(widget.manager, manager)) return;
      if (error is PanelApiException && error.statusCode == 401) {
        setState(() => _authorized = false);
        await widget.onUnauthorized(error);
      } else {
        _showError(error);
      }
    } finally {
      if (mounted && identical(widget.manager, manager)) {
        setState(() => _saving = false);
      }
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> _openLog(PanelLogFile file) async {
    final manager = widget.manager;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelLogFileView(
          manager: widget.manager,
          file: file,
          onUnauthorized: widget.onUnauthorized,
          saveFile: widget.saveFile,
          cleanupManager: widget.cleanupManager,
        ),
      ),
    );
    if (mounted && identical(widget.manager, manager)) await refresh();
  }

  Future<void> _startSelection() async {
    final manager = widget.cleanupManager;
    if (manager == null || _checkingCleanup || _background) return;
    if (_selecting) {
      setState(() {
        _selecting = false;
        _selectedFiles.clear();
        _selectedGroups.clear();
      });
      return;
    }
    setState(() => _checkingCleanup = true);
    try {
      final capabilities = await manager.capabilities();
      if (!mounted ||
          _background ||
          !identical(widget.cleanupManager, manager)) {
        return;
      }
      if (!capabilities.supported) {
        _showError('当前面板不支持日志清理');
        return;
      }
      setState(() {
        _selecting = true;
        _maxFiles = capabilities.maxFiles;
        _maxGroups = capabilities.maxGroups;
      });
    } catch (error) {
      if (!mounted || !identical(widget.cleanupManager, manager)) return;
      if (error is PanelApiException && error.statusCode == 401) {
        setState(() => _authorized = false);
        await widget.onUnauthorized(error);
      } else {
        _showError(error);
      }
    } finally {
      if (mounted && identical(widget.cleanupManager, manager)) {
        setState(() => _checkingCleanup = false);
      }
    }
  }

  void _toggleLog(PanelLogFile file) {
    if (_groupsMode) {
      if (_selectedGroups.contains(file.group)) {
        setState(() => _selectedGroups.remove(file.group));
      } else if (_selectedGroups.length < _maxGroups && file.group.isNotEmpty) {
        setState(() => _selectedGroups.add(file.group));
      } else {
        _showError('每次最多选择 $_maxGroups 个分组');
      }
    } else if (_selectedFiles.containsKey(file.filename)) {
      setState(() => _selectedFiles.remove(file.filename));
    } else if (file.version != null && _selectedFiles.length < _maxFiles) {
      setState(() => _selectedFiles[file.filename] = file);
    } else {
      _showError(
        file.version == null ? '文件缺少版本，请刷新列表' : '每次最多选择 $_maxFiles 个文件',
      );
    }
  }

  Future<void> _openCleanup({PanelLogCleanupOperation? operation}) async {
    final manager = widget.cleanupManager;
    if (manager == null || _background) return;
    final files = List<PanelLogFile>.unmodifiable(_selectedFiles.values);
    final groups = List<String>.unmodifiable(_selectedGroups);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelLogCleanupView(
          manager: manager,
          files: files,
          groups: groups,
          operation: operation,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (!mounted || !identical(widget.cleanupManager, manager)) return;
    setState(() {
      _selecting = false;
      _selectedFiles.clear();
      _selectedGroups.clear();
    });
    await refresh();
  }

  Future<void> _openCleanupHistory() async {
    final manager = widget.cleanupManager;
    if (manager == null || _background) return;
    final operation = await showModalBottomSheet<PanelLogCleanupOperation>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        _cleanupHistoryContext = context;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final operations = manager.recovery.operations;
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.65,
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('日志清理记录'),
                      subtitle: Text(manager.panelLabel),
                      trailing: IconButton(
                        tooltip: '清除已完成记录',
                        onPressed:
                            operations.any(
                              (operation) =>
                                  operation.result?.status == 'completed',
                            )
                            ? () =>
                                  setSheetState(manager.recovery.clearCompleted)
                            : null,
                        icon: const Icon(Icons.playlist_remove),
                      ),
                    ),
                    Expanded(
                      child: operations.isEmpty
                          ? const Center(child: Text('暂无清理记录'))
                          : ListView.builder(
                              itemCount: operations.length,
                              itemBuilder: (context, index) {
                                final operation = operations[index];
                                return ListTile(
                                  title: Text(
                                    operation.preview.items.first.filename,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${operation.preview.items.length} 个文件 · '
                                    '${operation.result?.status == 'completed' ? '处理完成' : '待查询原请求'}',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () =>
                                      Navigator.pop(context, operation),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    _cleanupHistoryContext = null;
    if (operation != null &&
        mounted &&
        !_background &&
        identical(widget.cleanupManager, manager)) {
      await _openCleanup(operation: operation);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_authorized) return const Center(child: Text('面板会话不可用，请重新连接'));
    if (_background) return const Center(child: Text('记录信息已隐藏'));
    final isHistory = _view == 'history';
    final history = _history;
    final logs = _logs;
    final total = isHistory ? history?.total : logs?.total;
    final pageNumber = isHistory ? history?.page : logs?.page;
    final pages = isHistory ? history?.pages : logs?.pages;
    final items = isHistory
        ? history?.items.length ?? 0
        : logs?.items.length ?? 0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: 'history',
                          icon: Icon(Icons.history),
                          label: Text('运行历史'),
                        ),
                        ButtonSegment(
                          value: 'logs',
                          icon: Icon(Icons.article_outlined),
                          label: Text('日志文件'),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: (selection) =>
                          _selectView(selection.first),
                    ),
                  ),
                  if (isHistory)
                    IconButton(
                      tooltip: '导出筛选结果 CSV',
                      onPressed: _saving ? null : _exportHistory,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: _submitSearch,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: isHistory ? '搜索任务名、命令或说明' : '搜索日志文件或任务名',
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            _searchController.clear();
                            _submitSearch('');
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (isHistory) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '运行状态',
                    prefixIcon: Icon(Icons.filter_list),
                  ),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部状态')),
                    DropdownMenuItem(value: 'success', child: Text('成功')),
                    DropdownMenuItem(value: 'failed', child: Text('失败')),
                    DropdownMenuItem(value: 'timeout', child: Text('超时')),
                    DropdownMenuItem(
                      value: 'start_failed',
                      child: Text('启动失败'),
                    ),
                    DropdownMenuItem(value: 'stopped', child: Text('手动停止')),
                    DropdownMenuItem(value: 'running', child: Text('运行中')),
                    DropdownMenuItem(value: 'starting', child: Text('启动中')),
                    DropdownMenuItem(value: 'delaying', child: Text('延迟中')),
                    DropdownMenuItem(value: 'unknown', child: Text('结果未知')),
                  ],
                  onChanged: (value) {
                    setState(() => _status = value ?? '');
                    unawaited(_load());
                  },
                ),
              ],
              if (!isHistory && widget.cleanupManager != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      tooltip: _selecting ? '取消选择日志' : '选择清理日志',
                      onPressed: _checkingCleanup ? null : _startSelection,
                      icon: Icon(_selecting ? Icons.close : Icons.checklist),
                    ),
                    IconButton(
                      tooltip: '日志清理记录',
                      onPressed: _openCleanupHistory,
                      icon: const Icon(Icons.manage_history),
                    ),
                    if (_selecting) ...[
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: false, label: Text('文件')),
                          ButtonSegment(value: true, label: Text('分组')),
                        ],
                        selected: {_groupsMode},
                        onSelectionChanged: (value) => setState(() {
                          _groupsMode = value.first;
                          _selectedFiles.clear();
                          _selectedGroups.clear();
                        }),
                      ),
                      Text(
                        '已选 ${_groupsMode ? _selectedGroups.length : _selectedFiles.length}',
                      ),
                      IconButton(
                        tooltip: '预检查清理日志',
                        onPressed:
                            _selectedFiles.isEmpty && _selectedGroups.isEmpty
                            ? null
                            : () => _openCleanup(),
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: refresh, child: const Text('重试'))],
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (total != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('$total 条记录'),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: refresh,
            child: !isHistory ? _logList(logs) : _historyList(history, items),
          ),
        ),
        if (pageNumber != null && pages != null && pages > 1)
          _RecordsPageControls(
            page: pageNumber,
            pages: pages,
            onPage: (next) => _load(page: next),
          ),
      ],
    );
  }

  Widget _historyList(PanelHistoryPage? data, int itemCount) {
    final items = data?.items ?? const <PanelHistoryItem>[];
    if (items.isEmpty) {
      return _emptyList(
        data == null || data.total == 0 ? '暂无运行历史' : '没有匹配的运行记录',
        Icons.history,
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: itemCount,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = items[index];
        final color = _historyColor(context, item.status);
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_historyIcon(item.status), color: color),
          title: Text(
            item.taskName.isEmpty ? item.taskId : item.taskName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              if (item.startAt.isNotEmpty) item.startAt,
              _historyStatus(item.status),
              '${item.durationSeconds} 秒',
              if (item.returnCode != null) '退出码 ${item.returnCode}',
              if (item.message.isNotEmpty) item.message,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showHistoryDetail(item),
        );
      },
    );
  }

  void _showHistoryDetail(PanelHistoryItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.taskName.isEmpty ? item.taskId : item.taskName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                _detailRow('状态', _historyStatus(item.status)),
                _detailRow('任务 ID', item.taskId),
                _detailRow('命令', item.command),
                _detailRow('开始时间', item.startAt),
                _detailRow('结束时间', item.endAt),
                _detailRow('耗时', '${item.durationSeconds} 秒'),
                _detailRow('退出码', item.returnCode?.toString() ?? '-'),
                _detailRow('来源', item.source),
                _detailRow('重试', '${item.retryAttempt} / ${item.maxRetries}'),
                _detailRow('说明', item.message),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _logList(PanelLogFilePage? data) {
    final items = data?.items ?? const <PanelLogFile>[];
    if (items.isEmpty) {
      return _emptyList(
        data == null || data.total == 0 ? '暂无日志文件' : '没有匹配的日志文件',
        Icons.article_outlined,
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final file = items[index];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _selecting
              ? Checkbox(
                  value: _groupsMode
                      ? _selectedGroups.contains(file.group)
                      : _selectedFiles.containsKey(file.filename),
                  onChanged: !_groupsMode && file.version == null
                      ? null
                      : (_) => _toggleLog(file),
                )
              : const Icon(Icons.description_outlined),
          title: Text(
            file.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${file.group} · ${_formatBytes(file.sizeBytes)} · ${file.modifiedAt}${file.busy == true ? ' · 正在使用' : ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _selecting ? _toggleLog(file) : _openLog(file),
        );
      },
    );
  }

  Widget _emptyList(String message, IconData icon) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    children: [
      const SizedBox(height: 72),
      Icon(icon, size: 36, color: Theme.of(context).colorScheme.outline),
      const SizedBox(height: 12),
      Center(child: Text(message)),
    ],
  );

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: SelectableText(value.isEmpty ? '-' : value)),
      ],
    ),
  );
}

class PanelLogFileView extends StatefulWidget {
  const PanelLogFileView({
    super.key,
    required this.manager,
    required this.file,
    required this.onUnauthorized,
    this.saveFile,
    this.cleanupManager,
  });

  final PanelRecordsManager manager;
  final PanelLogFile file;
  final Future<void> Function(Object error) onUnauthorized;
  final PanelFileSaver? saveFile;
  final PanelLogCleanupManager? cleanupManager;

  @override
  State<PanelLogFileView> createState() => _PanelLogFileViewState();
}

class _PanelLogFileViewState extends State<PanelLogFileView>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  PanelLogFileContent? _content;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _background = false;
  bool _authorized = true;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant PanelLogFileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager || oldWidget.file != widget.file) {
      _request++;
      _content = null;
      _authorized = true;
      _searchController.clear();
      unawaited(_load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => _background = state != AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final content = await widget.manager.fetchLogFile(widget.file.filename);
      if (!mounted || request != _request) return;
      setState(() {
        _content = content;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      if (error is PanelApiException && error.statusCode == 401) {
        setState(() {
          _authorized = false;
          _content = null;
        });
        await widget.onUnauthorized(error);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _download() async {
    if (_saving || _background) return;
    final manager = widget.manager;
    setState(() => _saving = true);
    try {
      final bytes = await widget.manager.downloadLogFile(widget.file.filename);
      if (!mounted || _background || !identical(widget.manager, manager)) {
        return;
      }
      final saved = await (widget.saveFile ?? _savePanelFile)(
        bytes: bytes,
        filename: widget.file.filename,
      );
      if (!mounted || !identical(widget.manager, manager)) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '日志文件已保存' : '已取消保存')));
    } catch (error) {
      if (!mounted || !identical(widget.manager, manager)) return;
      if (error is PanelApiException && error.statusCode == 401) {
        setState(() {
          _authorized = false;
          _content = null;
        });
        await widget.onUnauthorized(error);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && identical(widget.manager, manager)) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _cleanupFile() async {
    final manager = widget.cleanupManager;
    if (manager == null || _background) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelLogCleanupView(
          manager: manager,
          files: [widget.file],
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (mounted && identical(widget.cleanupManager, manager) && !_background) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _content;
    final query = _searchController.text.trim().toLowerCase();
    final allLines = content?.text.split('\n') ?? const <String>[];
    final lines = [
      for (var index = 0; index < allLines.length; index++)
        if (query.isEmpty || allLines[index].toLowerCase().contains(query))
          (index + 1, allLines[index]),
    ];
    return Scaffold(
      appBar: AppBar(
        title: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            _background || !_authorized ? '日志' : widget.file.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          if (widget.cleanupManager != null && widget.file.version != null)
            IconButton(
              tooltip: '删除日志文件',
              onPressed: _background || !_authorized || _loading
                  ? null
                  : _cleanupFile,
              icon: const Icon(Icons.delete_outline),
            ),
          IconButton(
            tooltip: '刷新日志',
            onPressed: _loading || _background || !_authorized ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _background || !_authorized
          ? Center(child: Text(!_authorized ? '面板会话不可用，请重新连接' : '日志信息已隐藏'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    children: [
                      TextField(
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: '搜索日志内容',
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除搜索',
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {});
                                  },
                                  icon: const Icon(Icons.close),
                                ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          onPressed: _saving ? null : _download,
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_outlined),
                          label: const Text('保存日志文件'),
                        ),
                      ),
                    ],
                  ),
                ),
                if (content != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        query.isEmpty
                            ? '${content.lines} 行 · 最多读取最近 5000 行'
                            : '${lines.length} 行匹配',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                if (_error != null)
                  MaterialBanner(
                    content: Text(_error!),
                    actions: [
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: content == null
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 100),
                            Center(
                              child: Text(_error == null ? '正在读取日志' : '无法读取日志'),
                            ),
                          ],
                        )
                      : lines.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 80),
                            Center(child: Text('没有匹配的日志内容')),
                          ],
                        )
                      : ListView.builder(
                          itemCount: lines.length,
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          itemBuilder: (context, index) {
                            final row = lines[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: SelectableText.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: '${row.$1.toString().padLeft(4)}  ',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.outline,
                                      ),
                                    ),
                                    TextSpan(
                                      text: row.$2,
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _RecordsPageControls extends StatelessWidget {
  const _RecordsPageControls({
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

Future<bool> _savePanelFile({
  required List<int> bytes,
  required String filename,
}) async {
  final directory = await getTemporaryDirectory();
  final safeName = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final file = File(
    p.join(
      directory.path,
      'fls-export-${DateTime.now().microsecondsSinceEpoch}-$safeName',
    ),
  );
  try {
    await file.writeAsBytes(bytes, flush: true);
    return await LocalFileBridge.saveFile(path: file.path, filename: filename);
  } finally {
    if (await file.exists()) await file.delete();
  }
}

Color _historyColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'success' => scheme.primary,
    'running' || 'starting' => scheme.tertiary,
    'delaying' => scheme.secondary,
    'stopped' => scheme.outline,
    _ => scheme.error,
  };
}

IconData _historyIcon(String status) => switch (status) {
  'success' => Icons.check_circle_outline,
  'running' => Icons.play_circle_outline,
  'starting' => Icons.hourglass_top,
  'stopped' => Icons.stop_circle_outlined,
  _ => Icons.error_outline,
};

String _historyStatus(String status) => switch (status) {
  'success' => '成功',
  'failed' => '失败',
  'timeout' => '超时',
  'start_failed' => '启动失败',
  'stopped' => '手动停止',
  'running' => '运行中',
  'starting' => '启动中',
  'delaying' => '延迟中',
  'unknown' => '结果未知',
  _ => status.isEmpty ? '未知' : status,
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

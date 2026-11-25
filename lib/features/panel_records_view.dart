import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/panel_records.dart';
import '../services/local_file_bridge.dart';
import '../services/panel_api_client.dart';
import '../services/panel_records_manager.dart';

typedef PanelFileSaver =
    Future<bool> Function({required List<int> bytes, required String filename});

class PanelRecordsView extends StatefulWidget {
  const PanelRecordsView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.saveFile,
  });

  final PanelRecordsManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final PanelFileSaver? saveFile;

  @override
  State<PanelRecordsView> createState() => PanelRecordsViewState();
}

class PanelRecordsViewState extends State<PanelRecordsView> {
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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
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
    });
    unawaited(_load());
  }

  void _submitSearch(String value) {
    setState(() => _query = value.trim());
    unawaited(_load());
  }

  Future<void> _exportHistory() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await widget.manager.exportHistory(
        query: _query,
        status: _status,
      );
      if (!mounted) return;
      final saved = await (widget.saveFile ?? _savePanelFile)(
        bytes: bytes,
        filename: 'fls-history-export.csv',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '历史记录已导出' : '已取消导出')));
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
      } else {
        _showError(error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> _openLog(PanelLogFile file) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelLogFileView(
          manager: widget.manager,
          file: file,
          onUnauthorized: widget.onUnauthorized,
          saveFile: widget.saveFile,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          leading: const Icon(Icons.description_outlined),
          title: Text(
            file.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${file.group} · ${_formatBytes(file.sizeBytes)} · ${file.modifiedAt}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openLog(file),
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
  });

  final PanelRecordsManager manager;
  final PanelLogFile file;
  final Future<void> Function(Object error) onUnauthorized;
  final PanelFileSaver? saveFile;

  @override
  State<PanelLogFileView> createState() => _PanelLogFileViewState();
}

class _PanelLogFileViewState extends State<PanelLogFileView> {
  final _searchController = TextEditingController();
  PanelLogFileContent? _content;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final content = await widget.manager.fetchLogFile(widget.file.filename);
      if (!mounted) return;
      setState(() {
        _content = content;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
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
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await widget.manager.downloadLogFile(widget.file.filename);
      if (!mounted) return;
      final saved = await (widget.saveFile ?? _savePanelFile)(
        bytes: bytes,
        filename: widget.file.filename,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '日志文件已保存' : '已取消保存')));
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
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
            widget.file.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新日志',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '下载日志文件',
            onPressed: _saving ? null : _download,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
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
              actions: [TextButton(onPressed: _load, child: const Text('重试'))],
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: content == null
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 100),
                      Center(child: Text(_error == null ? '正在读取日志' : '无法读取日志')),
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
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                              TextSpan(
                                text: row.$2,
                                style: const TextStyle(fontFamily: 'monospace'),
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_script_pull.dart';
import '../services/panel_api_client.dart';
import '../services/panel_script_pull_manager.dart';

class PanelScriptPullView extends StatefulWidget {
  const PanelScriptPullView({
    super.key,
    required this.manager,
    required this.currentPath,
    required this.onUnauthorized,
  });

  final PanelScriptPullManager manager;
  final String currentPath;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<PanelScriptPullView> createState() => _PanelScriptPullViewState();
}

class _PanelScriptPullViewState extends State<PanelScriptPullView> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _scrollController = ScrollController();
  PanelScriptPullOptions? _options;
  List<PanelScriptPullJob> _history = const [];
  PanelScriptPullJob? _selected;
  Timer? _pollTimer;
  String _proxyId = '';
  String _pendingKind = 'file';
  bool _repositoryMode = false;
  String? _error;
  String? _pendingRequestId;
  bool _loading = true;
  bool _submitting = false;
  bool _refreshing = false;
  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitial());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _refreshGeneration++;
    _urlController.dispose();
    _nameController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        widget.manager.fetchOptions(),
        widget.manager.fetchHistory(),
      ]);
      if (!mounted) return;
      final options = results[0] as PanelScriptPullOptions;
      final history = results[1] as PanelScriptPullHistory;
      PanelScriptPullJob? activeJob;
      for (final job in history.items) {
        if (job.isActive) {
          activeJob = job;
          break;
        }
      }
      setState(() {
        _options = options;
        _history = history.items;
        _selected = activeJob;
        _loading = false;
      });
      if (_history.any((job) => job.isActive)) _startPolling();
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  String? _destinationPath() {
    final name = _nameController.text.trim();
    if (name.isEmpty ||
        name != _nameController.text ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      return null;
    }
    return widget.currentPath.isEmpty ? name : '${widget.currentPath}/$name';
  }

  Future<void> _submit() async {
    final url = _urlController.text.trim();
    final path = _destinationPath();
    if (url.isEmpty || path == null) {
      setState(() => _error = '请输入有效 URL 和名称');
      return;
    }
    final requestId =
        _pendingRequestId ?? PanelScriptPullManager.newRequestId();
    if (_pendingRequestId == null) {
      _pendingKind = _repositoryMode ? 'repo' : 'file';
    }
    _pendingRequestId = requestId;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final job = _pendingKind == 'repo'
          ? await widget.manager.submitRepository(
              url: url,
              path: path,
              requestId: requestId,
              proxyId: _proxyId,
            )
          : await widget.manager.submitFile(
              url: url,
              path: path,
              requestId: requestId,
              proxyId: _proxyId,
            );
      if (!mounted) return;
      _pendingRequestId = null;
      setState(() {
        _submitting = false;
        _selected = job;
        _upsertHistory(job);
      });
      _startPolling();
      if (job.isComplete) _showCompleted(job);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      if (error is PanelApiException &&
          error.statusCode != null &&
          error.statusCode! < 500) {
        _pendingRequestId = null;
        _pendingKind = 'file';
      }
      setState(() {
        _submitting = false;
        _error = error.toString();
      });
      unawaited(_refreshHistory(silent: true));
    }
  }

  Future<void> _cancel(PanelScriptPullJob job) async {
    try {
      final updated = await widget.manager.cancel(job.id, kind: job.kind);
      if (!mounted) return;
      setState(() {
        _selected = updated;
        _upsertHistory(updated);
      });
      _startPolling();
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      setState(() => _error = error.toString());
      unawaited(_refreshHistory(silent: true));
    }
  }

  void _select(PanelScriptPullJob job) {
    setState(() {
      _selected = job;
      _error = null;
    });
    if (job.isActive) _startPolling();
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refreshHistory(silent: true)),
    );
    unawaited(_refreshHistory(silent: true));
  }

  Future<void> _refreshHistory({bool silent = false}) async {
    if (_refreshing || !mounted) return;
    _refreshing = true;
    final generation = ++_refreshGeneration;
    try {
      final history = await widget.manager.fetchHistory();
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _history = history.items;
        final selectedId = _selected?.id;
        if (selectedId != null) {
          for (final job in _history) {
            if (job.id == selectedId) {
              _selected = job;
              break;
            }
          }
        }
      });
      if (!_history.any((job) => job.isActive)) {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    } catch (error) {
      if (!mounted || generation != _refreshGeneration) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      if (!silent) setState(() => _error = error.toString());
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshSelected() async {
    final selected = _selected;
    if (selected == null) return;
    try {
      final job = await widget.manager.fetchJob(
        selected.id,
        kind: selected.kind,
      );
      if (!mounted) return;
      setState(() {
        _selected = job;
        _upsertHistory(job);
        _error = null;
      });
      if (job.isActive) _startPolling();
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
      } else {
        setState(() => _error = error.toString());
      }
    }
  }

  void _upsertHistory(PanelScriptPullJob job) {
    _history = [
      job,
      ..._history.where((item) => item.id != job.id),
    ].take(20).toList(growable: false);
  }

  Future<void> _handleUnauthorized(Object error) async {
    await widget.onUnauthorized(error);
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  void _showCompleted(PanelScriptPullJob job) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已拉取 ${job.path}')));
  }

  String _statusLabel(PanelScriptPullJob job) => switch (job.status) {
    'pending' => job.kind == 'repo' ? '等待克隆' : '等待下载',
    'cloning' => '正在克隆',
    'downloading' => job.kind == 'repo' ? '正在克隆' : '正在下载',
    'publishing' => '正在保存',
    'cancelling' => '正在取消',
    'complete' => '已完成',
    'failed' => switch (job.errorCode) {
      'target_exists' => '目标已存在，未覆盖',
      'too_large' => '文件超过 64 MB 限制',
      'path_changed' => '目标目录已变化，未发布',
      'worker_interrupted' => '服务重启中断，结果需核实',
      _ => '拉取失败',
    },
    'cancelled' => '已取消',
    _ => '结果未知，请核对目录',
  };

  String _formatBytes(int value) {
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Widget _progress(PanelScriptPullJob job) {
    final progress = job.progress;
    if (job.kind == 'repo') {
      final count = job.isComplete || progress.current == null
          ? ''
          : progress.objectTotal == null
          ? ' · ${progress.current} 个对象'
          : ' · ${progress.current}/${progress.objectTotal} 个对象';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_statusLabel(job)),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: job.isComplete
                ? 1
                : job.isActive
                ? null
                : 0,
            minHeight: 4,
          ),
          const SizedBox(height: 6),
          Text('${job.isComplete ? '已完成' : progress.label}$count'),
        ],
      );
    }
    final percent = progress.percent;
    final total = progress.totalBytes;
    final label = total != null && percent != null
        ? '${_formatBytes(progress.downloadedBytes)} / ${_formatBytes(total)} · $percent%'
        : '已接收 ${_formatBytes(progress.downloadedBytes)} · 总量未知';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_statusLabel(job)),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: percent == null ? null : percent / 100,
          minHeight: 4,
        ),
        const SizedBox(height: 6),
        Text(label),
      ],
    );
  }

  Widget _jobTile(PanelScriptPullJob job) => ListTile(
    selected: _selected?.id == job.id,
    contentPadding: EdgeInsets.zero,
    title: Text(job.path, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      '${job.kind == 'repo' ? 'Git 仓库' : job.sourceHost} · ${_statusLabel(job)}',
    ),
    onTap: () => _select(job),
    trailing: job.isActive
        ? IconButton(
            tooltip: '取消拉取',
            onPressed: () => _cancel(job),
            icon: const Icon(Icons.stop_circle_outlined),
          )
        : const Icon(Icons.chevron_right),
  );

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final options = _options;
    return Scaffold(
      appBar: AppBar(
        title: const Text('远程拉取'),
        actions: [
          IconButton(
            tooltip: '刷新作业',
            onPressed: _loading ? null : _loadInitial,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  '保存到 ${widget.currentPath.isEmpty ? 'scripts 根目录' : widget.currentPath}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'file', label: Text('单文件')),
                    ButtonSegment(value: 'repo', label: Text('Git 仓库')),
                  ],
                  selected: {_repositoryMode ? 'repo' : 'file'},
                  onSelectionChanged: _pendingRequestId == null && !_submitting
                      ? (selection) => setState(
                          () => _repositoryMode = selection.single == 'repo',
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('panel-script-pull-url'),
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'HTTP/HTTPS URL',
                    hintText: 'https://example.com/script.py 或仓库地址',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('panel-script-pull-name'),
                  controller: _nameController,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: _repositoryMode ? '仓库目录名' : '文件名',
                  ),
                  onSubmitted: (_) => _submit(),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _proxyId,
                  decoration: const InputDecoration(labelText: '代理'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('不使用代理')),
                    ...?options?.proxies.map(
                      (proxy) => DropdownMenuItem(
                        value: proxy.id,
                        child: Text('${proxy.name} · ${proxy.type}'),
                      ),
                    ),
                  ],
                  onChanged: _submitting
                      ? null
                      : (value) => setState(() => _proxyId = value ?? ''),
                ),
                if (options?.proxies.isEmpty ?? true)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('未配置启用的代理，将使用直连。'),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_pendingRequestId == null ? '开始拉取' : '重试并核实原请求'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  MaterialBanner(
                    content: Text(_error!),
                    actions: [
                      TextButton(
                        onPressed: () => _refreshHistory(),
                        child: const Text('核实作业'),
                      ),
                    ],
                  ),
                ],
                if (selected != null) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '当前作业',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: '核实作业状态',
                        onPressed: _refreshSelected,
                        icon: const Icon(Icons.fact_check_outlined),
                      ),
                    ],
                  ),
                  SelectableText(selected.path),
                  const SizedBox(height: 10),
                  _progress(selected),
                  if (selected.isActive)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _cancel(selected),
                        icon: const Icon(Icons.stop),
                        label: const Text('取消'),
                      ),
                    ),
                  if (selected.isComplete)
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('返回并刷新目录'),
                      ),
                    ),
                ],
                const SizedBox(height: 20),
                const Divider(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '最近拉取',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text('${_history.length}'),
                  ],
                ),
                if (_history.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('暂无拉取记录')),
                  )
                else
                  ..._history.map(_jobTile),
              ],
            ),
    );
  }
}

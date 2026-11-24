import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_task_detail.dart';
import '../models/panel_task_draft.dart';
import '../services/panel_api_client.dart';
import '../services/panel_tasks_manager.dart';
import 'panel_task_editor_view.dart';

class PanelTaskDetailView extends StatefulWidget {
  const PanelTaskDetailView({
    super.key,
    required this.manager,
    required this.taskId,
    required this.taskName,
    required this.onUnauthorized,
  });

  final PanelTasksManager manager;
  final String taskId;
  final String taskName;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<PanelTaskDetailView> createState() => _PanelTaskDetailViewState();
}

class _PanelTaskDetailViewState extends State<PanelTaskDetailView> {
  PanelTaskDetail? _detail;
  final Set<String> _revealedEnvKeys = {};
  String? _error;
  String? _log;
  String? _logError;
  bool _loading = true;
  bool _logLoading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.manager.fetchTaskDetail(widget.taskId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      await _loadLog();
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

  Future<void> _loadLog() async {
    if (_logLoading) return;
    setState(() {
      _logLoading = true;
      _logError = null;
    });
    try {
      final log = await widget.manager.fetchTaskLog(widget.taskId, lines: 200);
      if (!mounted) return;
      setState(() {
        _log = log;
        _logLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        return;
      }
      setState(() {
        _logError = error.toString();
        _logLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _detail?.task;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          task?['name']?.toString() ?? widget.taskName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (task != null)
            IconButton(
              tooltip: '编辑任务',
              onPressed: _loading ? null : _editTask,
              icon: const Icon(Icons.edit_outlined),
            ),
          IconButton(
            tooltip: '刷新详情',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Future<void> _editTask() async {
    final task = _detail?.task;
    if (task == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PanelTaskEditorView(
          manager: widget.manager,
          taskId: widget.taskId,
          initial: PanelTaskDraft.fromTask(task),
          onUnauthorized: (error) async {
            await widget.onUnauthorized(error);
            if (mounted) Navigator.of(context).maybePop();
          },
        ),
      ),
    );
    if (saved == true && mounted) await _load();
  }

  Widget _buildBody(BuildContext context) {
    final detail = _detail;
    if (detail == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return _errorState();
    }
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: _load, child: const Text('重试'))],
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _sectionTitle(context, '任务状态'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  detail.runtime['running'] == true
                      ? Icons.play_circle_fill
                      : Icons.task_alt,
                  color: detail.runtime['running'] == true
                      ? Theme.of(context).colorScheme.tertiary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                title: Text(detail.runtime['running'] == true ? '运行中' : '已停止'),
                subtitle: Text(
                  [
                    if (detail.runtime['pid'] != null)
                      'PID ${detail.runtime['pid']}',
                    if (_text(detail.runtime['process_name']).isNotEmpty)
                      _text(detail.runtime['process_name']),
                    detail.task['enabled'] == true ? '已启用' : '已停用',
                  ].join('  ·  '),
                ),
              ),
              const Divider(height: 20),
              _sectionTitle(context, '任务设置'),
              _detailRow('备注', detail.task['remark']),
              _detailRow('Cron', detail.task['cron'], emptyText: '手动任务'),
              _detailRow('配置文件', detail.task['config_path']),
              _detailRow('合集 ID', detail.task['collection_id']),
              _detailRow('代理 ID', detail.task['proxy_id']),
              _detailRow('运行次数', detail.task['run_count']),
              _detailRow('最近更新', detail.task['updated_at']),
              _commandBlock(context, _text(detail.task['command'])),
              _environment(context, detail.task['env']),
              _policyRows(context, detail.task),
              const Divider(height: 24),
              _sectionTitle(context, '最近运行历史'),
              if (detail.history.isEmpty)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('暂无运行记录'),
                )
              else
                ...detail.history.map((row) => _historyTile(context, row)),
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(child: _sectionTitle(context, '任务日志')),
                  IconButton(
                    tooltip: '刷新任务日志',
                    onPressed: _logLoading ? null : _loadLog,
                    icon: _logLoading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
              if (_logError != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _logError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                )
              else
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 320),
                  padding: const EdgeInsets.all(12),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _log ?? (_logLoading ? '正在读取日志' : '暂无日志'),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _errorState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 34),
          const SizedBox(height: 12),
          Text(_error ?? '无法读取任务详情', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _detailRow(String label, Object? value, {String emptyText = '-'}) {
    final text = _text(value);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(label)),
          Expanded(child: SelectableText(text.isEmpty ? emptyText : text)),
        ],
      ),
    );
  }

  Widget _commandBlock(BuildContext context, String command) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('命令', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: SelectableText(
            command.isEmpty ? '-' : command,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    ),
  );

  Widget _environment(BuildContext context, Object? value) {
    final env = value is Map<String, dynamic>
        ? value.map((key, value) => MapEntry(key, value?.toString() ?? ''))
        : const <String, String>{};
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('任务变量（${env.length}）'),
      children: env.entries
          .map((entry) {
            final revealed = _revealedEnvKeys.contains(entry.key);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: SelectableText(entry.key),
              subtitle: SelectableText(revealed ? entry.value : '已隐藏'),
              trailing: IconButton(
                tooltip: revealed ? '隐藏变量值' : '显示变量值',
                onPressed: () => setState(() {
                  if (revealed) {
                    _revealedEnvKeys.remove(entry.key);
                  } else {
                    _revealedEnvKeys.add(entry.key);
                  }
                }),
                icon: Icon(revealed ? Icons.visibility_off : Icons.visibility),
              ),
            );
          })
          .toList(growable: false),
    );
  }

  Widget _policyRows(BuildContext context, Map<String, dynamic> task) {
    final notify = task['notify'];
    final delay = task['random_delay'];
    final retry = task['retry'];
    final notifyMode = notify is Map ? _text(notify['mode']) : '-';
    final notifyIds = notify is Map && notify['ids'] is List
        ? (notify['ids'] as List).join(', ')
        : '';
    final notifyLabel = switch (notifyMode) {
      'none' => '不通知',
      'default' => '跟随默认',
      'custom' => '自定义',
      _ => notifyMode,
    };
    final delayMode = delay is Map ? _text(delay['mode']) : '-';
    final delayLabel = switch (delayMode) {
      'none' => '不延迟',
      'default' => '使用默认',
      'custom' => '自定义',
      _ => delayMode,
    };
    final delayText = delay is Map
        ? '$delayLabel${delayMode == 'custom' ? ' · ${delay['seconds'] ?? 0} 秒' : ''}'
        : '-';
    final retryText = retry is Map
        ? '${retry['attempts'] ?? 0} 次 · 间隔 ${retry['interval_seconds'] ?? 60} 秒'
        : '-';
    return Column(
      children: [
        _detailRow(
          '通知',
          [notifyLabel, notifyIds].where((s) => s.isNotEmpty).join(' · '),
        ),
        _detailRow('随机延迟', delayText),
        _detailRow('失败重试', retryText),
      ],
    );
  }

  Widget _historyTile(BuildContext context, Map<String, dynamic> row) {
    final status = _text(row['status']);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        status == 'success' ? Icons.check_circle_outline : Icons.history,
        color: status == 'failed' || status == 'timeout'
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(_historyStatus(status)),
      subtitle: Text(
        [
          _text(row['start_at']),
          if (row['duration_seconds'] != null) '${row['duration_seconds']} 秒',
          if (row['return_code'] != null) '退出码 ${row['return_code']}',
          if (_text(row['message']).isNotEmpty) _text(row['message']),
        ].where((value) => value.isNotEmpty).join('  ·  '),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String _historyStatus(String status) => switch (status) {
    'success' => '成功',
    'failed' => '失败',
    'timeout' => '超时',
    'stopped' => '手动停止',
    'running' => '运行中',
    'starting' => '启动中',
    'delaying' => '延迟中',
    'start_failed' => '启动失败',
    'unknown' => '结果未知',
    _ => status.isEmpty ? '状态未知' : status,
  };

  String _text(Object? value) => value?.toString().trim() ?? '';
}

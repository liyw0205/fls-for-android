import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/panel_script_file.dart';
import '../services/panel_api_client.dart';
import '../services/panel_script_files_manager.dart';
import '../services/panel_script_import_manager.dart';
import '../services/panel_script_pull_manager.dart';
import '../services/panel_script_debug_manager.dart';
import 'panel_script_debug_view.dart';
import 'panel_script_import_view.dart';
import 'panel_script_pull_view.dart';

class PanelScriptFilesView extends StatefulWidget {
  const PanelScriptFilesView({
    super.key,
    required this.manager,
    this.pullManager,
    this.importManager,
    this.debugManager,
    required this.onUnauthorized,
  });

  final PanelScriptFilesManager manager;
  final PanelScriptPullManager? pullManager;
  final PanelScriptImportManager? importManager;
  final PanelScriptDebugManager? debugManager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<PanelScriptFilesView> createState() => _PanelScriptFilesViewState();
}

class _PanelScriptFilesViewState extends State<PanelScriptFilesView> {
  final _searchController = TextEditingController();
  PanelScriptFilePage? _data;
  String _path = '';
  String _query = '';
  String? _error;
  bool _loading = true;
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

  Future<void> _load({int page = 1}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.manager.fetchTree(
        path: _path,
        query: _query,
        page: page,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error, routesToClose: 1);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openFile(PanelScriptFileItem item) async {
    if (item.isDirectory) {
      setState(() {
        _path = item.path;
        _query = '';
        _searchController.clear();
      });
      await _load();
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _PanelScriptFileEditorView(
          path: item.path,
          manager: widget.manager,
          debugManager: widget.debugManager,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (saved == true && mounted) await _load(page: _data?.page ?? 1);
  }

  Future<void> _openPull() async {
    final manager = widget.pullManager;
    if (manager == null) return;
    final completed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PanelScriptPullView(
          manager: manager,
          currentPath: _path,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (completed == true && mounted) await _load(page: _data?.page ?? 1);
  }

  Future<void> _openImport() async {
    final manager = widget.importManager;
    if (manager == null) return;
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PanelScriptImportView(
          manager: manager,
          currentPath: _path,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (imported == true && mounted) await _load(page: _data?.page ?? 1);
  }

  Future<void> _openDebugHistory() async {
    final manager = widget.debugManager;
    if (manager == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelScriptDebugHistoryView(
          manager: manager,
          onUnauthorized: widget.onUnauthorized,
          routesToClose: 2,
        ),
      ),
    );
  }

  Future<void> _rename(PanelScriptFileItem item) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _ScriptRenameNameDialog(initialName: item.name),
    );
    if (newName == null || newName.isEmpty || !mounted) return;

    try {
      final preview = await widget.manager.previewRename(
        path: item.path,
        newName: newName,
      );
      if (!mounted) return;
      final updates = await showDialog<List<PanelScriptRenameReferenceUpdate>>(
        context: context,
        builder: (_) => _ScriptRenameReviewDialog(preview: preview),
      );
      if (updates == null || !mounted) return;
      final operationId = _newOperationId();
      PanelScriptRenameOperation operation;
      try {
        operation = await widget.manager.renameFile(
          path: item.path,
          newName: newName,
          revision: preview.revision,
          operationId: operationId,
          references: updates,
        );
      } catch (error) {
        if (error is PanelApiException && error.statusCode == 401) {
          await _handleUnauthorized(error, routesToClose: 1);
          return;
        }
        if (error is PanelApiException &&
            error.data?['operation'] is Map<String, dynamic>) {
          operation = PanelScriptRenameOperation.fromJson(
            error.data!['operation'],
          );
        } else if (error is PanelApiException &&
            (error.statusCode == null || error.statusCode! >= 500)) {
          try {
            operation = await widget.manager.fetchRenameOperation(operationId);
          } on PanelApiException catch (statusError) {
            if (statusError.statusCode == 401) {
              await _handleUnauthorized(statusError, routesToClose: 1);
              return;
            }
            if (statusError.statusCode == 404) {
              operation = await widget.manager.renameFile(
                path: item.path,
                newName: newName,
                revision: preview.revision,
                operationId: operationId,
                references: updates,
              );
            } else {
              rethrow;
            }
          }
        } else {
          rethrow;
        }
      }
      if (!mounted) return;
      if (!operation.finished) {
        await _showRenameOperation(operation);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已重命名为 ${operation.destination.split('/').last}'),
          ),
        );
      }
      if (mounted) await _load(page: 1);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error, routesToClose: 1);
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _delete(PanelScriptFileItem item) async {
    try {
      final preview = await widget.manager.previewDelete(item.path);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删除 ${item.name}'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(preview.path),
                  const SizedBox(height: 8),
                  Text('大小：${_formatBytes(preview.sizeBytes)}'),
                  if (preview.references.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('以下任务引用此文件。删除后这些任务可能无法运行。'),
                    for (final reference in preview.references)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(reference.taskName),
                        subtitle: Text(
                          [
                            if (reference.fields.contains('command')) '命令',
                            if (reference.fields.contains('config_path'))
                              '配置路径',
                          ].join('、'),
                        ),
                      ),
                  ] else ...[
                    const SizedBox(height: 12),
                    const Text('此操作会永久删除服务器上的文件。'),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除文件'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      try {
        await widget.manager.deleteFile(
          path: preview.path,
          revision: preview.revision,
          confirmReferences: preview.references.isNotEmpty,
        );
      } catch (error) {
        if (error is PanelApiException && error.statusCode == 401) {
          await _handleUnauthorized(error, routesToClose: 1);
          return;
        }
        if (error is PanelApiException && error.statusCode == 409) {
          await _load(page: 1);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('文件或任务引用已变化，请重新检查后再删除')),
            );
          }
          return;
        }
        if (error is PanelApiException &&
            (error.statusCode == null || error.statusCode! >= 500)) {
          try {
            await widget.manager.previewDelete(preview.path);
          } on PanelApiException catch (statusError) {
            if (statusError.statusCode == 404) {
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('已删除 ${preview.path}')));
                await _load(page: 1);
              }
              return;
            }
            if (statusError.statusCode == 401) {
              await _handleUnauthorized(statusError, routesToClose: 1);
              return;
            }
          }
          if (mounted) {
            await _load(page: 1);
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('删除结果未知，已刷新目录确认状态')));
            }
          }
          return;
        }
        rethrow;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已删除 ${preview.path}')));
      await _load(page: 1);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error, routesToClose: 1);
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _showRenameOperation(PanelScriptRenameOperation initial) async {
    var operation = initial;
    while (mounted) {
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        barrierDismissible: operation.finished,
        builder: (context) => AlertDialog(
          title: const Text('改名状态'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${operation.source}  →  ${operation.destination}'),
                  const SizedBox(height: 8),
                  Text('状态：${_renameStatusLabel(operation.status)}'),
                  Text('原路径：${operation.sourceExists ? "存在" : "不存在"}'),
                  Text('目标路径：${operation.destinationExists ? "存在" : "不存在"}'),
                  for (final task in operation.taskStates)
                    Text(
                      '任务 ${task['task_id']}：${_taskRenameLabel(task['state']!)}',
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'refresh'),
              child: const Text('刷新状态'),
            ),
            if (!operation.finished) ...[
              TextButton(
                onPressed: () => Navigator.pop(context, 'rollback'),
                child: const Text('回滚'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'resume'),
                child: const Text('继续完成'),
              ),
            ] else
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
          ],
        ),
      );
      if (action == null || !mounted) return;
      try {
        if (action == 'refresh') {
          operation = await widget.manager.fetchRenameOperation(operation.id);
        } else {
          operation = await widget.manager.recoverRename(
            operationId: operation.id,
            action: action,
          );
        }
      } catch (error) {
        if (error is PanelApiException && error.statusCode == 401) {
          await _handleUnauthorized(error, routesToClose: 1);
          return;
        }
        try {
          operation = await widget.manager.fetchRenameOperation(operation.id);
        } catch (_) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.toString())));
          return;
        }
      }
    }
  }

  Future<void> _create() async {
    final created = await showDialog<_CreateScriptEntry>(
      context: context,
      builder: (_) => const _CreateScriptEntryDialog(),
    );
    if (created == null || !mounted) return;
    final path = _path.isEmpty ? created.name : '$_path/${created.name}';
    try {
      await widget.manager.createFile(path: path, kind: created.kind);
      if (!mounted) return;
      await _load(page: 1);
      if (created.kind == 'file' && mounted) {
        await _openFile(
          PanelScriptFileItem(
            name: created.name,
            path: path,
            kind: 'file',
            sizeBytes: 0,
            modifiedAt: '',
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error, routesToClose: 1);
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  void _search(String value) {
    setState(() => _query = value.trim());
    unawaited(_load());
  }

  Future<void> _handleUnauthorized(
    Object error, {
    required int routesToClose,
  }) async {
    final navigator = Navigator.of(context);
    await widget.onUnauthorized(error);
    for (var index = 0; index < routesToClose && navigator.canPop(); index++) {
      navigator.pop();
    }
  }

  Future<void> _goTo(String path) async {
    setState(() {
      _path = path;
      _query = '';
      _searchController.clear();
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('面板文件'),
        actions: [
          if (widget.importManager != null)
            IconButton(
              tooltip: '上传与导入',
              onPressed: _openImport,
              icon: const Icon(Icons.file_upload_outlined),
            ),
          if (widget.pullManager != null)
            IconButton(
              tooltip: '从 URL 拉取',
              onPressed: _openPull,
              icon: const Icon(Icons.download_outlined),
            ),
          if (widget.debugManager != null)
            IconButton(
              tooltip: '调试记录',
              onPressed: _openDebugHistory,
              icon: const Icon(Icons.history),
            ),
          IconButton(
            tooltip: '刷新目录',
            onPressed: _loading ? null : () => _load(page: data?.page ?? 1),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新建文件或目录',
        onPressed: _create,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _breadcrumbs(),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '搜索当前目录',
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              _search('');
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [TextButton(onPressed: _load, child: const Text('重试'))],
            ),
          Expanded(
            child: data == null || data.items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 72),
                      Icon(
                        data == null || data.total == 0
                            ? Icons.folder_open_outlined
                            : Icons.search_off,
                        size: 36,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          data == null || data.total == 0 ? '目录为空' : '没有匹配的文件',
                        ),
                      ),
                    ],
                  )
                : RefreshIndicator(
                    onRefresh: () => _load(page: data.page),
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      itemCount: data.items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = data.items[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            item.isDirectory
                                ? Icons.folder_outlined
                                : Icons.description_outlined,
                          ),
                          title: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            item.isDirectory
                                ? '文件夹'
                                : '${_formatBytes(item.sizeBytes ?? 0)} · ${item.modifiedAt}',
                          ),
                          onTap: () => _openFile(item),
                          trailing: PopupMenuButton<String>(
                            tooltip: '文件操作',
                            onSelected: (action) {
                              if (action == 'rename') _rename(item);
                              if (action == 'delete') _delete(item);
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'rename',
                                child: Text('重命名'),
                              ),
                              if (!item.isDirectory)
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除文件'),
                                ),
                            ],
                            icon: const Icon(Icons.more_vert),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          if (data != null && data.pages > 1)
            SafeArea(
              top: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一页',
                    onPressed: data.page > 1
                        ? () => _load(page: data.page - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${data.page} / ${data.pages} · ${data.total} 项'),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: data.page < data.pages
                        ? () => _load(page: data.page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _breadcrumbs() {
    final segments = _path.isEmpty ? const <String>[] : _path.split('/');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _path.isEmpty ? null : () => _goTo(''),
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('scripts'),
          ),
          for (var index = 0; index < segments.length; index++) ...[
            const Icon(Icons.chevron_right, size: 18),
            TextButton(
              onPressed: index == segments.length - 1
                  ? null
                  : () => _goTo(segments.take(index + 1).join('/')),
              child: Text(segments[index]),
            ),
          ],
        ],
      ),
    );
  }
}

String _newOperationId() {
  final random = math.Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

String _renameStatusLabel(String status) => switch (status) {
  'prepared' => '准备中',
  'moved' => '文件已移动',
  'tasks_saved' => '任务引用已更新，等待调度器恢复',
  'succeeded' => '完成',
  'rolled_back' => '已回滚',
  _ => '状态待确认',
};

String _taskRenameLabel(String state) => switch (state) {
  'updated' => '已更新',
  'unchanged' => '尚未更新',
  'missing' => '任务已不存在',
  'conflict' => '与当前任务冲突',
  _ => '未知',
};

class _ScriptRenameNameDialog extends StatefulWidget {
  const _ScriptRenameNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_ScriptRenameNameDialog> createState() =>
      _ScriptRenameNameDialogState();
}

class _ScriptRenameNameDialogState extends State<_ScriptRenameNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重命名'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: '新名称'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('检查引用'),
      ),
    ],
  );
}

class _ScriptRenameReviewDialog extends StatefulWidget {
  const _ScriptRenameReviewDialog({required this.preview});

  final PanelScriptRenamePreview preview;

  @override
  State<_ScriptRenameReviewDialog> createState() =>
      _ScriptRenameReviewDialogState();
}

class _ScriptRenameReviewDialogState extends State<_ScriptRenameReviewDialog> {
  late final List<TextEditingController> _commands;
  late final List<TextEditingController> _configs;

  @override
  void initState() {
    super.initState();
    _commands = widget.preview.references
        .map((reference) => TextEditingController(text: reference.afterCommand))
        .toList(growable: false);
    _configs = widget.preview.references
        .map(
          (reference) => TextEditingController(text: reference.afterConfigPath),
        )
        .toList(growable: false);
  }

  @override
  void dispose() {
    for (final controller in [..._commands, ..._configs]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('检查任务引用'),
    content: SizedBox(
      width: 560,
      height: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.preview.source}  →  ${widget.preview.destination}'),
          const SizedBox(height: 8),
          Expanded(
            child: widget.preview.references.isEmpty
                ? const Center(child: Text('没有检测到关联任务'))
                : ListView.builder(
                    itemCount: widget.preview.references.length,
                    itemBuilder: (context, index) {
                      final reference = widget.preview.references[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(reference.name),
                            if (reference.manual)
                              const Text('命令包含手动路径，请确认并修改为新路径。'),
                            const SizedBox(height: 4),
                            const Text('当前命令'),
                            SelectableText(
                              reference.beforeCommand,
                              maxLines: 3,
                            ),
                            TextField(
                              controller: _commands[index],
                              minLines: 1,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                labelText: '改名后的命令',
                              ),
                            ),
                            TextField(
                              controller: _configs[index],
                              decoration: const InputDecoration(
                                labelText: '改名后的配置路径',
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          List<PanelScriptRenameReferenceUpdate>.generate(
            widget.preview.references.length,
            (index) => PanelScriptRenameReferenceUpdate(
              taskId: widget.preview.references[index].id,
              command: _commands[index].text,
              configPath: _configs[index].text,
            ),
            growable: false,
          ),
        ),
        child: const Text('确认改名'),
      ),
    ],
  );
}

class _CreateScriptEntry {
  const _CreateScriptEntry(this.name, this.kind);

  final String name;
  final String kind;
}

class _CreateScriptEntryDialog extends StatefulWidget {
  const _CreateScriptEntryDialog();

  @override
  State<_CreateScriptEntryDialog> createState() =>
      _CreateScriptEntryDialogState();
}

class _CreateScriptEntryDialogState extends State<_CreateScriptEntryDialog> {
  final _controller = TextEditingController();
  String _kind = 'file';
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建脚本项目'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _kind,
          decoration: const InputDecoration(labelText: '类型'),
          items: const [
            DropdownMenuItem(value: 'file', child: Text('文件')),
            DropdownMenuItem(value: 'directory', child: Text('文件夹')),
          ],
          onChanged: (value) => setState(() => _kind = value ?? 'file'),
        ),
        TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(labelText: '名称', errorText: _error),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final name = _controller.text.trim();
          if (name.isEmpty ||
              name == '.' ||
              name == '..' ||
              name.contains('/') ||
              name.contains('\\') ||
              name.contains('\u0000') ||
              name.startsWith('/')) {
            setState(() => _error = '请输入有效名称');
            return;
          }
          Navigator.pop(context, _CreateScriptEntry(name, _kind));
        },
        child: const Text('创建'),
      ),
    ],
  );
}

class _PanelScriptFileEditorView extends StatefulWidget {
  const _PanelScriptFileEditorView({
    required this.path,
    required this.manager,
    this.debugManager,
    required this.onUnauthorized,
  });

  final String path;
  final PanelScriptFilesManager manager;
  final PanelScriptDebugManager? debugManager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_PanelScriptFileEditorView> createState() =>
      _PanelScriptFileEditorViewState();
}

class _PanelScriptFileEditorViewState
    extends State<_PanelScriptFileEditorView> {
  final _controller = TextEditingController();
  PanelScriptFileSnapshot? _snapshot;
  PanelScriptFileSnapshot? _conflict;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  int _request = 0;

  Future<void> _debug() async {
    final manager = widget.debugManager;
    if (manager == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelScriptDebugView(
          manager: manager,
          initialPath: widget.path,
          onUnauthorized: widget.onUnauthorized,
          routesToClose: 3,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.manager.fetchFile(widget.path);
      if (!mounted || request != _request) return;
      _controller.text = snapshot.content;
      setState(() {
        _snapshot = snapshot;
        _conflict = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error, routesToClose: 2);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final snapshot = _snapshot;
    if (snapshot == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.manager.saveFile(
        path: widget.path,
        content: _controller.text,
        revision: snapshot.revision,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = saved;
        _conflict = null;
        _saving = false;
      });
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error, routesToClose: 2);
        return;
      }
      if (error is PanelApiException &&
          (error.statusCode == null || error.statusCode! >= 500)) {
        try {
          final current = await widget.manager.fetchFile(widget.path);
          if (!mounted) return;
          if (current.content == _controller.text) {
            setState(() {
              _snapshot = current;
              _conflict = null;
              _saving = false;
            });
            Navigator.of(context).pop(true);
            return;
          }
          if (current.revision != snapshot.revision) {
            await _showConflict(current);
            return;
          }
        } catch (verifyError) {
          if (!mounted) return;
          if (verifyError is PanelApiException &&
              verifyError.statusCode == 401) {
            await _handleUnauthorized(verifyError, routesToClose: 2);
            return;
          }
          setState(() {
            _error = '保存结果暂时无法确认。草稿仍保留，请重新读取核实后再保存。';
            _saving = false;
          });
          return;
        }
      }
      Object? current;
      if (error is PanelApiException) current = error.data?['current'];
      if (error is PanelApiException &&
          error.statusCode == 409 &&
          error.data?['code'] == 'revision_conflict' &&
          current is Map<String, dynamic>) {
        try {
          final conflict = PanelScriptFileSnapshot.fromJson(current);
          await _showConflict(conflict);
          return;
        } on FormatException {
          // Fall through to the generic recoverable error state.
        }
      }
      setState(() {
        _error = error.toString();
        _saving = false;
      });
    }
  }

  Future<void> _showConflict(PanelScriptFileSnapshot current) async {
    if (!mounted) return;
    setState(() {
      _conflict = current;
      _saving = false;
    });
    await _resolveConflict(current);
  }

  Future<void> _resolveConflict(PanelScriptFileSnapshot current) async {
    final choice = await showDialog<_ConflictChoice>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ScriptConflictDialog(
        draft: _controller.text,
        current: current.content,
      ),
    );
    if (!mounted || choice == null) return;
    setState(() {
      _snapshot = current;
      _conflict = null;
      if (choice == _ConflictChoice.adoptServer) {
        _controller.text = current.content;
      }
    });
    if (choice == _ConflictChoice.keepDraft) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('草稿已保留；再次保存将基于当前服务器版本校验')));
    }
  }

  Future<void> _handleUnauthorized(
    Object error, {
    required int routesToClose,
  }) async {
    final navigator = Navigator.of(context);
    await widget.onUnauthorized(error);
    for (var index = 0; index < routesToClose && navigator.canPop(); index++) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.path.split('/').last,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        if (widget.debugManager != null)
          IconButton(
            tooltip: '调试运行',
            onPressed: _loading || _saving || _snapshot == null ? null : _debug,
            icon: const Icon(Icons.play_arrow),
          ),
        IconButton(
          tooltip: '重新读取',
          onPressed: _loading || _saving ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '保存文件',
          onPressed: _loading || _saving || _snapshot == null ? null : _save,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: _load, child: const Text('重试'))],
          ),
        if (_conflict != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_outlined),
                const SizedBox(width: 8),
                const Expanded(child: Text('文件已在其他位置修改，草稿仍保留。')),
                TextButton(
                  onPressed: () => _resolveConflict(_conflict!),
                  child: const Text('对照版本'),
                ),
              ],
            ),
          ),
        if (_snapshot != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_formatBytes(_snapshot!.sizeBytes)} · ${_snapshot!.modifiedAt}',
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: TextField(
              controller: _controller,
              enabled: !_loading && _snapshot != null,
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

enum _ConflictChoice { keepDraft, adoptServer }

class _ScriptConflictDialog extends StatelessWidget {
  const _ScriptConflictDialog({required this.draft, required this.current});

  final String draft;
  final String current;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('文件版本冲突'),
    content: SizedBox(
      width: 560,
      height: 360,
      child: Column(
        children: [
          const Align(alignment: Alignment.centerLeft, child: Text('你的草稿')),
          Expanded(child: _VersionPreview(draft)),
          const SizedBox(height: 10),
          const Align(alignment: Alignment.centerLeft, child: Text('服务器当前版本')),
          Expanded(child: _VersionPreview(current)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('继续编辑'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _ConflictChoice.adoptServer),
        child: const Text('采用服务器内容'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _ConflictChoice.keepDraft),
        child: const Text('保留草稿'),
      ),
    ],
  );
}

class _VersionPreview extends StatelessWidget {
  const _VersionPreview(this.value);

  final String value;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(4),
    ),
    child: SingleChildScrollView(
      child: SelectableText(
        value,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

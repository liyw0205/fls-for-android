import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_collection.dart';
import '../services/panel_api_client.dart';
import '../services/panel_tasks_manager.dart';

class PanelCollectionsView extends StatefulWidget {
  const PanelCollectionsView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
  });

  final PanelTasksManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<PanelCollectionsView> createState() => PanelCollectionsViewState();
}

class PanelCollectionsViewState extends State<PanelCollectionsView> {
  final _searchController = TextEditingController();
  PanelCollectionPage? _data;
  String _query = '';
  String? _error;
  bool _loading = true;

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

  Future<void> _load({int page = 1}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.manager.fetchCollections(
        query: _query,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
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

  Future<void> refresh() => _load(page: _data?.page ?? 1);

  Future<void> _openCollection(PanelCollection collection) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _PanelCollectionDetailView(
          manager: widget.manager,
          collectionId: collection.id,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (mounted) await _load(page: _data?.page ?? 1);
  }

  Future<void> _create() async {
    final draft = await _editDialog(context);
    if (draft == null || !mounted) return;
    try {
      final result = await widget.manager.saveCollection(
        requestId: PanelTasksManager.newRequestId(),
        name: draft.$1,
        remark: draft.$2,
      );
      if (!mounted) return;
      await _load();
      final id = result['collection_id']?.toString();
      if (id != null && id.isNotEmpty && mounted) {
        await _openCollection(
          PanelCollection(
            id: id,
            name: draft.$1,
            remark: draft.$2,
            memberCount: 0,
          ),
        );
      }
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    if (error is PanelApiException && error.statusCode == 401) {
      unawaited(widget.onUnauthorized(error));
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (value) {
                    setState(() => _query = value.trim());
                    unawaited(_load());
                  },
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '搜索合集或任务',
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                              unawaited(_load());
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '新建合集',
                onPressed: _create,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            ],
          ),
        ),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: _load, child: const Text('重试'))],
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: data == null || data.items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 80),
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
                          data == null || data.total == 0
                              ? '暂无任务合集'
                              : '没有匹配的合集',
                        ),
                      ),
                      if (data == null || data.total == 0)
                        Center(
                          child: TextButton.icon(
                            onPressed: _create,
                            icon: const Icon(Icons.add),
                            label: const Text('新建合集'),
                          ),
                        ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: data.items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final collection = data.items[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          collection.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${collection.remark.isEmpty ? '暂无备注' : collection.remark}\n${collection.memberCount} 个任务',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openCollection(collection),
                      );
                    },
                  ),
          ),
        ),
        if (data != null && data.pages > 1)
          _PageControls(
            page: data.page,
            pages: data.pages,
            onPage: (page) => _load(page: page),
          ),
      ],
    );
  }
}

class _PanelCollectionDetailView extends StatefulWidget {
  const _PanelCollectionDetailView({
    required this.manager,
    required this.collectionId,
    required this.onUnauthorized,
  });

  final PanelTasksManager manager;
  final String collectionId;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_PanelCollectionDetailView> createState() =>
      _PanelCollectionDetailViewState();
}

class _PanelCollectionDetailViewState
    extends State<_PanelCollectionDetailView> {
  final _queryController = TextEditingController();
  PanelCollectionTaskPage? _data;
  List<String> _memberIds = const [];
  final Map<String, String> _selected = {};
  String _view = 'members';
  String _query = '';
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _load({int page = 1}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_view == 'available' && _memberIds.isEmpty) {
        final members = await widget.manager.fetchCollectionTasks(
          widget.collectionId,
          limit: 1,
        );
        _memberIds = members.memberIds;
        _data = members;
      }
      final data = await widget.manager.fetchCollectionTasks(
        widget.collectionId,
        view: _view,
        query: _query,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        if (data.view == 'members') _memberIds = data.memberIds;
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

  Future<void> _edit() async {
    final data = _data;
    if (data == null) return;
    final draft = await _editDialog(
      context,
      name: data.collection.name,
      remark: data.collection.remark,
    );
    if (draft == null) return;
    await _mutate(
      () => widget.manager.saveCollection(
        requestId: PanelTasksManager.newRequestId(),
        collectionId: widget.collectionId,
        collectionVersion: data.collectionVersion,
        name: draft.$1,
        remark: draft.$2,
      ),
    );
  }

  Future<void> _delete() async {
    final data = _data;
    if (data == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除合集？'),
        content: Text(
          '将删除“${data.collection.name}”，并把 ${_memberIds.length} 个任务移出合集。任务本身不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除合集'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      setState(() => _busy = true);
      await widget.manager.deleteCollection(
        collectionId: widget.collectionId,
        expectedMembers: _memberIds,
        collectionVersion: data.collectionVersion,
        requestId: PanelTasksManager.newRequestId(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _showError(error);
      if (mounted) {
        setState(() => _busy = false);
        if (error is PanelApiException && error.statusCode == 409) {
          await _load();
        }
      }
    }
  }

  Future<void> _removeTask(String taskId, String taskName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出合集？'),
        content: Text('“$taskName”仍会保留在任务列表中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _mutate(
      () => widget.manager.removeTaskFromCollection(
        taskId: taskId,
        collectionId: widget.collectionId,
        requestId: PanelTasksManager.newRequestId(),
      ),
    );
  }

  Future<void> _addSelected() async {
    if (_selected.isEmpty) return;
    await _mutate(
      () => widget.manager.addTasksToCollection(
        collectionId: widget.collectionId,
        taskIds: _selected.keys.toList(growable: false),
        expectedCollections: Map.of(_selected),
        requestId: PanelTasksManager.newRequestId(),
      ),
    );
    if (mounted) setState(_selected.clear);
  }

  Future<void> _mutate(Future<Object?> Function() operation) async {
    setState(() => _busy = true);
    try {
      await operation();
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (_view == 'members') _memberIds = const [];
      });
      await _load();
    } catch (error) {
      if (mounted) setState(() => _busy = false);
      if (mounted && error is PanelApiException && error.statusCode == 409) {
        await _load();
      }
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (error is PanelApiException && error.statusCode == 401) {
      unawaited(widget.onUnauthorized(error));
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  void _search() {
    setState(() => _query = _queryController.text.trim());
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: Text(data?.collection.name ?? '任务合集'),
        actions: [
          IconButton(
            tooltip: '编辑合集',
            onPressed: _busy || data == null ? null : _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: '删除合集',
            onPressed: _busy || data == null ? null : _delete,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _busy || _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (data != null)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text(
                data.collection.remark.isEmpty
                    ? '暂无备注'
                    : data.collection.remark,
              ),
              subtitle: Text('${_memberIds.length} 个任务'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              children: [
                TextField(
                  controller: _queryController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: _view == 'members' ? '搜索合集内任务' : '搜索可加入任务',
                    suffixIcon: IconButton(
                      tooltip: '搜索',
                      onPressed: _search,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'members', label: Text('合集任务')),
                      ButtonSegment(value: 'available', label: Text('添加任务')),
                    ],
                    selected: {_view},
                    onSelectionChanged: _busy
                        ? null
                        : (value) {
                            setState(() {
                              _view = value.first;
                              _queryController.clear();
                              _query = '';
                              _selected.clear();
                            });
                            unawaited(_load());
                          },
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [TextButton(onPressed: _load, child: const Text('重试'))],
            ),
          if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: data == null || data.items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 72),
                      Center(
                        child: Text(_view == 'members' ? '合集暂无任务' : '没有可加入的任务'),
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: data.items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final task = data.items[index];
                      if (_view == 'available') {
                        final selected = _selected.containsKey(task.id);
                        return CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: selected,
                          title: Text(
                            task.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              if (task.command.isNotEmpty) task.command,
                              if (task.collectionId.isNotEmpty) '当前属于其他合集',
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: _busy
                              ? null
                              : (value) => setState(() {
                                  if (value == true) {
                                    _selected[task.id] = task.collectionId;
                                  } else {
                                    _selected.remove(task.id);
                                  }
                                }),
                        );
                      }
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          task.running
                              ? Icons.play_circle_outline
                              : Icons.task_alt,
                        ),
                        title: Text(
                          task.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if (task.cron.isNotEmpty) task.cron,
                            if (task.command.isNotEmpty) task.command,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: '移出合集',
                          onPressed: _busy
                              ? null
                              : () => _removeTask(task.id, task.name),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      );
                    },
                  ),
          ),
          if (data != null && data.pages > 1)
            _PageControls(
              page: data.page,
              pages: data.pages,
              onPage: (page) => _load(page: page),
            ),
          if (_view == 'available')
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy || _selected.isEmpty ? null : _addSelected,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: Text(
                      _selected.isEmpty ? '选择任务' : '加入 ${_selected.length} 个任务',
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PageControls extends StatelessWidget {
  const _PageControls({
    required this.page,
    required this.pages,
    required this.onPage,
  });

  final int page;
  final int pages;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
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

Future<(String, String)?> _editDialog(
  BuildContext context, {
  String name = '',
  String remark = '',
}) async {
  final nameController = TextEditingController(text: name);
  final remarkController = TextEditingController(text: remark);
  final result = await showDialog<(String, String)>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(name.isEmpty ? '新建合集' : '编辑合集'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(labelText: '合集名称'),
              ),
              TextField(
                controller: remarkController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '备注'),
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
            onPressed: nameController.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, (
                    nameController.text.trim(),
                    remarkController.text.trim(),
                  )),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  nameController.dispose();
  remarkController.dispose();
  return result;
}

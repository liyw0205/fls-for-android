import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_script_file.dart';
import '../services/panel_api_client.dart';
import '../services/panel_script_files_manager.dart';

class PanelScriptFilesView extends StatefulWidget {
  const PanelScriptFilesView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
  });

  final PanelScriptFilesManager manager;
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
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (saved == true && mounted) await _load(page: _data?.page ?? 1);
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
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openFile(item),
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
    required this.onUnauthorized,
  });

  final String path;
  final PanelScriptFilesManager manager;
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

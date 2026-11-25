import 'package:flutter/material.dart';

import '../models/panel_global_env.dart';
import '../services/panel_api_client.dart';
import '../services/panel_global_env_manager.dart';

class PanelGlobalEnvView extends StatefulWidget {
  const PanelGlobalEnvView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
  });
  final PanelGlobalEnvManager manager;
  final Future<void> Function(PanelApiException) onUnauthorized;

  @override
  State<PanelGlobalEnvView> createState() => _PanelGlobalEnvViewState();
}

class _PanelGlobalEnvViewState extends State<PanelGlobalEnvView> {
  final _search = TextEditingController();
  PanelEnvPage? _page;
  String? _error;
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load([int page = 1]) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.manager.fetchPage(
        query: _search.text,
        page: page,
      );
      if (mounted && generation == _generation) setState(() => _page = data);
    } on PanelApiException catch (error) {
      if (!mounted || generation != _generation) return;
      if (error.statusCode == 401) {
        await widget.onUnauthorized(error);
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '变量列表读取失败');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(String action, [PanelEnvItem? item]) async {
    if (action == 'replace' &&
        !await _confirm(
          context,
          '查看全部变量？',
          '将读取全部变量值，包括凭据。保存会替换此面板的全部全局变量。',
          '查看',
        )) {
      return;
    }
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _EnvWriteView(
          manager: widget.manager,
          onUnauthorized: widget.onUnauthorized,
          action: action,
          item: item,
          initialVersion: _page?.version,
        ),
      ),
    );
    if (changed == true && mounted) await _load(_page?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('全局变量'),
      actions: [
        IconButton(
          tooltip: '刷新变量',
          onPressed: _loading ? null : () => _load(_page?.page ?? 1),
          icon: const Icon(Icons.refresh),
        ),
        PopupMenuButton<String>(
          tooltip: '变量操作',
          onSelected: _open,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'replace', child: Text('查看和替换全部变量')),
            PopupMenuItem(value: 'import', child: Text('从任务导入')),
          ],
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _search,
            maxLength: 200,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              labelText: '搜索变量名',
              counterText: '',
              suffixIcon: IconButton(
                tooltip: '搜索变量',
                onPressed: _loading ? null : () => _load(),
                icon: const Icon(Icons.search),
              ),
            ),
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) _EnvError(_error!, onRetry: () => _load()),
        Expanded(
          child: _page == null
              ? const SizedBox.shrink()
              : _page!.items.isEmpty
              ? const Center(child: Text('暂无匹配变量'))
              : ListView.separated(
                  itemCount: _page!.items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = _page!.items[index];
                    return ListTile(
                      title: Text(item.key),
                      subtitle: const Text('值已隐藏'),
                      onTap: () => _open('edit', item),
                      trailing: PopupMenuButton<String>(
                        tooltip: '${item.key} 操作',
                        onSelected: (action) => _open(action, item),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑变量')),
                          PopupMenuItem(value: 'delete', child: Text('删除变量')),
                        ],
                      ),
                    );
                  },
                ),
        ),
        if (_page != null)
          _EnvPager(page: _page!, enabled: !_loading, onPage: _load),
      ],
    ),
    floatingActionButton: FloatingActionButton.small(
      tooltip: '新增变量',
      onPressed: _page == null || _loading ? null : () => _open('new'),
      child: const Icon(Icons.add),
    ),
  );
}

class _EnvWriteView extends StatefulWidget {
  const _EnvWriteView({
    required this.manager,
    required this.onUnauthorized,
    required this.action,
    this.item,
    this.initialVersion,
  });
  final PanelGlobalEnvManager manager;
  final Future<void> Function(PanelApiException) onUnauthorized;
  final String action;
  final PanelEnvItem? item;
  final String? initialVersion;

  @override
  State<_EnvWriteView> createState() => _EnvWriteViewState();
}

class _EnvWriteViewState extends State<_EnvWriteView>
    with WidgetsBindingObserver {
  final _key = TextEditingController();
  final _value = TextEditingController();
  final _query = TextEditingController();
  final _selected = <String, PanelEnvItem>{};
  PanelEnvPage? _sources;
  String? _version;
  String? _error;
  Map<String, Object?>? _pending;
  bool _loading = false;
  bool _busy = false;
  bool _ready = false;
  bool _visible = false;
  bool _foreground = true;
  bool _dirty = false;
  bool _conflict = false;
  bool _retryAllowed = false;
  bool _overwrite = false;

  String get _title => switch (widget.action) {
    'new' => '新增全局变量',
    'edit' => '编辑全局变量',
    'delete' => '删除全局变量',
    'replace' => '全部全局变量',
    _ => '从任务导入',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _key.text = widget.item?.key ?? '';
    _version = widget.item?.version ?? widget.initialVersion;
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      _visible = false;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _key.dispose();
    _value.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _handleError(Object error) async {
    if (!mounted) return;
    if (error is PanelApiException && error.statusCode == 401) {
      await widget.onUnauthorized(error);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(
      () => _error = error is PanelApiException
          ? error.message
          : error is ArgumentError
          ? (error.message?.toString() ?? '变量参数无效')
          : '变量操作失败，请重试',
    );
  }

  Future<void> _load([int page = 1]) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.action == 'import') {
        final data = await widget.manager.fetchPage(
          query: _query.text,
          page: page,
          sources: true,
        );
        if (!mounted) return;
        setState(() {
          _sources = data;
          _version ??= data.version;
        });
      } else if (widget.action == 'edit' || widget.action == 'replace') {
        final data = await widget.manager.fetchContent(
          key: widget.action == 'edit' ? widget.item!.key : null,
        );
        if (!mounted) return;
        setState(() {
          _value.text = data.content;
          _version = data.version;
        });
      } else if (_version == null) {
        final data = await widget.manager.fetchPage();
        if (mounted) setState(() => _version = data.version);
      }
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      await _handleError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rebase() async {
    if (_pending != null &&
        !await _confirm(
          context,
          '放弃原提交恢复？',
          '原提交结果无法确认。继续将核对服务器当前内容，再以新提交保存保留的草稿。',
          '核对当前内容',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String version;
      if (widget.action == 'edit' || widget.action == 'replace') {
        final data = await widget.manager.fetchContent(
          key: widget.action == 'edit' ? widget.item!.key : null,
        );
        if (!mounted) return;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('核对面板当前内容'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('继续会以保留的草稿替换以下当前内容。'),
                    const SizedBox(height: 16),
                    SelectableText(data.content),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回草稿'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保留草稿并继续'),
              ),
            ],
          ),
        );
        if (accepted != true) return;
        version = data.version;
      } else {
        if (!mounted ||
            !await _confirm(
              context,
              '重新核对变量？',
              widget.action == 'import'
                  ? '将清空已选任务变量，请按最新来源重新选择。'
                  : '将重新读取面板版本，保留填写内容。',
              '核对',
            )) {
          return;
        }
        final data = await widget.manager.fetchPage(
          query: widget.action == 'delete' ? widget.item!.key : '',
        );
        if (widget.action == 'delete') {
          final items = data.items.where(
            (item) => item.key == widget.item!.key,
          );
          if (items.isEmpty) throw const PanelApiException('变量已删除，请返回列表刷新');
          version = items.first.version;
        } else {
          version = data.version;
        }
        if (widget.action == 'import') {
          _selected.clear();
          _sources = null;
          _query.clear();
        }
      }
      if (!mounted) return;
      setState(() {
        _version = version;
        _conflict = false;
        _pending = null;
        _retryAllowed = false;
      });
      if (widget.action == 'import') await _load();
    } catch (error) {
      await _handleError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_pending != null && !_retryAllowed) return;
    if (!await _confirm(
      context,
      _pending != null ? '重试原提交？' : '$_title？',
      widget.action == 'delete'
          ? '将删除 ${widget.item!.key}，后续任务不再继承此全局变量。'
          : widget.action == 'replace'
          ? '将替换此面板的全部全局变量。未包含的变量会被删除。'
          : widget.action == 'import'
          ? '将导入 ${_selected.length} 项任务变量；${_overwrite ? '覆盖' : '跳过'}已有同名变量。'
          : '保存后将影响后续任务；任务中的同名变量仍优先。',
      '确认',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data =
          _pending ??
          <String, Object?>{
            'action': widget.action,
            'version': _version,
            'request_id': PanelGlobalEnvManager.newRequestId(),
            if (widget.action == 'new' || widget.action == 'edit') ...{
              'key': _key.text.trim(),
              'value': _value.text,
            },
            if (widget.action == 'edit' || widget.action == 'delete')
              'original_key': widget.item!.key,
            if (widget.action == 'replace') 'env_text': _value.text,
            if (widget.action == 'import') ...{
              'items': _selected.keys.toList(growable: false),
              'sources': _selected.map(
                (key, value) => MapEntry(key, value.version),
              ),
              'overwrite': _overwrite,
            },
          };
      _pending = Map.unmodifiable(data);
      final result = await widget.manager.mutate({
        ...data,
        if (_retryAllowed) 'confirm_retry': true,
      });
      _finish(result);
    } on ArgumentError catch (error) {
      _pending = null;
      await _handleError(error);
    } on PanelApiException catch (error) {
      final result = error.data == null
          ? null
          : PanelEnvResult.fromJson(error.data);
      if (result?.saved == true) {
        _finish(result!);
        return;
      }
      if (error.statusCode == 401 ||
          error.statusCode == 403 ||
          (error.statusCode != null &&
              error.statusCode! >= 400 &&
              error.statusCode! < 500 &&
              error.statusCode != 408 &&
              result?.saved != null &&
              result?.resolved == true)) {
        _pending = null;
      }
      _conflict = result?.conflict == true && result?.resolved == true;
      _retryAllowed = result?.confirmRequired == true;
      await _handleError(error);
    } catch (error) {
      await _handleError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish(PanelEnvResult result) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已保存，变更 ${result.changed} 项${result.skipped > 0 ? '，跳过 ${result.skipped} 项' : ''}',
        ),
      ),
    );
    setState(() {
      _pending = null;
      _dirty = false;
    });
    Navigator.of(context).pop(true);
  }

  Future<void> _check() async {
    final pending = _pending;
    if (pending == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.manager.status(
        pending['request_id'] as String,
      );
      if (!mounted) return;
      if (result.saved == true) {
        _finish(result);
        return;
      }
      setState(() {
        _retryAllowed = result.saved == false || result.state == 'missing';
        _conflict = result.state == 'unknown';
        _error = _retryAllowed ? '尚未确认保存，可核对后重试原提交。' : '结果未知且变量已变化，请核对面板当前内容。';
      });
    } catch (error) {
      await _handleError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    if ((_dirty || _pending != null) &&
        !await _confirm(
          context,
          '离开变量编辑？',
          _pending == null
              ? '尚未保存的草稿会丢失。'
              : '提交结果尚未确认。离开不会撤销服务器操作，草稿和原提交信息会丢失，请优先查询原提交。',
          '离开',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _pending = null;
    });
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        _ready && !_busy && !_loading && _pending == null && !_conflict;
    return PopScope(
      canPop: !_busy && !_dirty && _pending == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: !_foreground
            ? const Center(child: Icon(Icons.lock_outline))
            : Column(
                children: [
                  if (_loading || _busy) const LinearProgressIndicator(),
                  if (_error != null)
                    _EnvError(
                      _error!,
                      onRetry: _loading || _busy
                          ? null
                          : _pending != null
                          ? _check
                          : _conflict
                          ? _rebase
                          : !_ready
                          ? _load
                          : null,
                      label: _pending != null
                          ? '查询原提交'
                          : _conflict
                          ? '核对当前内容'
                          : '重试',
                    ),
                  if (_pending != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SelectableText('提交 ${_pending!['request_id']}'),
                    ),
                  if (_pending != null && _conflict)
                    TextButton(
                      onPressed: _busy ? null : _rebase,
                      child: const Text('核对当前内容'),
                    ),
                  Expanded(
                    child: widget.action == 'import'
                        ? _importBody(enabled)
                        : ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              if (widget.action == 'delete')
                                Text(
                                  '变量 ${widget.item!.key}',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              if (widget.action == 'new' ||
                                  widget.action == 'edit') ...[
                                TextField(
                                  controller: _key,
                                  enabled: enabled,
                                  maxLength: 200,
                                  onChanged: (_) =>
                                      setState(() => _dirty = true),
                                  decoration: const InputDecoration(
                                    labelText: '变量名',
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (widget.action != 'delete') ...[
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        widget.action == 'replace'
                                            ? '变量文本'
                                            : '变量值',
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: _visible ? '隐藏变量值' : '显示变量值',
                                      onPressed: _loading
                                          ? null
                                          : () => setState(
                                              () => _visible = !_visible,
                                            ),
                                      icon: Icon(
                                        _visible
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                    ),
                                  ],
                                ),
                                if (_visible)
                                  TextField(
                                    controller: _value,
                                    enabled: enabled,
                                    minLines: widget.action == 'replace'
                                        ? 12
                                        : 4,
                                    maxLines: null,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    onChanged: (_) =>
                                        setState(() => _dirty = true),
                                    decoration: InputDecoration(
                                      labelText: widget.action == 'replace'
                                          ? '全部变量文本'
                                          : '变量值',
                                    ),
                                  )
                                else
                                  const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Text('变量值已隐藏'),
                                  ),
                              ],
                            ],
                          ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed:
                              _busy ||
                                  _loading ||
                                  _version == null ||
                                  !_ready ||
                                  _conflict ||
                                  (_pending != null && !_retryAllowed) ||
                                  (widget.action == 'import' &&
                                      _selected.isEmpty)
                              ? null
                              : _save,
                          icon: Icon(
                            widget.action == 'delete'
                                ? Icons.delete_outline
                                : Icons.save_outlined,
                          ),
                          label: Text(
                            _pending != null
                                ? '确认后重试原提交'
                                : widget.action == 'delete'
                                ? '删除变量'
                                : widget.action == 'import'
                                ? '导入所选变量'
                                : '保存变量',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _importBody(bool enabled) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _query,
          enabled: enabled,
          maxLength: 200,
          onSubmitted: (_) => _load(),
          decoration: InputDecoration(
            labelText: '搜索任务或变量名',
            counterText: '',
            suffixIcon: IconButton(
              tooltip: '搜索任务变量',
              onPressed: enabled ? () => _load() : null,
              icon: const Icon(Icons.search),
            ),
          ),
        ),
      ),
      SwitchListTile(
        title: const Text('覆盖已有同名变量'),
        value: _overwrite,
        onChanged: enabled
            ? (value) => setState(() {
                _overwrite = value;
                _dirty = true;
              })
            : null,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(child: Text('已选 ${_selected.length} / 200')),
            IconButton(
              tooltip: '清空选择',
              onPressed: enabled
                  ? () => setState(() => _selected.clear())
                  : null,
              icon: const Icon(Icons.deselect),
            ),
          ],
        ),
      ),
      Expanded(
        child: _sources == null
            ? const SizedBox.shrink()
            : _sources!.items.isEmpty
            ? const Center(child: Text('暂无匹配任务变量'))
            : ListView.builder(
                itemCount: _sources!.items.length,
                itemBuilder: (_, index) {
                  final item = _sources!.items[index];
                  return CheckboxListTile(
                    title: Text(item.key),
                    subtitle: Text(
                      '${item.taskName}\n${item.exists ? '已存在同名全局变量' : '新增全局变量'}',
                    ),
                    value: _selected.containsKey(item.id),
                    onChanged:
                        !enabled ||
                            (!_selected.containsKey(item.id) &&
                                _selected.length >= 200)
                        ? null
                        : (value) => setState(() {
                            _dirty = true;
                            if (value == true) {
                              _selected[item.id!] = item;
                            } else {
                              _selected.remove(item.id);
                            }
                          }),
                  );
                },
              ),
      ),
      if (_sources != null)
        _EnvPager(page: _sources!, enabled: enabled, onPage: _load),
    ],
  );
}

class _EnvPager extends StatelessWidget {
  const _EnvPager({
    required this.page,
    required this.enabled,
    required this.onPage,
  });
  final PanelEnvPage page;
  final bool enabled;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: enabled && page.page > 1
              ? () => onPage(page.page - 1)
              : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Flexible(child: Text('${page.page} / ${page.pages} · ${page.total} 项')),
        IconButton(
          tooltip: '下一页',
          onPressed: enabled && page.page < page.pages
              ? () => onPage(page.page + 1)
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
}

class _EnvError extends StatelessWidget {
  const _EnvError(this.message, {this.onRetry, this.label = '重试'});
  final String message;
  final VoidCallback? onRetry;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        if (onRetry != null) TextButton(onPressed: onRetry, child: Text(label)),
      ],
    ),
  );
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
  String label,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(label),
          ),
        ],
      ),
    ) ==
    true;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/panel_task_config.dart';
import '../services/panel_api_client.dart';
import '../services/panel_tasks_manager.dart';

class PanelTaskConfigView extends StatefulWidget {
  const PanelTaskConfigView({
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
  State<PanelTaskConfigView> createState() => _PanelTaskConfigViewState();
}

class _PanelTaskConfigViewState extends State<PanelTaskConfigView>
    with WidgetsBindingObserver {
  final _content = TextEditingController();
  late PanelTaskConfigRecovery _recovery;
  PanelTaskConfigSnapshot? _file;
  PanelTaskConfigSnapshot? _latest;
  String? _error;
  String? _message;
  String? _requestStatus;
  bool _busy = false;
  bool _authorized = true;
  bool _background = false;
  bool _allowPop = false;
  bool _hasDraft = false;
  bool _needsReview = false;
  BuildContext? _dialogContext;
  int _generation = 0;

  bool get _pending => _recovery.requestId != null;
  bool get _dirty => _file != null && _content.text != _file!.content;
  bool get _canWrite =>
      !_busy &&
      !_pending &&
      _authorized &&
      !_background &&
      _file != null &&
      _latest == null &&
      !_needsReview;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bind();
  }

  @override
  void didUpdateWidget(covariant PanelTaskConfigView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager ||
        oldWidget.taskId != widget.taskId) {
      _generation++;
      _closeDialog();
      _content.clear();
      _file = null;
      _latest = null;
      _busy = false;
      _authorized = true;
      _error = null;
      _message = null;
      _requestStatus = null;
      _hasDraft = false;
      _needsReview = false;
      _allowPop = false;
      _bind();
    }
  }

  void _bind() {
    _recovery = widget.manager.configRecoveryFor(widget.taskId);
    unawaited(_pending ? _query() : _load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => _background = state != AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    _generation++;
    _closeDialog();
    WidgetsBinding.instance.removeObserver(this);
    _content.dispose();
    super.dispose();
  }

  bool _current(int generation) =>
      mounted && generation == _generation && _authorized;

  void _closeDialog() {
    final dialog = _dialogContext;
    _dialogContext = null;
    if (dialog == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (dialog.mounted && ModalRoute.of(dialog)?.isCurrent == true) {
        Navigator.of(dialog).pop();
      }
    });
  }

  Future<void> _fail(Object error, int generation) async {
    if (!_current(generation)) return;
    if (error is PanelApiException && error.statusCode == 401) {
      setState(() {
        _authorized = false;
        _busy = false;
        _generation++;
      });
      _closeDialog();
      await widget.onUnauthorized(error);
      return;
    }
    setState(
      () => _error = error is PanelApiException ? error.message : '任务配置操作失败',
    );
  }

  Future<void> _load() async {
    if (_busy || !_authorized) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await widget.manager.fetchTaskConfig(widget.taskId);
      if (!_current(generation)) return;
      setState(() {
        if (_file != null && _dirty && _file!.revision != file.revision) {
          _latest = file;
          _needsReview = true;
          _error = '当前配置已变更，草稿已保留';
        } else {
          if (!_dirty) _content.text = file.content;
          _file = file;
          _hasDraft = true;
          _latest = null;
        }
      });
    } catch (error) {
      await _fail(error, generation);
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _applyResult(
    PanelTaskConfigSubmission result,
    int generation,
  ) async {
    if (!_current(generation)) return;
    if (result.status == 'saved' || result.status == 'not_saved') {
      setState(() {
        _recovery.requestId = null;
        _requestStatus = null;
        _busy = false;
        if (result.status == 'saved') {
          _file = null;
          _latest = null;
          _message = result.cleanupRequired ? '配置已保存，临时文件清理待处理' : '配置已保存';
        } else {
          _message = '原提交未保存';
        }
      });
      await _load();
    } else {
      setState(() {
        _requestStatus = result.status;
        _error = result.status == 'missing'
            ? '未找到原提交回执，请核对当前配置'
            : '原提交结果尚未确认，请核对当前配置';
      });
    }
  }

  Future<void> _save() async {
    final file = _file;
    if (!_canWrite || file == null) return;
    if (_content.text.length > file.maxBytes ||
        utf8.encode(_content.text).length > file.maxBytes) {
      setState(() => _error = '配置内容超过 ${file.maxBytes} 字节编辑上限');
      return;
    }
    final generation = ++_generation;
    final requestId = PanelTasksManager.newRequestId();
    setState(() {
      _recovery.requestId = requestId;
      _requestStatus = null;
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await widget.manager.saveTaskConfig(
        file,
        content: _content.text,
        requestId: requestId,
      );
      await _applyResult(result, generation);
    } catch (error) {
      if (!_current(generation)) return;
      if (error is PanelApiException && error.data?['saved'] == false) {
        setState(() {
          _recovery.requestId = null;
          if (error.data?['code'] == 'revision_conflict') _needsReview = true;
        });
        final current = error.data?['current'];
        if (current != null) {
          try {
            final latest = PanelTaskConfigSnapshot.fromJson(current);
            if (latest.taskId == widget.taskId) {
              setState(() => _latest = latest);
            }
          } on FormatException {
            /* Keep the draft if the conflict payload is invalid. */
          }
        }
      }
      await _fail(error, generation);
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _query() async {
    final requestId = _recovery.requestId;
    if (_busy || requestId == null || !_authorized) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _requestStatus = null;
    });
    try {
      final result = await widget.manager.fetchTaskConfigRequest(
        widget.taskId,
        requestId,
      );
      await _applyResult(result, generation);
    } catch (error) {
      await _fail(error, generation);
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _review() async {
    if (_busy || !_authorized || (_pending && _requestStatus == null)) return;
    final generation = ++_generation;
    final requestId = _recovery.requestId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final latest = await widget.manager.fetchTaskConfig(widget.taskId);
      if (!_current(generation) || !mounted) return;
      BuildContext? dialogContext;
      final adoptServer = await showDialog<bool>(
        context: context,
        builder: (context) {
          _dialogContext = context;
          dialogContext = context;
          return AlertDialog(
            title: const Text('核对任务配置'),
            content: SizedBox(
              width: 640,
              height: MediaQuery.sizeOf(context).height * .45,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(latest.path),
                    if (_file != null && _file!.path != latest.path)
                      Text('任务路径已从 ${_file!.path} 变更'),
                    if (requestId != null)
                      const Text('原提交结果无法确认。结束核对后，可基于当前版本另行保存。'),
                    const SizedBox(height: 16),
                    const Text('当前配置'),
                    SelectableText(
                      latest.content.isEmpty ? '（空文件）' : latest.content,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    const Divider(height: 24),
                    Text(_hasDraft ? '本地草稿' : '原草稿未保留'),
                    SelectableText(
                      _content.text.isEmpty ? '（空草稿）' : _content.text,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('采用当前内容'),
              ),
              if (_hasDraft)
                FilledButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('保留草稿合并'),
                ),
            ],
          );
        },
      );
      if (_dialogContext == dialogContext) _dialogContext = null;
      if (!_current(generation) ||
          adoptServer == null ||
          _recovery.requestId != requestId) {
        return;
      }
      setState(() {
        if (adoptServer) _content.text = latest.content;
        _file = latest;
        _latest = null;
        _needsReview = false;
        _hasDraft = true;
        _recovery.requestId = null;
        _requestStatus = null;
        _message = adoptServer ? '已采用当前配置' : '草稿已保留，请合并后保存';
      });
    } catch (error) {
      await _fail(error, generation);
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    final generation = _generation;
    BuildContext? dialogContext;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        _dialogContext = context;
        dialogContext = context;
        return AlertDialog(
          title: const Text('离开配置编辑？'),
          content: Text(
            _pending ? '草稿将丢弃。原提交 ID 会保留在当前面板会话，重新进入后可查询。' : '未保存的草稿将丢弃。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('离开'),
            ),
          ],
        );
      },
    );
    if (_dialogContext == dialogContext) _dialogContext = null;
    if (!mounted || generation != _generation || confirmed != true) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    return PopScope(
      canPop: _allowPop || (!_busy && !_dirty && !_pending),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            '任务配置文件',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '重新读取配置',
              onPressed: _busy || _pending || !_authorized ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '保存配置',
              onPressed: _canWrite ? _save : null,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: !_authorized || _background
            ? const Center(child: Icon(Icons.lock_outline))
            : SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: SizedBox(
                      height: math.max(
                        constraints.maxHeight,
                        (_pending || _error != null ? 480 : 320) *
                            MediaQuery.textScalerOf(context).scale(14) /
                            14,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_busy)
                            const LinearProgressIndicator(minHeight: 2),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.taskName,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                if (file != null) Text(file.path),
                                if (file != null && !file.exists)
                                  const Text('文件不存在，保存后创建'),
                                if (_message != null) Text(_message!),
                                if (_error != null)
                                  Text(
                                    _error!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                if (_pending) ...[
                                  SelectableText(
                                    '提交 ID：${_recovery.requestId}',
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: _busy ? null : _query,
                                        icon: const Icon(Icons.manage_search),
                                        label: const Text('查询原提交'),
                                      ),
                                      if (_requestStatus != null)
                                        TextButton(
                                          onPressed: _busy ? null : _review,
                                          child: const Text('核对当前配置'),
                                        ),
                                    ],
                                  ),
                                ] else if (_needsReview ||
                                    _latest != null ||
                                    (_error != null && file != null))
                                  TextButton.icon(
                                    onPressed: _busy ? null : _review,
                                    icon: const Icon(Icons.compare_arrows),
                                    label: const Text('对照并合并草稿'),
                                  )
                                else if (file == null && !_busy)
                                  TextButton.icon(
                                    onPressed: _load,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重新读取配置'),
                                  ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: TextField(
                                controller: _content,
                                readOnly: !_canWrite,
                                expands: true,
                                minLines: null,
                                maxLines: null,
                                autocorrect: false,
                                enableSuggestions: false,
                                keyboardType: TextInputType.multiline,
                                textAlignVertical: TextAlignVertical.top,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 14,
                                ),
                                decoration: const InputDecoration(
                                  labelText: '配置内容',
                                  alignLabelWithHint: true,
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (_) =>
                                    setState(() => _message = null),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

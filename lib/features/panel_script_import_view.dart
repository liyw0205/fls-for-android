import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/panel_script_import.dart';
import '../services/local_file_bridge.dart';
import '../services/panel_api_client.dart';
import '../services/panel_script_import_manager.dart';

class PanelScriptImportSource {
  const PanelScriptImportSource({
    required this.path,
    required this.filename,
    required this.sizeBytes,
  });

  final String path;
  final String filename;
  final int sizeBytes;
}

typedef PanelScriptImportPicker = Future<PanelScriptImportSource?> Function();

class PanelScriptImportView extends StatefulWidget {
  const PanelScriptImportView({
    super.key,
    required this.manager,
    required this.currentPath,
    required this.onUnauthorized,
    this.pickFile,
  });

  final PanelScriptImportManager manager;
  final String currentPath;
  final Future<void> Function(Object error) onUnauthorized;
  final PanelScriptImportPicker? pickFile;

  @override
  State<PanelScriptImportView> createState() => _PanelScriptImportViewState();
}

class _PanelScriptImportViewState extends State<PanelScriptImportView> {
  final _nameController = TextEditingController();
  Timer? _pollTimer;
  PanelScriptImportSource? _source;
  List<PanelScriptImportJob> _history = const [];
  PanelScriptImportJob? _selected;
  String? _error;
  String? _pendingRequestId;
  int _uploadSent = 0;
  int _uploadTotal = 0;
  bool _loading = true;
  bool _picking = false;
  bool _submitting = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitial());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _nameController.dispose();
    if (!_submitting) _deleteSource();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    try {
      final history = await widget.manager.fetchHistory(limit: 20);
      if (!mounted) return;
      final active = _firstOrNull(history.items.where((job) => job.isActive));
      setState(() {
        _history = history.items;
        _selected = active;
        _loading = false;
      });
      if (active != null) _startPolling();
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

  Future<PanelScriptImportSource?> _pickAndCopy() async {
    final picked = await LocalFileBridge.pickScriptImport();
    if (picked == null) return null;
    final directory = await getTemporaryDirectory();
    final destination = p.join(
      directory.path,
      'fls-script-import-${DateTime.now().microsecondsSinceEpoch}.upload',
    );
    final copied = await LocalFileBridge.copyUriToPath(
      uri: picked.uri,
      path: destination,
      maxBytes: PanelScriptImportManager.maxUploadBytes,
    );
    if (!copied) throw const FileSystemException('无法读取所选文件');
    final file = File(destination);
    final size = await file.length();
    if (size > PanelScriptImportManager.maxUploadBytes) {
      await file.delete();
      throw const PanelApiException('文件超过 64 MiB 限制', statusCode: 413);
    }
    return PanelScriptImportSource(
      path: destination,
      filename: picked.name,
      sizeBytes: size,
    );
  }

  Future<void> _pick() async {
    if (_picking || _submitting) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final picked = await (widget.pickFile ?? _pickAndCopy)();
      if (!mounted) {
        if (picked != null) {
          try {
            await File(picked.path).delete();
          } on FileSystemException {
            // The temporary picker copy may already have been removed by the OS.
          }
        }
        return;
      }
      if (picked == null) return;
      await _deleteSource();
      setState(() {
        _source = picked;
        _pendingRequestId = null;
        _nameController.text = _defaultTargetName(picked.filename);
      });
    } catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  String _defaultTargetName(String filename) {
    final kind = PanelScriptImportManager.kindForFilename(filename);
    if (kind == 'zip' || kind == 'tar' || kind == 'tar.gz') {
      final lower = filename.toLowerCase();
      if (lower.endsWith('.tar.gz')) {
        return filename.substring(0, filename.length - 7);
      }
      if (lower.endsWith('.tgz')) {
        return filename.substring(0, filename.length - 4);
      }
      if (lower.endsWith('.zip') || lower.endsWith('.tar')) {
        return filename.substring(0, filename.length - 4);
      }
    }
    return filename;
  }

  String? _targetPath() {
    final name = _nameController.text.trim();
    if (name.isEmpty ||
        name != _nameController.text ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        name.endsWith('.') ||
        name.endsWith(' ') ||
        name.contains(':') ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$',
          caseSensitive: false,
        ).hasMatch(name)) {
      return null;
    }
    return widget.currentPath.isEmpty ? name : '${widget.currentPath}/$name';
  }

  Future<void> _submit() async {
    final source = _source;
    final path = _targetPath();
    if (source == null || path == null) {
      setState(() => _error = '请选择文件并填写有效的目标名称');
      return;
    }
    final requestId =
        _pendingRequestId ?? PanelScriptImportManager.newRequestId();
    _pendingRequestId = requestId;
    setState(() {
      _submitting = true;
      _uploadSent = 0;
      _uploadTotal = 0;
      _error = null;
    });
    try {
      final job = await widget.manager.submit(
        filePath: source.path,
        filename: source.filename,
        path: path,
        requestId: requestId,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _uploadSent = sent;
            _uploadTotal = total;
          });
        },
      );
      if (!mounted) return;
      _pendingRequestId = null;
      await _deleteSource();
      setState(() {
        _source = null;
        _submitting = false;
        _selected = job;
        _upsert(job);
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
      }
      setState(() {
        _submitting = false;
        _error = _messageFor(error);
      });
      unawaited(_refreshHistory(silent: true));
    } finally {
      if (!mounted) {
        try {
          await File(source.path).delete();
        } on FileSystemException {
          // The temporary picker copy may already have been removed by the OS.
        }
      }
    }
  }

  Future<void> _cancel(PanelScriptImportJob job) async {
    try {
      final updated = await widget.manager.cancel(job.id);
      if (!mounted) return;
      setState(() {
        _selected = updated;
        _upsert(updated);
      });
      _startPolling();
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
        return;
      }
      setState(() => _error = _messageFor(error));
      unawaited(_refreshHistory(silent: true));
    }
  }

  void _select(PanelScriptImportJob job) {
    setState(() {
      _selected = job;
      _error = null;
    });
    if (job.isActive) _startPolling();
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refreshSelected()),
    );
    unawaited(_refreshSelected());
  }

  Future<void> _refreshSelected() async {
    final selected = _selected;
    if (_refreshing || selected == null || !mounted) return;
    _refreshing = true;
    try {
      final job = await widget.manager.fetchJob(selected.id);
      if (!mounted) return;
      setState(() {
        _selected = job;
        _upsert(job);
      });
      if (!job.isActive) {
        _pollTimer?.cancel();
        _pollTimer = null;
        if (job.isComplete) _showCompleted(job);
      }
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
      } else {
        setState(() => _error = _messageFor(error));
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshHistory({bool silent = false}) async {
    try {
      final history = await widget.manager.fetchHistory(limit: 20);
      if (!mounted) return;
      setState(() {
        _history = history.items;
        final selectedId = _selected?.id;
        if (selectedId != null) {
          _selected =
              _firstOrNull(
                history.items.where((job) => job.id == selectedId),
              ) ??
              _selected;
        }
      });
    } catch (error) {
      if (!mounted || silent) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _handleUnauthorized(error);
      } else {
        setState(() => _error = _messageFor(error));
      }
    }
  }

  void _upsert(PanelScriptImportJob job) {
    _history = [
      job,
      ..._history.where((item) => item.id != job.id),
    ].take(20).toList(growable: false);
  }

  Future<void> _handleUnauthorized(Object error) async {
    await widget.onUnauthorized(error);
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _deleteSource() async {
    final source = _source;
    if (source == null) return;
    try {
      await File(source.path).delete();
    } on FileSystemException {
      // The temporary picker copy may already have been removed by the OS.
    }
  }

  String _messageFor(Object error) {
    if (error is PanelApiException) {
      final code = error.data?['code'];
      return switch (code) {
        'target_exists' => '目标已存在，未覆盖。请选择新名称。',
        'request_id_conflict' => '导入请求已变化，请重新选择文件。',
        'too_large' => '文件或解压内容超过大小限制。',
        'too_many_active_jobs' => '当前导入任务较多，请稍后重试。',
        'not_cancellable' => '作业已进入发布阶段，不能取消。',
        'worker_interrupted' => '服务重启中断了导入，请检查目录后再继续。',
        _ => error.message,
      };
    }
    return error.toString();
  }

  String _status(PanelScriptImportJob job) => switch (job.status) {
    'pending' => '等待导入',
    'processing' => job.kind == 'file' ? '正在写入' : '正在解包',
    'publishing' => '正在发布',
    'cancelling' => '正在取消',
    'complete' => '已完成',
    'cancelled' => '已取消',
    'unknown' => '结果未知',
    'failed' => _failureStatus(job.errorCode),
    _ => job.status,
  };

  String _failureStatus(String code) => switch (code) {
    'target_exists' => '目标已存在，未覆盖',
    'too_large' => '超过大小限制',
    'worker_interrupted' => '服务重启中断，结果需核实',
    _ => '导入失败',
  };

  double? _jobFraction(PanelScriptImportJob job) {
    if (job.status == 'complete') return 1;
    if (job.kind != 'file' || job.status != 'processing') return null;
    final total = job.progress.totalBytes;
    if (total == null || total == 0) return null;
    return (job.progress.processedBytes / total).clamp(0.0, 1.0).toDouble();
  }

  String _jobProgressLabel(PanelScriptImportJob job) {
    if (job.status == 'complete') return '已完成';
    if (job.kind == 'file' && job.status == 'processing') {
      final total = job.progress.totalBytes;
      if (total != null && total > 0) {
        final percent = (job.progress.processedBytes * 100 / total)
            .round()
            .clamp(0, 100);
        return '${_formatBytes(job.progress.processedBytes)} / ${_formatBytes(total)}  $percent%';
      }
      return '正在写入 ${_formatBytes(job.progress.processedBytes)}';
    }
    if (job.kind != 'file' && job.progress.processedBytes > 0) {
      return '已解包 ${_formatBytes(job.progress.processedBytes)}';
    }
    return _status(job);
  }

  void _showCompleted(PanelScriptImportJob job) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已导入 ${job.path}')));
  }

  void _finish() => Navigator.of(context).pop(true);

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final selected = _selected;
    final uploadFraction = _uploadTotal > 0
        ? (_uploadSent / _uploadTotal).clamp(0.0, 1.0).toDouble()
        : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('上传与导入'),
        actions: [
          IconButton(
            tooltip: '刷新作业',
            onPressed: _loading ? null : _refreshHistory,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  widget.currentPath.isEmpty
                      ? 'scripts 根目录'
                      : 'scripts/${widget.currentPath}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.attach_file),
                  title: Text(source?.filename ?? '选择文件'),
                  subtitle: Text(
                    source == null
                        ? '普通文件、ZIP、TAR 或 TGZ'
                        : _formatBytes(source.sizeBytes),
                  ),
                  trailing: IconButton(
                    tooltip: '选择文件',
                    onPressed:
                        _picking || _submitting || _pendingRequestId != null
                        ? null
                        : _pick,
                    icon: _picking
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open_outlined),
                  ),
                ),
                TextField(
                  controller: _nameController,
                  enabled: !_submitting && _pendingRequestId == null,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: '目標名称',
                    prefixText: widget.currentPath.isEmpty
                        ? 'scripts/'
                        : 'scripts/${widget.currentPath}/',
                  ),
                ),
                if (source != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    PanelScriptImportManager.kindForFilename(source.filename) ==
                            'file'
                        ? '已有目标文件不会覆盖'
                        : '归档目标目录必须不存在',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (_submitting) ...[
                  LinearProgressIndicator(value: uploadFraction),
                  const SizedBox(height: 8),
                  Text(
                    _uploadTotal > 0
                        ? '上传中 · ${_formatBytes(_uploadSent)} / ${_formatBytes(_uploadTotal)} ${((uploadFraction ?? 0) * 100).round()}%'
                        : '正在准备上传',
                  ),
                  const SizedBox(height: 8),
                ],
                if (selected != null) ...[
                  const Divider(height: 24),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_status(selected)),
                    subtitle: Text(selected.path),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '检查作业状态',
                          onPressed: _refreshSelected,
                          icon: const Icon(Icons.sync),
                        ),
                        if (selected.isCancellable)
                          IconButton(
                            tooltip: '取消导入',
                            onPressed: () => _cancel(selected),
                            icon: const Icon(Icons.close),
                          ),
                      ],
                    ),
                  ),
                  LinearProgressIndicator(value: _jobFraction(selected)),
                  const SizedBox(height: 6),
                  Text(_jobProgressLabel(selected)),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  MaterialBanner(
                    content: Text(_error!),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _error = null),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: source == null || _submitting || _picking
                      ? null
                      : _submit,
                  icon: _submitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file_outlined),
                  label: Text(_submitting ? '正在上传' : '上传并导入'),
                ),
                if (selected?.isComplete == true) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _finish, child: const Text('返回目录')),
                ],
                if (_history.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  Text('最近作业', style: Theme.of(context).textTheme.titleSmall),
                  for (final job in _history.take(10))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        job.isComplete
                            ? Icons.check_circle_outline
                            : job.status == 'failed'
                            ? Icons.error_outline
                            : Icons.upload_file_outlined,
                      ),
                      title: Text(job.path),
                      subtitle: Text('${_status(job)} · ${job.kind}'),
                      onTap: () => _select(job),
                    ),
                ],
              ],
            ),
    );
  }

  static String _formatBytes(int value) {
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}

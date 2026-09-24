import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/local_install_manager.dart';
import '../services/local_file_bridge.dart';
import '../services/local_panel_host.dart';
import '../services/operation_cancellation.dart';
import 'remote_web_view.dart';
import '../models/panel_server.dart';

enum _LocalTab { overview, environment, diagnostics }

class LocalSetupView extends StatefulWidget {
  const LocalSetupView({super.key});

  @override
  State<LocalSetupView> createState() => _LocalSetupViewState();
}

class _LocalSetupViewState extends State<LocalSetupView>
    with WidgetsBindingObserver {
  final _manager = LocalInstallManager();
  bool _loading = true;
  bool _installing = false;
  bool _installed = false;
  bool _runtimeInstalled = false;
  bool _panelReady = false;
  bool _autoRestart = false;
  bool _notificationsGranted = true;
  _LocalTab _tab = _LocalTab.overview;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  Timer? _statusTimer;
  String _logText = '';
  LocalPanelStatus _serviceStatus = const LocalPanelStatus(
    state: LocalPanelState.stopped,
    startedAt: null,
    exitCode: null,
    restartAttempts: 0,
    autoRestart: false,
  );
  RuntimeProfile _selectedProfile = RuntimeProfile.python;
  RuntimeProfile? _installedProfile;
  double _progress = 0;
  String _phase = '';
  String? _error;
  OperationCancellation? _cancellation;
  final _mirrorController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_tab == _LocalTab.overview &&
          _lifecycleState == AppLifecycleState.resumed &&
          !_installing) {
        _refreshStatus();
      }
    });
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _cancellation?.cancel();
    _mirrorController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final values = await Future.wait([
      _manager.installedRuntimeProfile(),
      _manager.hasProject(),
      LocalPanelHost.status(),
      _manager.loadGithubMirror(),
      LocalPanelHost.notificationsGranted(),
    ]);
    if (!mounted) return;
    final profile = values[0] as RuntimeProfile?;
    final serviceStatus = values[2] as LocalPanelStatus;
    _mirrorController.text = values[3] as String;
    setState(() {
      _installedProfile = profile;
      _selectedProfile = profile ?? RuntimeProfile.python;
      _runtimeInstalled = profile != null;
      _installed = profile != null && values[1] as bool;
      _serviceStatus = serviceStatus;
      _panelReady = serviceStatus.isRunning;
      _autoRestart = serviceStatus.autoRestart;
      _notificationsGranted = values[4] as bool;
      _loading = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _refreshStatus();
    }
  }

  Future<void> _refreshStatus() async {
    final values = await Future.wait([
      _manager.installedRuntimeProfile(),
      _manager.hasProject(),
      LocalPanelHost.status(),
      LocalPanelHost.notificationsGranted(),
    ]);
    if (!mounted) return;
    final profile = values[0] as RuntimeProfile?;
    final serviceStatus = values[2] as LocalPanelStatus;
    setState(() {
      _installedProfile = profile;
      _runtimeInstalled = profile != null;
      _installed = profile != null && values[1] as bool;
      _serviceStatus = serviceStatus;
      _panelReady = serviceStatus.isRunning;
      _autoRestart = serviceStatus.autoRestart;
      _notificationsGranted = values[3] as bool;
    });
  }

  void _selectProfile(RuntimeProfile profile) {
    setState(() => _selectedProfile = profile);
  }

  String _profileName(RuntimeProfile? profile) => switch (profile) {
    RuntimeProfile.python => 'Python 基础镜像',
    RuntimeProfile.all => 'Full 预装镜像',
    null => '未安装',
  };

  String get _serviceStateLabel => switch (_serviceStatus.state) {
    LocalPanelState.stopped => _installed ? '已停止' : '未安装',
    LocalPanelState.starting => '正在启动',
    LocalPanelState.running => '运行中',
    LocalPanelState.retrying => '异常退出，正在恢复 ${_serviceStatus.restartAttempts}/3',
    LocalPanelState.crashed => '异常退出',
    LocalPanelState.failed => '启动失败',
    LocalPanelState.interrupted => '服务中断',
    LocalPanelState.unknown => _loading ? '正在检查状态' : '状态未知',
  };

  Color get _serviceStateColor => switch (_serviceStatus.state) {
    LocalPanelState.running => const Color(0xFF147D72),
    LocalPanelState.retrying ||
    LocalPanelState.starting => const Color(0xFF9A6700),
    LocalPanelState.crashed ||
    LocalPanelState.failed ||
    LocalPanelState.interrupted => const Color(0xFFB54732),
    _ => Theme.of(context).colorScheme.onSurfaceVariant,
  };

  Future<void> _setAutoRestart(bool enabled) async {
    await LocalPanelHost.setAutoRestart(enabled);
    await _refreshStatus();
  }

  Future<void> _openNotificationSettings() async {
    if (!_notificationsGranted) {
      await LocalPanelHost.requestNotificationPermission();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final granted = await LocalPanelHost.notificationsGranted();
      if (!mounted) return;
      setState(() => _notificationsGranted = granted);
      if (!granted) await LocalPanelHost.openAppSettings();
      return;
    }
    await LocalPanelHost.openAppSettings();
  }

  Future<void> _loadServiceLog() async {
    final text = await LocalPanelHost.readServiceLog();
    if (!mounted) return;
    setState(() => _logText = text);
  }

  void _openEnvironmentManager() {
    if (!_installed) return;
    if (!_panelReady) {
      _startPanel(openEnvironmentManager: true);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RemoteWebView(
          server: const PanelServer(
            name: '本机 FLS',
            url: 'http://127.0.0.1:5700',
          ),
          initialPath: '/panel/status',
          pageTitle: '运行环境管理',
        ),
      ),
    );
  }

  void _selectTab(_LocalTab tab) {
    setState(() => _tab = tab);
    if (tab == _LocalTab.diagnostics) _loadServiceLog();
  }

  Future<bool> _confirmRuntimeReplacement() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('更换基础容器镜像？'),
        content: const Text(
          '这会替换整个容器，并移除容器内后来安装的系统运行器。FLS 面板、设置、任务、日志和脚本保存在容器外，不会被替换。需要添加运行器时，优先使用 FLS 面板的运行环境管理。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('更换镜像'),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Future<File> _temporaryArchive(String name) async {
    final root = await _manager.root;
    await root.create(recursive: true);
    return File(
      p.join(
        root.path,
        '.$name-${DateTime.now().millisecondsSinceEpoch}.tar.gz',
      ),
    );
  }

  Future<void> _installOrUpdate({bool replaceRuntime = false}) async {
    final replacingRuntime =
        replaceRuntime &&
        _runtimeInstalled &&
        _selectedProfile != _installedProfile;
    if (replacingRuntime && !await _confirmRuntimeReplacement()) return;
    final cancellation = OperationCancellation();
    _cancellation = cancellation;
    setState(() {
      _installing = true;
      _error = null;
      _progress = 0;
      _phase = '检查设备运行时';
    });
    try {
      await _manager.saveGithubMirror(_mirrorController.text);
      if (_panelReady) await LocalPanelHost.stop();
      final runtimeProfile = _runtimeInstalled && !replacingRuntime
          ? _installedProfile!
          : _selectedProfile;
      if (!await _manager.hasRuntime(profile: runtimeProfile)) {
        final abis = await LocalPanelHost.supportedAbis();
        setState(() => _phase = '下载并校验 ${_profileName(runtimeProfile)}');
        await _manager.installRuntime(
          supportedAbis: abis,
          profile: runtimeProfile,
          githubMirror: _mirrorController.text,
          cancellation: cancellation,
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
        );
      }
      setState(() {
        _phase = '下载并安装 FLS 面板';
        _progress = 0;
      });
      await _manager.updatePanel(
        githubMirror: _mirrorController.text,
        cancellation: cancellation,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      setState(() {
        _phase = '启动本机面板';
        _progress = 0;
      });
      await _manager.startPanel(cancellation: cancellation);
      await _refreshStatus();
      if (mounted && _panelReady) _openLocalPanel();
    } catch (error) {
      if (mounted && error is! OperationCancelled) {
        setState(() => _error = error.toString());
      }
      try {
        await _refreshStatus();
      } catch (_) {}
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (mounted) {
        setState(() {
          _installing = false;
          if (cancellation.isCancelled) _phase = '已取消';
        });
      }
    }
  }

  Future<void> _importContainer() async {
    if (_installing) return;
    if (_runtimeInstalled && !await _confirmRuntimeReplacement()) return;
    final cancellation = OperationCancellation();
    _cancellation = cancellation;
    setState(() {
      _installing = true;
      _error = null;
      _phase = '选择容器文件';
      _progress = 0;
    });
    File? archive;
    try {
      final uri = await LocalFileBridge.pickContainer();
      if (uri == null) {
        if (mounted) setState(() => _phase = '已取消');
        return;
      }
      archive = await _temporaryArchive('fls-import');
      setState(() => _phase = '导入并校验容器');
      final copied = await LocalFileBridge.copyUriToPath(
        uri: uri,
        path: archive.path,
      );
      if (!copied) throw StateError('无法读取所选容器文件');
      cancellation.throwIfCancelled();
      if (_panelReady) await LocalPanelHost.stop();
      final profile = await _manager.importRuntime(
        archive,
        cancellation: cancellation,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      _selectedProfile = profile;
      await _refreshStatus();
    } catch (error) {
      if (mounted && error is! OperationCancelled) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (archive != null && await archive.exists()) await archive.delete();
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (mounted) {
        setState(() {
          _installing = false;
          if (cancellation.isCancelled) _phase = '已取消';
        });
      }
    }
  }

  Future<void> _exportContainer() async {
    if (_installing || !_runtimeInstalled) return;
    setState(() {
      _installing = true;
      _error = null;
      _phase = '准备导出容器';
      _progress = 0;
    });
    File? archive;
    try {
      archive = await _manager.exportRuntime();
      final profile = _installedProfile ?? RuntimeProfile.python;
      final saved = await LocalFileBridge.saveFile(
        path: archive.path,
        filename: 'fls-container-${profile.id}-arm64.tar.gz',
      );
      if (!saved) throw StateError('未选择导出位置');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (archive != null && await archive.exists()) await archive.delete();
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _togglePanel() async {
    if (_installing) return;
    if (_panelReady) {
      try {
        await LocalPanelHost.stop();
        await _refreshStatus();
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      }
      return;
    }

    await _startPanel();
  }

  Future<void> _startPanel({bool openEnvironmentManager = false}) async {
    if (_installing) return;
    final cancellation = OperationCancellation();
    _cancellation = cancellation;
    setState(() {
      _installing = true;
      _error = null;
      _phase = '启动本机面板';
      _progress = 0;
    });
    try {
      await _manager.startPanel(cancellation: cancellation);
      await _refreshStatus();
      if (mounted && _panelReady) {
        if (openEnvironmentManager) {
          _openEnvironmentManager();
        } else {
          _openLocalPanel();
        }
      }
    } catch (error) {
      if (mounted && error is! OperationCancelled) {
        setState(() => _error = error.toString());
      }
      try {
        await _refreshStatus();
      } catch (_) {}
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (mounted) {
        setState(() {
          _installing = false;
          if (cancellation.isCancelled) _phase = '已取消';
        });
      }
    }
  }

  void _cancelOperation() {
    final cancellation = _cancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    cancellation.cancel();
    if (mounted) setState(() {});
  }

  void _openLocalPanel() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RemoteWebView(
          server: PanelServer(name: '本机 FLS', url: 'http://127.0.0.1:5700'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          title: const Text('本机面板'),
          actions: [
            IconButton(
              tooltip: '刷新本机状态',
              onPressed: _refreshStatus,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SegmentedButton<_LocalTab>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: _LocalTab.overview,
                  icon: Icon(Icons.dashboard_outlined),
                  label: Text('运行'),
                ),
                ButtonSegment(
                  value: _LocalTab.environment,
                  icon: Icon(Icons.extension_outlined),
                  label: Text('环境'),
                ),
                ButtonSegment(
                  value: _LocalTab.diagnostics,
                  icon: Icon(Icons.monitor_heart_outlined),
                  label: Text('诊断'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) _selectTab(selection.first);
              },
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          sliver: SliverList(
            delegate: SliverChildListDelegate(_tabContent(context)),
          ),
        ),
      ],
    );
  }

  List<Widget> _tabContent(BuildContext context) {
    return [
      ..._operationFeedback(context),
      if (_tab == _LocalTab.overview) ..._overviewContent(context),
      if (_tab == _LocalTab.environment) ..._environmentContent(context),
      if (_tab == _LocalTab.diagnostics) ..._diagnosticsContent(context),
    ];
  }

  List<Widget> _operationFeedback(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return [
      if (_installing) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _phase,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                ),
                if (_cancellation != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _cancellation!.isCancelled
                          ? null
                          : _cancelOperation,
                      icon: const Icon(Icons.close),
                      label: Text(
                        _cancellation!.isCancelled ? '正在取消...' : '取消',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (_error != null) ...[
        Material(
          color: const Color(0xFFFFF0EC),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: Color(0xFFB54732)),
                const SizedBox(width: 10),
                Expanded(child: Text(_error!)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (_serviceStatus.state == LocalPanelState.failed && !_installing) ...[
        TextButton.icon(
          onPressed: () {
            _selectTab(_LocalTab.diagnostics);
            _loadServiceLog();
          },
          icon: const Icon(Icons.article_outlined),
          label: const Text('查看启动诊断'),
          style: TextButton.styleFrom(
            foregroundColor: colorScheme.error,
            alignment: Alignment.centerLeft,
          ),
        ),
        const SizedBox(height: 8),
      ],
    ];
  }

  List<Widget> _overviewContent(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 46,
                height: 46,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/fls_panel_icon.png',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'FLS 本机实例',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _loading ? '正在检查安装状态' : _serviceStateLabel,
                      style: TextStyle(color: _serviceStateColor, fontSize: 13),
                    ),
                    if (_panelReady) ...[
                      const SizedBox(height: 3),
                      Text(
                        'http://127.0.0.1:5700',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (_runtimeInstalled) ...[
                      const SizedBox(height: 3),
                      Text(
                        '基础镜像：${_profileName(_installedProfile)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  _panelReady ? Icons.check_circle : Icons.circle_outlined,
                  color: _panelReady
                      ? const Color(0xFF147D72)
                      : colorScheme.outline,
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (_installed)
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _installing ? null : _togglePanel,
                icon: Icon(_panelReady ? Icons.stop : Icons.play_arrow),
                label: Text(_panelReady ? '停止面板' : '启动面板'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _installing ? null : _installOrUpdate,
                icon: const Icon(Icons.system_update_alt),
                label: const Text('更新 FLS'),
              ),
            ),
          ],
        )
      else
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _installing || _loading ? null : _installOrUpdate,
            icon: const Icon(Icons.download),
            label: Text(_runtimeInstalled ? '安装 FLS 面板' : '安装本机 FLS'),
          ),
        ),
      if (_serviceStatus.state == LocalPanelState.crashed ||
          _serviceStatus.state == LocalPanelState.failed ||
          _serviceStatus.state == LocalPanelState.interrupted) ...[
        const SizedBox(height: 12),
        Text(
          '最后退出码：${_serviceStatus.exitCode?.toString() ?? '未知'} · 已尝试恢复 ${_serviceStatus.restartAttempts}/3 次',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    ];
  }

  List<Widget> _environmentContent(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('容器基础镜像', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 5),
              Text(
                _runtimeInstalled
                    ? '当前基础镜像：${_profileName(_installedProfile)}'
                    : '首次安装时选择预装环境；已安装后可在容器中继续安装其他运行器。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (!_runtimeInstalled) ...[
                const SizedBox(height: 12),
                SegmentedButton<RuntimeProfile>(
                  expandedInsets: EdgeInsets.zero,
                  segments: const [
                    ButtonSegment(
                      value: RuntimeProfile.python,
                      label: Text('Python 基础'),
                    ),
                    ButtonSegment(
                      value: RuntimeProfile.all,
                      label: Text('Full 预装'),
                    ),
                  ],
                  selected: {_selectedProfile},
                  onSelectionChanged: _installing
                      ? null
                      : (selection) {
                          if (selection.isNotEmpty) {
                            _selectProfile(selection.first);
                          }
                        },
                ),
                const SizedBox(height: 6),
                Text(
                  _selectedProfile == RuntimeProfile.python
                      ? '轻量容器，包含 Python；可通过 FLS 安装器后续添加环境。'
                      : '镜像预装常用 Linux 工具和多种脚本运行器。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_runtimeInstalled && _installed) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _installing ? null : _openEnvironmentManager,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('打开 FLS 运行环境安装器'),
                ),
                const SizedBox(height: 6),
                Text(
                  '安装命令会在当前容器内运行；例如 Python 基础容器也可以在面板的运行环境页面安装 Bash、Node.js、PHP 等。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_runtimeInstalled) ...[
                const SizedBox(height: 16),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('更换容器基础镜像'),
                  subtitle: const Text('可选操作，会替换整个容器'),
                  children: [
                    SegmentedButton<RuntimeProfile>(
                      expandedInsets: EdgeInsets.zero,
                      segments: const [
                        ButtonSegment(
                          value: RuntimeProfile.python,
                          label: Text('Python 基础'),
                        ),
                        ButtonSegment(
                          value: RuntimeProfile.all,
                          label: Text('Full 预装'),
                        ),
                      ],
                      selected: {_selectedProfile},
                      onSelectionChanged: _installing
                          ? null
                          : (selection) {
                              if (selection.isNotEmpty) {
                                _selectProfile(selection.first);
                              }
                            },
                    ),
                    if (_selectedProfile != _installedProfile) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _installing
                            ? null
                            : () => _installOrUpdate(replaceRuntime: true),
                        icon: const Icon(Icons.swap_horiz),
                        label: const Text('下载并更换基础镜像'),
                      ),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _mirrorController,
                enabled: !_installing,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'GitHub 加速源（可选）',
                  hintText: '留空使用官方地址；支持前缀或 %s 模板',
                  prefixIcon: Icon(Icons.bolt_outlined),
                ),
                onChanged: (value) =>
                    unawaited(_manager.saveGithubMirror(value)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _installing ? null : _importContainer,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('导入容器'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _installing || !_runtimeInstalled
                          ? null
                          : _exportContainer,
                      icon: const Icon(Icons.ios_share_outlined),
                      label: const Text('导出容器'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _diagnosticsContent(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return [
      Card(
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('异常退出后自动恢复'),
              subtitle: const Text('最多连续尝试 3 次；手动停止后不会恢复。需要显示常驻通知。'),
              value: _autoRestart,
              onChanged: _installed ? _setAutoRestart : null,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: Icon(
                _notificationsGranted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(_notificationsGranted ? '通知权限已允许' : '通知权限未允许'),
              subtitle: const Text('常驻运行状态和异常退出提示'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openNotificationSettings,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.battery_saver_outlined),
              title: const Text('后台运行设置'),
              subtitle: const Text('查看系统电池与应用后台限制'),
              trailing: const Icon(Icons.open_in_new),
              onTap: LocalPanelHost.openBatterySettings,
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: Text(
              '本机服务日志',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: '刷新日志',
            onPressed: _loadServiceLog,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 140, maxHeight: 320),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          child: SelectableText(
            _logText.isEmpty ? '点击刷新查看本机服务日志' : _logText,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Text('本机存储', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Card(
        child: Column(
          children: const [
            _StorageRow(label: '容器与 Python', path: 'fls/runtime'),
            Divider(height: 1, indent: 14, endIndent: 14),
            _StorageRow(label: 'FLS 面板程序', path: 'fls/project'),
            Divider(height: 1, indent: 14, endIndent: 14),
            _StorageRow(
              label: '任务、日志和脚本',
              path: 'fls/data · fls/log · fls/scripts',
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(
        '前台服务能提高运行优先级，但系统强制停止、厂商电池策略和 Doze 仍可能中断服务。',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
      ),
    ];
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              path,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

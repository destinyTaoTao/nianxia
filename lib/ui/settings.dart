import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import '../platform/organizer.dart';
import '../app/backup.dart';
import 'common.dart';
import 'recovery.dart';
import 'backup_password.dart';
import '../app/diagnostics.dart';
import '../app/capture_session_controller.dart';
import '../domain/backup_operation.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.book,
    this.models,
    required this.themeMode,
    required this.onTheme,
    this.modelsFirst = false,
    this.backupService,
    this.diagnostics,
    this.captureSession,
    this.startupNotice,
  });
  final bool modelsFirst;
  final BackupService? backupService;
  final LocalDiagnostics? diagnostics;
  final CaptureSessionController? captureSession;
  final String? startupNotice;
  final Notebook book;
  final LocalModels? models;
  final ThemeMode themeMode;
  final FutureOr<bool> Function(ThemeMode) onTheme;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final vault = KeyVault();
  final key = TextEditingController();
  bool configured = false;
  bool keyBusy = false;
  String? keyError;
  late ThemeMode mode = widget.themeMode;
  Key themeFieldKey = UniqueKey();
  bool themeBusy = false;
  final Map<String, bool> ready = {};
  late final backup =
      widget.backupService ??
      BackupService(widget.book, diagnostics: widget.diagnostics);
  bool busy = false;
  bool previewingDiagnostics = false;
  bool cancelRequested = false;
  void requestCancel() {
    cancelRequested = true;
    backup.cancelled = true;
    setState(() => status = '正在取消，请等待当前阶段结束');
  }

  double? progress;
  String? status;
  final Set<String> downloading = {};
  @override
  void initState() {
    super.initState();
    loadKey();
    loadModels();
    widget.models?.store.addListener(modelChanged);
  }

  Future<void> loadKey() async {
    try {
      final value = await vault.configured;
      if (mounted) {
        setState(() => configured = value);
      }
    } catch (_) {
      if (mounted) {
        setState(() => keyError = '设备安全存储不可用，云端整理保持关闭。');
      }
    }
  }

  void modelChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> loadModels() async {
    final models = widget.models;
    if (models == null) {
      return;
    }
    for (final m in models.store.models) {
      final value = await models.store.ready(m.id);
      if (mounted) {
        setState(() => ready[m.id] = value);
      }
    }
  }

  Future<void> download(String id) async {
    if (!downloading.add(id)) {
      return;
    }
    setState(() {});
    try {
      await widget.models!.store.download(id);
      await loadModels();
      widget.book.changed();
    } catch (_) {
      if (mounted) {
        notice(context, widget.models!.store.errors[id] ?? '模型下载失败，请重试。');
      }
    } finally {
      downloading.remove(id);
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> saveKey({bool clear = false}) async {
    setState(() => keyBusy = true);
    try {
      if (clear) {
        await vault.clear();
      } else {
        await vault.save(key.text);
      }
      if (!mounted) return;
      key.clear();
      await loadKey();
      if (mounted) {
        notice(context, clear ? '密钥已清除，云端整理已关闭' : '密钥已保存，每次发送前仍需确认');
      }
    } catch (e) {
      if (mounted) {
        notice(context, userError(e));
      }
    } finally {
      if (mounted) {
        setState(() => keyBusy = false);
      }
    }
  }

  void updateProgress(double value) {
    if (mounted) {
      setState(() => progress = value);
    }
  }

  Future<void> export() => exportChoice();
  Future<void> exportChoice({
    bool encrypted = false,
    bool readable = false,
  }) async {
    if (busy) return;
    cancelRequested = false;
    Uint8List? password;
    if (encrypted) {
      password = await requestBackupPassword(context, creating: true);
      if (password == null) return;
    } else if (!await confirm(
      context,
      readable ? '导出文本与音频（未加密）？' : '导出未加密备份？',
      readable
          ? '包含可阅读文本、原音频和追加来源信息；不用于完整恢复。选择云盘会使内容离开设备。'
          : '包含可读文字、原音频和记录关系。接下来选择保存或分享去向；选择云盘会使内容离开设备。凭证和模型不包含在内。',
      action: readable ? '生成导出' : '生成备份',
    )) {
      return;
    }
    if (!mounted || busy) {
      password?.fillRange(0, password.length, 0);
      return;
    }
    setState(() {
      busy = true;
      progress = 0;
      status = '正在生成${readable ? '可读导出' : '备份'}';
    });
    File? file;
    try {
      file = encrypted
          ? await backup.exportEncrypted(
              passwordUtf8: password!,
              progress: updateProgress,
            )
          : readable
          ? await backup.exportReadable(progress: updateProgress)
          : await backup.export(progress: updateProgress);
      if (!mounted) return;
      setState(() => status = '文件已生成，等待选择去向');
      await shareGenerated(
        file,
        encrypted
            ? '念下密码完整备份'
            : readable
            ? '念下文本与音频（未加密）'
            : '念下完整备份（未加密）',
      );
    } catch (e) {
      if (mounted) setState(() => status = backupError(e));
    } finally {
      password?.fillRange(0, password.length, 0);
      await cleanupExport(file);
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
  }

  String backupError(Object error) => error is BackupCipherFailure
      ? switch (error.kind) {
          BackupCipherFailureKind.authentication => '密码不正确，或备份已损坏。',
          BackupCipherFailureKind.cancelled => '操作已取消，原有记录保持不变。',
          BackupCipherFailureKind.resourceLimit => '此备份需要的资源超出当前支持范围，原有记录保持不变。',
          _ => '备份无法读取，请核对文件和可用空间。原有记录保持不变。',
        }
      : userError(error);
  Future<void> cleanupExport(File? file) async {
    try {
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {
      if (mounted) setState(() => status = '临时副本尚未清理，重新打开应用后将重试清理。');
    }
  }

  Future<void> shareGenerated(File file, String subject) async {
    if (cancelRequested || !mounted) {
      if (mounted) setState(() => status = '已取消导出，未打开分享页');
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: subject,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
    if (mounted) {
      setState(
        () => status = result.status == ShareResultStatus.dismissed
            ? '已取消分享，未确认保存到所选位置'
            : result.status == ShareResultStatus.success
            ? '文件已交给所选应用，请核对实际保存位置'
            : '已打开分享页，保存结果未确认',
      );
    }
  }

  Future<void> diagnosticExport() async {
    final diagnostics = widget.diagnostics;
    if (busy || diagnostics == null) return;
    cancelRequested = false;
    setState(() => busy = true);
    File? file;
    try {
      final preview = await diagnostics.previewExport();
      if (!mounted) return;
      if (!preview.available) {
        setState(() => status = '诊断暂不可用，记录和备份仍可正常使用。');
        return;
      }
      setState(() => previewingDiagnostics = true);
      final approved = await confirm(
        context,
        '诊断导出预览',
        '${preview.entries} 条事件，约 ${(preview.bytes / 1024).toStringAsFixed(1)} KB。\n时间范围：${preview.firstAt?.toLocal().toString().substring(0, 16) ?? '暂无事件'} 至 ${preview.lastAt?.toLocal().toString().substring(0, 16) ?? '暂无事件'}。省略 ${preview.dropped} 条高峰事件。\n包含：${preview.includedFields.join('、')}。\n不包含正文、查询、音频、密钥或密码。\n选择其他应用或云盘会使这些诊断信息离开设备。',
        action: '导出诊断',
      );
      if (!approved || !mounted || cancelRequested) return;
      setState(() => previewingDiagnostics = false);
      file = await diagnostics.export();
      if (!mounted) return;
      await shareGenerated(file, '念下诊断信息');
    } catch (e) {
      if (mounted) setState(() => status = userError(e));
    } finally {
      await cleanupExport(file);
      if (mounted) {
        setState(() {
          busy = false;
          previewingDiagnostics = false;
        });
      }
    }
  }

  Future<void> restore() async {
    if (busy) return;
    if (!await confirm(
      context,
      '从备份恢复？',
      '相同内容跳过，冲突保留副本，不覆盖已有记录。支持本应用的新旧 ZIP 备份；密码备份需要密码和本机的加密支持。大备份需要更多时间和设备空间。',
      action: '选择备份',
    )) {
      return;
    }
    if (!mounted || busy) return;
    cancelRequested = false;
    setState(() {
      busy = true;
      progress = null;
      status = '请选择备份文件';
    });
    try {
      final selected = await FilePicker.pickFile(type: FileType.any);
      if (!mounted) return;
      if (cancelRequested) {
        setState(() => status = '已取消恢复，原有记录保持不变。');
        return;
      }
      if (selected == null) {
        setState(() => status = '已取消选择备份');
        return;
      }
      if (selected.path == null) {
        throw const NotebookException('无法读取所选文件，请先将备份保存到设备后重试。');
      }
      setState(() {
        progress = 0;
        status = '正在校验备份';
      });
      RestoreReport result;
      Uint8List? password;
      try {
        try {
          result = await backup.restore(
            File(selected.path!),
            progress: updateProgress,
          );
        } on BackupPasswordRequired {
          if (backup.cipher == null) {
            throw const NotebookException('此版本暂未启用密码备份恢复，请保留文件，使用已支持的版本恢复。');
          }
          if (!mounted) return;
          password = await requestBackupPassword(context, creating: false);
          if (password == null || cancelRequested) {
            if (mounted) setState(() => status = '已取消恢复，原有记录保持不变。');
            return;
          }
          result = await backup.restore(
            File(selected.path!),
            passwordUtf8: password,
            progress: updateProgress,
          );
        }
      } finally {
        password?.fillRange(0, password.length, 0);
      }
      if (mounted) {
        setState(
          () => status =
              '恢复完成：新增 ${result.added}，跳过 ${result.skipped}，冲突 ${result.conflicts}。查找索引将在模型就绪后重建。',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => status = backupError(e));
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
  }

  @override
  void dispose() {
    cancelRequested = true;
    if (busy) backup.cancelled = true;
    widget.models?.store.removeListener(modelChanged);
    key.dispose();
    super.dispose();
  }

  List<Widget> modelSection(BuildContext context) => [
    PaperSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('离线模型', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            '首次下载需要联网，完成后可离线使用。不会发送你的录音或文字。',
            style: TextStyle(fontSize: 14, height: 1.6),
          ),
          if (widget.models == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('当前环境未接入模型，请使用文字记录和关键词查找。'),
            ),
          for (final m in widget.models?.store.models ?? [])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(switch (m.id) {
                    'sensevoice' => '语音转文字',
                    'bge' => '按意思查找',
                    _ => m.label,
                  }, style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    '下载约 ${(m.bytes / 1000000).toStringAsFixed(1)} MB',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  if (widget.models!.store.progress.containsKey(m.id)) ...[
                    LinearProgressIndicator(
                      value: widget.models!.store.progress[m.id],
                    ),
                    TextButton(
                      onPressed: () => widget.models!.store.cancel(m.id),
                      child: const Text('取消下载'),
                    ),
                  ] else if (ready[m.id] == true)
                    const Text('已就绪，可离线使用')
                  else if (!ready.containsKey(m.id))
                    const Text('正在检查本地模型…')
                  else
                    OutlinedButton.icon(
                      onPressed: downloading.contains(m.id)
                          ? null
                          : () => download(m.id),
                      icon: const Icon(Icons.download_outlined),
                      label: Text(downloading.contains(m.id) ? '正在校验' : '下载模型'),
                    ),
                  if (widget.models!.store.errors[m.id] != null)
                    Text(
                      widget.models!.store.errors[m.id]!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) {
        notice(context, '请等待当前备份操作完成，或先取消。');
      }
    },
    child: Scaffold(
      appBar: AppBar(title: Text(widget.modelsFirst ? '离线功能' : '设置')),
      body: ReadingWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (widget.modelsFirst) ...[
              ...modelSection(context),
              const SizedBox(height: 16),
            ],
            PaperSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('保存在这里', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  const Text(
                    '记录、音频、转写和查找保存在设备上，无需账号。模型下载完成后可离线记查。应用数据未声明加密；请保护设备访问权限。',
                  ),
                  const SizedBox(height: 28),
                  DropdownButtonFormField<ThemeMode>(
                    key: themeFieldKey,
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: '外观'),
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('跟随系统'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('浅色'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('深色'),
                      ),
                    ],
                    onChanged: themeBusy
                        ? null
                        : (v) async {
                            if (v == null) return;
                            setState(() {
                              themeBusy = true;
                              // Keep showing the persisted selection until saving succeeds.
                              themeFieldKey = UniqueKey();
                            });
                            var saved = false;
                            try {
                              saved = await widget.onTheme(v);
                            } catch (_) {
                              // The previous selection stays active after a storage failure.
                            }
                            if (!mounted) return;
                            setState(() {
                              if (saved) mode = v;
                              themeBusy = false;
                              themeFieldKey = UniqueKey();
                            });
                            if (!saved && context.mounted) {
                              notice(context, '主题设置未保存，请重试。');
                            }
                          },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PaperSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('快捷呼出', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    Platform.isIOS
                        ? '在系统“快捷指令”中选择念下的“记一下”，可绑定操作按钮。呼出后直接进入录音胶囊；系统可能要求解锁。'
                        : '下拉系统快捷设置，编辑并添加“记一下”磁贴，即可直接呼出录音胶囊。AI 键若支持应用快捷动作或打开链接，可绑定“记一下”；是否可选取决于手机系统。',
                  ),
                  const SizedBox(height: 8),
                  const Text('只在主动呼出后录音。切换应用或锁屏会停止并尝试保存，不在后台持续监听。'),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        const ClipboardData(text: 'nianxia://capture'),
                      );
                      if (context.mounted) {
                        notice(context, '录音链接已复制，可用于系统快捷指令的“打开 URL”动作。');
                      }
                    },
                    icon: const Icon(Icons.link_rounded),
                    label: const Text('复制录音快捷链接'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (!widget.modelsFirst) ...[
              ...modelSection(context),
              const SizedBox(height: 16),
            ],
            PaperSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '可选云端整理',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    configured
                        ? '已配置 DeepSeek 密钥。每次仅在你确认后发送单条正文。'
                        : '默认关闭。配置自己的 DeepSeek API Key 后，才可逐次确认整理。',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: key,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'DeepSeek API Key',
                      hintText: '仅保存在设备安全存储',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton(
                        onPressed: keyBusy ? null : () => saveKey(),
                        child: const Text('保存密钥'),
                      ),
                      if (configured)
                        TextButton(
                          onPressed: keyBusy
                              ? null
                              : () => saveKey(clear: true),
                          child: const Text('清除密钥'),
                        ),
                    ],
                  ),
                  if (keyError != null) Text(keyError!),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PaperSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('导出与恢复', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    backup.cipher != null
                        ? '完整备份使用密码保护；忘记密码无法找回。可读导出未加密。两者均不包含模型、密钥或查询音频。'
                        : '此版本暂未启用密码备份。现有完整备份与可读导出均未加密，包含文字和原音频；不包含模型、密钥或查询音频。',
                    style: const TextStyle(fontSize: 14, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: busy || backup.cipher == null
                            ? null
                            : () => exportChoice(encrypted: true),
                        icon: const Icon(Icons.lock_outline_rounded),
                        label: const Text('密码完整备份'),
                      ),
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => exportChoice(readable: true),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('导出文本与音频（未加密）'),
                      ),
                      if (backup.cipher == null)
                        OutlinedButton.icon(
                          onPressed: busy ? null : export,
                          icon: const Icon(Icons.ios_share_outlined),
                          label: const Text('完整备份（未加密）'),
                        ),
                      OutlinedButton.icon(
                        onPressed: busy ? null : restore,
                        icon: const Icon(Icons.restore_outlined),
                        label: const Text('恢复备份'),
                      ),
                    ],
                  ),
                  if (busy && !previewingDiagnostics) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: progress),
                    TextButton(
                      onPressed: requestCancel,
                      child: const Text('取消操作'),
                    ),
                  ],
                  if (status != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Semantics(liveRegion: true, child: Text(status!)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('待恢复与隔离资料'),
              subtitle: const Text('试听、导出或确认丢弃尚未保存的片段'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => RecoveryScreen(
                    book: widget.book,
                    captureSession: widget.captureSession,
                  ),
                ),
              ),
            ),
            if (widget.diagnostics != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('本地诊断'),
                subtitle: const Text('只含阶段、耗时和安全错误码，保留最多 7 天'),
                trailing: TextButton(
                  onPressed: busy ? null : diagnosticExport,
                  child: const Text('预览诊断导出'),
                ),
              ),
            if (widget.startupNotice != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(widget.startupNotice!),
              ),
            if (widget.book.recoveryWarnings > 0)
              Text(
                '有 ${widget.book.recoveryWarnings} 个恢复标记无法读取，文件已保留。请先导出可用记录，再排查。',
              ),
            const SizedBox(height: 32),
            TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: '念下',
                applicationVersion: '0.1.0',
                applicationLegalese: 'SenseVoice 模型：FunASR 模型许可；sherpa-onnx：Apache-2.0；BGE：MIT。模型版本与文件校验值见随应用发布的清单。',
              ),
              child: const Text('版本与开源许可'),
            ),
          ],
        ),
      ),
    ),
  );
}

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import '../platform/organizer.dart';
import '../data/backup.dart';
import 'common.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.book,
    this.models,
    required this.themeMode,
    required this.onTheme,
    this.modelsFirst = false,
  });
  final bool modelsFirst;
  final Notebook book;
  final LocalModels? models;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onTheme;
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
  final Map<String, bool> ready = {};
  late final backup = BackupService(widget.book);
  bool busy = false;
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

  Future<void> export() async {
    if (!await confirm(
      context,
      '导出未加密备份？',
      '包含可读文字、原音频和记录关系。接下来选择保存或分享去向；选择云盘会使内容离开设备。凭证和模型不包含在内。',
      action: '生成备份',
    )) {
      return;
    }
    setState(() {
      busy = true;
      progress = 0;
      status = '正在生成备份';
    });
    try {
      final file = await backup.export(progress: updateProgress);
      if (!mounted) {
        return;
      }
      setState(() => status = '备份已生成，等待选择去向');
      final box = context.findRenderObject() as RenderBox?;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: '念下备份（未加密）',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      if (mounted) {
        setState(
          () => status = result.status == ShareResultStatus.success
              ? '备份已交给所选应用，请核对保存位置'
              : result.status == ShareResultStatus.dismissed
              ? '已取消分享，未确认保存到所选位置'
              : '已打开分享页，保存结果未确认',
        );
      }
      // Keep no unbounded local export history. A later share can regenerate.
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      if (mounted) {
        setState(() => status = userError(e));
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

  Future<void> restore() async {
    if (!await confirm(
      context,
      '从备份恢复？',
      '相同内容跳过，冲突保留副本，不覆盖已有记录。支持本应用生成的未加密 ZIP，最大 512 MB。',
      action: '选择备份',
    )) {
      return;
    }
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (selected == null || selected.path == null || !mounted) {
      return;
    }
    setState(() {
      busy = true;
      progress = 0;
      status = '正在校验备份';
    });
    try {
      final result = await backup.restore(
        File(selected.path!),
        progress: updateProgress,
      );
      if (mounted) {
        setState(
          () => status =
              '恢复完成：新增 ${result.added}，跳过 ${result.skipped}，冲突 ${result.conflicts}。查找索引将在模型就绪后重建。',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => status = userError(e));
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
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => mode = v);
                        widget.onTheme(v);
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
                  const Text(
                    '备份未加密，包含可读文本与原音频；不包含模型、密钥或查询音频。系统分享和同步日历可能使所选内容离开设备。',
                    style: TextStyle(fontSize: 14, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton.icon(
                        onPressed: busy ? null : export,
                        icon: const Icon(Icons.ios_share_outlined),
                        label: const Text('导出备份'),
                      ),
                      OutlinedButton.icon(
                        onPressed: busy ? null : restore,
                        icon: const Icon(Icons.restore_outlined),
                        label: const Text('恢复备份'),
                      ),
                    ],
                  ),
                  if (busy) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: progress),
                    TextButton(
                      onPressed: () {
                        backup.cancelled = true;
                        setState(() => status = '正在取消，请等待当前校验结束');
                      },
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
            if (widget.book.recoveryDrafts.isNotEmpty) ...[
              const SizedBox(height: 28),
              Text('待恢复录音', style: Theme.of(context).textTheme.titleMedium),
              const Text('这些片段未能自动保存。原记录已删除时，可由你决定保存为独立记录。'),
              for (final draft in List<CaptureDraft>.of(
                widget.book.recoveryDrafts,
              ))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(draft.createdAt.toLocal().toString()),
                  subtitle: const Text('保存结果尚未确认'),
                  trailing: PopupMenuButton<String>(
                    tooltip: '恢复录音操作',
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'recover',
                        child: Text('尝试恢复为独立记录'),
                      ),
                      const PopupMenuItem(
                        value: 'discard',
                        child: Text('丢弃片段'),
                      ),
                    ],
                    onSelected: (v) async {
                      try {
                        if (v == 'discard') {
                          if (!await confirm(
                            context,
                            '丢弃待恢复片段？',
                            '此音频还没有保存为记录，丢弃后无法恢复。',
                            action: '丢弃',
                          )) {
                            return;
                          }
                          await widget.book.cancelCapture(draft);
                        } else {
                          await widget.book.finishCapture(
                            draft,
                            recovering: true,
                            standalone: true,
                          );
                        }
                        if (mounted) {
                          setState(() {});
                        }
                      } catch (e) {
                        if (context.mounted) {
                          notice(context, userError(e));
                        }
                      }
                    },
                  ),
                ),
            ],
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

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

Future<Uint8List?> requestBackupPassword(
  BuildContext context, {
  required bool creating,
}) async {
  final value = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PasswordDialog(creating: creating),
  );
  return value == null ? null : Uint8List.fromList(utf8.encode(value));
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.creating});
  final bool creating;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final password = TextEditingController(),
      confirmation = TextEditingController();
  String? error;
  void submit() {
    final text = password.text;
    if (text.isEmpty) {
      setState(() => error = '请输入备份密码。');
      return;
    }
    if (widget.creating && text.runes.length < 12) {
      setState(() => error = '新密码至少需要 12 个字符。');
      return;
    }
    if (widget.creating && text != confirmation.text) {
      setState(() => error = '两次密码不一致，请重新确认。');
      return;
    }
    Navigator.pop(context, text); // Preserve whitespace and Unicode exactly.
  }

  @override
  void dispose() {
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.creating ? '设置备份密码' : '输入备份密码'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.creating
                ? '密码由你保管，忘记后无法找回此备份。请使用至少 12 个字符的独立密码。下一步选择保存位置，云盘会使备份离开设备。'
                : '密码不正确或文件损坏均无法恢复。原有记录会保留。',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('backup-password'),
            controller: password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            autofillHints: const [],
            maxLength: widget.creating ? 512 : null,
            decoration: const InputDecoration(labelText: '备份密码'),
            textInputAction: widget.creating
                ? TextInputAction.next
                : TextInputAction.done,
            onSubmitted: widget.creating ? null : (_) => submit(),
          ),
          if (widget.creating)
            TextField(
              key: const Key('backup-password-confirmation'),
              controller: confirmation,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              autofillHints: const [],
              maxLength: 512,
              decoration: const InputDecoration(labelText: '再次输入密码'),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => submit(),
            ),
          if (error != null) Semantics(liveRegion: true, child: Text(error!)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: submit,
        child: Text(widget.creating ? '生成密码备份' : '继续恢复'),
      ),
    ],
  );
}

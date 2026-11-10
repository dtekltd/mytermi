import 'package:flutter/material.dart';

import '../theme.dart';

/// Round icon button used in page headers.
class CircleButton extends StatelessWidget {
  const CircleButton({super.key, required this.icon, required this.onPressed, this.tooltip});
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: c.surface,
        shape: CircleBorder(side: BorderSide(color: c.border, width: 0.6)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(width: 50, height: 50, child: Icon(icon, size: 26, color: c.text)),
        ),
      ),
    );
  }
}

/// Rounded-square button used in the terminal's bottom bars.
class SquareButton extends StatelessWidget {
  const SquareButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.size = 44,
    this.color,
    this.tooltip,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: color ?? context.colors.surface,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        canRequestFocus: false,
        onTap: onPressed,
        child: SizedBox(width: size, height: size, child: Center(child: child)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Centered title + subtitle with optional buttons left / right.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.leading, this.actions = const []});
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                if (subtitle != null)
                  Text(subtitle!, style: TextStyle(fontSize: 14, color: c.textDim)),
              ],
            ),
            if (leading != null) Align(alignment: Alignment.centerLeft, child: leading),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 10), a],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Hosts ───────" style section label.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Row(children: [
        Text(text, style: TextStyle(color: c.textDim, fontWeight: FontWeight.w600, fontSize: 15)),
        const SizedBox(width: 12),
        const Expanded(child: Divider()),
      ]),
    );
  }
}

/// Rounded card row: coloured icon tile, title, subtitle, trailing widget.
class ItemCard extends StatelessWidget {
  const ItemCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.iconColor,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            child: Row(children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: iconColor ?? context.colors.orange, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, color: subtitleColor ?? c.textDim)),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ]),
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 120),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: c.textDim),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: c.textDim, height: 1.4)),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      ),
    );
  }
}

/// Dialog with one text field. Returns the text, or null if cancelled.
/// The controller lives in the dialog's State so it's only disposed after the
/// close animation (disposing it right after `showDialog` returns crashes).
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String confirmText,
  String initialText = '',
  String? labelText,
  String? hintText,
  bool obscure = false,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(
        title: title,
        confirmText: confirmText,
        initialText: initialText,
        labelText: labelText,
        hintText: hintText,
        obscure: obscure,
      ),
    );

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.confirmText,
    required this.initialText,
    this.labelText,
    this.hintText,
    required this.obscure,
  });
  final String title, confirmText, initialText;
  final String? labelText, hintText;
  final bool obscure;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _ctl = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _ctl,
          obscureText: widget.obscure,
          autofocus: true,
          autocorrect: !widget.obscure,
          decoration: InputDecoration(labelText: widget.labelText, hintText: widget.hintText),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(context, _ctl.text), child: Text(widget.confirmText)),
        ],
      );
}

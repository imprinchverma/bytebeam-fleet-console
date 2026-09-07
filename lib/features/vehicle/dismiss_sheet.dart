import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

const dismissReasons = [
  'I am on it',
  'Wrong alert',
  'Something else…',
];

Future<String?> showDismissReasonSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: FleetTheme.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  'Dismiss alert',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              for (final reason in dismissReasons)
                ListTile(
                  title: Text(reason),
                  onTap: () => Navigator.pop(context, reason),
                ),
            ],
          ),
        ),
      );
    },
  );
}

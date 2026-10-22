import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../widgets/pill_choice.dart';
import 'glossary_screen.dart';

/// Theme and handedness, both applied as soon as they're picked (spec
/// feature-dark-theme).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          _section(context, '外觀'),
          _card(
            context,
            title: '主題',
            child: PillChoice<ThemeMode>(
              options: const [
                (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
                (ThemeMode.light, '淺色', Icons.light_mode_outlined),
                (ThemeMode.system, '跟隨系統', Icons.contrast),
              ],
              selected: settings.themeMode,
              onChanged: settings.setThemeMode,
            ),
          ),
          _section(context, '操作'),
          _card(
            context,
            title: '慣用手',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PillChoice<Handedness>(
                  options: const [
                    (Handedness.left, '左手', Icons.front_hand_outlined),
                    (Handedness.right, '右手', Icons.front_hand_outlined),
                  ],
                  selected: settings.handedness,
                  onChanged: settings.setHandedness,
                ),
                const SizedBox(height: 8),
                Text('錄音、停止、標記重點、播放等常用按鈕會放在這一側。', style: muted),
              ],
            ),
          ),
          _section(context, '其他'),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundColor: theme.colorScheme.primary,
                child: const Icon(Icons.menu_book_outlined, size: 20),
              ),
              title: const Text('詞庫'),
              subtitle: Text('人名、專有名詞的正確寫法', style: muted),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const GlossaryScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 16, 6, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        letterSpacing: 0.5,
      ),
    ),
  );

  Widget _card(BuildContext context, {required String title, required Widget child}) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

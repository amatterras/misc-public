import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_application_1/app/app_state.dart';
import 'package:flutter_application_1/app/theme.dart';
import 'package:flutter_application_1/data/models/canvas_models.dart';
import 'package:flutter_application_1/data/repositories/canvas_repository.dart';
import 'package:flutter_application_1/data/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'light and dark roles switch without changing stored drawing colors',
    () {
      final originalMode = AppColors.mode;
      addTearDown(() => AppColors.mode = originalMode);
      final stroke = StrokeItem(
        id: 'red-stroke',
        points: const [StrokePoint(0, 0), StrokePoint(5, 5)],
        color: const Color(0xCCFF3B30),
        strokeWidth: 2,
      );
      final stored = stroke.toJson();

      AppColors.mode = ThemeMode.dark;
      expect(AppColors.background, const Color(0xFF191A1D));
      expect(AppColors.accent, const Color(0xFF789BB5));
      final dark = buildAppTheme(brightness: Brightness.dark);
      expect(dark.brightness, Brightness.dark);

      AppColors.mode = ThemeMode.light;
      // The one interface palette, light variant ("porcelain & ink").
      expect(AppColors.background, AppColors.background);
      expect(AppColors.background, const Color(0xFFF3F5F9));
      expect(AppColors.canvas, AppColors.canvas);
      expect(AppColors.text, AppColors.text);
      expect(AppColors.text, const Color(0xFF181C25));
      expect(
        buildAppTheme(brightness: Brightness.light).brightness,
        Brightness.light,
      );
      final light = AppColors.text.computeLuminance() + .05;
      final backgroundLuminance = AppColors.background.computeLuminance() + .05;
      final contrast = light > backgroundLuminance
          ? light / backgroundLuminance
          : backgroundLuminance / light;
      expect(contrast, greaterThan(7));

      final restored = StrokeItem.fromJson(stored);
      expect(restored.color, const Color(0xCCFF3B30));
      expect(
        InkColors.library.where((s) => s.id == 'bright-red'),
        hasLength(1),
      );
      expect(InkColors.byId('steel-blue')?.color, InkColors.steelBlue);
    },
  );

  test('theme mode preference persists and notifies the root', () async {
    final dir = await Directory.systemTemp.createTemp('theapp_theme_mode_');
    final workspace = Workspace(dir);
    final state = AppState(
      canvases: FileCanvasRepository(workspace.store),
      settings: SettingsRepository(workspace.store),
      workspace: workspace,
      enableSendTo: false,
    );
    try {
      await state.init();
      await state.setThemeMode('light');
      expect(state.themeModePreference.value, 'light');
      final reopened = SettingsRepository(workspace.store);
      await reopened.load();
      expect(reopened.get<String>('themeMode'), 'light');
    } finally {
      state.dispose();
      workspace.dispose();
      await dir.delete(recursive: true);
    }
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import '../../data/models/canvas_models.dart';

/// Native Windows handwriting recognition via Windows Ink, using the stored
/// stroke points rather than raster OCR. No cloud service or package is used.
class WindowsInkOcr {
  static bool get available =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  static Map<String, Object> payload(
    Iterable<StrokeItem> strokes,
    Rect dayRect,
  ) => {
    'strokes': [
      for (final stroke in strokes)
        if (stroke.points.length >= 2 && stroke.bounds.overlaps(dayRect))
          {
            'points': [
              for (final point in stroke.points)
                [
                  point.x - dayRect.left,
                  point.y - dayRect.top,
                  point.pressure.clamp(0.05, 1.0),
                ],
            ],
          },
    ],
  };

  static const _script = r'''
param([string]$Path)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Runtime.WindowsRuntime
try {
  $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $inkPointType = [Windows.UI.Input.Inking.InkPoint, Windows.UI, ContentType=WindowsRuntime]
  $inkBuilderType = [Windows.UI.Input.Inking.InkStrokeBuilder, Windows.UI, ContentType=WindowsRuntime]
  $containerType = [Windows.UI.Input.Inking.InkStrokeContainer, Windows.UI, ContentType=WindowsRuntime]
  $recognizerType = [Windows.UI.Input.Inking.InkRecognizerContainer, Windows.UI, ContentType=WindowsRuntime]
  $pointConstructor = $inkPointType.GetConstructors() | Where-Object { $_.GetParameters().Count -eq 2 } | Select-Object -First 1
  $pointType = $pointConstructor.GetParameters()[0].ParameterType
  $inkPointsType = [System.Collections.Generic.List[Windows.UI.Input.Inking.InkPoint]]
  $builder = [Activator]::CreateInstance($inkBuilderType)
  $container = [Activator]::CreateInstance($containerType)
  foreach ($stroke in $data.strokes) {
    $points = [Activator]::CreateInstance($inkPointsType)
    foreach ($sample in $stroke.points) {
      $position = [Activator]::CreateInstance($pointType)
      $position.X = [double]$sample[0]
      $position.Y = [double]$sample[1]
      $inkPoint = $pointConstructor.Invoke([object[]]@($position, [single]$sample[2]))
      $points.Add($inkPoint)
    }
    if ($points.Count -ge 2) {
      $container.AddStroke($builder.CreateStrokeFromInkPoints($points, [System.Numerics.Matrix3x2]::Identity))
    }
  }
  if ($container.GetStrokes().Count -eq 0) { exit 2 }
  $recognizer = [Activator]::CreateInstance($recognizerType)
  if ($recognizer.GetRecognizers().Count -eq 0) { exit 3 }
  $operation = $recognizer.RecognizeAsync($container, [Windows.UI.Input.Inking.InkRecognitionTarget]::All)
  $method = $recognizerType.GetMethods() | Where-Object { $_.Name -eq 'RecognizeAsync' -and $_.GetParameters().Count -eq 2 } | Select-Object -First 1
  $resultType = $method.ReturnType.GenericTypeArguments[0]
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
  $null = $task.Wait(-1)
  $words = [System.Collections.Generic.List[string]]::new()
  foreach ($result in $task.Result) {
    $candidates = $result.GetTextCandidates()
    if ($candidates.Count -gt 0) { $words.Add([string]$candidates[0]) }
  }
  [Console]::Out.Write(($words -join ' '))
} catch {
  [Console]::Error.WriteLine(('WINRT:' + $_.Exception.HResult.ToString('X8')))
  exit 5
}
''';

  static Future<String> recognize(
    Iterable<StrokeItem> strokes,
    Rect dayRect,
  ) async {
    final data = payload(strokes, dayRect);
    if ((data['strokes']! as List).isEmpty) return '';
    final folder = await Directory.systemTemp.createTemp('theapp-ink-ocr-');
    try {
      final input = File('${folder.path}${Platform.pathSeparator}strokes.json');
      await input.writeAsString(jsonEncode(data), flush: true);
      final script = File(
        '${folder.path}${Platform.pathSeparator}recognize-ink.ps1',
      );
      await script.writeAsString(_script, flush: true);
      final process = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        input.path,
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (code == 0) return (await output).trim();
      final diagnostic = await errors;
      final hresult = RegExp(r'WINRT:([0-9A-Fa-f]{8})').firstMatch(diagnostic);
      if (hresult != null) {
        throw StateError(
          'Windows handwriting recognition failed (0x${hresult.group(1)}).',
        );
      }
      throw StateError(
        code == 3
            ? 'No Windows handwriting recognizer is installed for the enabled languages.'
            : code == 2
            ? 'No usable ink strokes were available for recognition.'
            : 'Windows handwriting recognition is unavailable (exit code $code).',
      );
    } finally {
      await folder.delete(recursive: true).catchError((_) => folder);
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'download_service.dart';

class ModelDownloadState {
  final Map<String, double> progressMap;
  final Set<String> downloadedModels;
  final Set<String> activeDownloads;

  ModelDownloadState({
    this.progressMap = const {},
    this.downloadedModels = const {},
    this.activeDownloads = const {},
  });

  ModelDownloadState copyWith({
    Map<String, double>? progressMap,
    Set<String>? downloadedModels,
    Set<String>? activeDownloads,
  }) {
    return ModelDownloadState(
      progressMap: progressMap ?? this.progressMap,
      downloadedModels: downloadedModels ?? this.downloadedModels,
      activeDownloads: activeDownloads ?? this.activeDownloads,
    );
  }
}

class ModelDownloadNotifier extends StateNotifier<ModelDownloadState> {
  final DownloadService _service = DownloadService();

  ModelDownloadNotifier() : super(ModelDownloadState());

  Future<void> startDownload(GemmaModel model) async {
    state = state.copyWith(
      activeDownloads: {...state.activeDownloads, model.name},
      progressMap: {
        ...state.progressMap,
        model.name: state.progressMap[model.name] ?? 0.01,
      },
    );
    
    try {
      await _service.downloadModel(model, (progress) {
        if ((progress - (state.progressMap[model.name] ?? 0)).abs() > 0.01) {
          state = state.copyWith(
            progressMap: {
              ...state.progressMap,
              model.name: progress,
            },
          );
        }
      });
      
      state = state.copyWith(
        activeDownloads: state.activeDownloads.where((e) => e != model.name).toSet(),
        downloadedModels: {...state.downloadedModels, model.name},
        progressMap: {
          ...state.progressMap,
          model.name: 1.0,
        },
      );
    } catch (e) {
      print("Download error: $e");
      state = state.copyWith(
        activeDownloads: state.activeDownloads.where((e) => e != model.name).toSet(),
        progressMap: {
          ...state.progressMap,
          model.name: state.progressMap[model.name] ?? 0.0,
        },
      );
      rethrow;
    }
  }

  void updateDownloadedStatus(List<GemmaModel> models) async {
    final downloaded = <String>{};
    final progressMap = <String, double>{};
    
    for (var model in models) {
      if (await _service.checkDownloaded(model)) {
        downloaded.add(model.name);
        progressMap[model.name] = 1.0;
      } else {
        final progress = await _service.getDownloadProgress(model);
        if (progress > 0) {
          progressMap[model.name] = progress;
        }
      }
    }
    
    state = state.copyWith(
      downloadedModels: downloaded,
      progressMap: progressMap,
    );
  }
}

final modelDownloadProvider = StateNotifierProvider<ModelDownloadNotifier, ModelDownloadState>((ref) {
  return ModelDownloadNotifier();
});

class ThemeNotifier extends StateNotifier<ThemeMode> {
  ThemeNotifier() : super(ThemeMode.light);

  void toggleTheme(bool isDark) {
    state = isDark ? ThemeMode.dark : ThemeMode.light;
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeMode>((ref) {
  return ThemeNotifier();
});

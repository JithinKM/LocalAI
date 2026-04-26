import 'dart:async';
import 'dart:io';
import 'package:llamadart/llamadart.dart';
import 'llm_service_interface.dart';

class GemmaService implements LlmService {
  LlamaEngine? _engine;
  LlamaBackend? _backend;
  
  @override
  Future<void> loadModel(String path) async {
    try {
      // Full teardown of previous model
      await unloadModel();
      
      // Initialize backend and engine
      _backend = LlamaBackend();
      _engine = LlamaEngine(_backend!);
      
      // Use optimized parameters from the reference project
      final params = ModelParams(
        contextSize: Platform.isAndroid ? 1024 : 2048,
        gpuLayers: 20, // Reasonable default for Pixel 6a
        preferredBackend: GpuBackend.vulkan, // Standard for Android GenAI
        numberOfThreads: Platform.numberOfProcessors > 4 ? 4 : 0,
        numberOfThreadsBatch: Platform.numberOfProcessors > 4 ? 4 : 0,
      );

      await _engine!.loadModel(path, modelParams: params);
      print("Llama model loaded successfully from $path");
    } catch (e) {
      print("Failed to load Llama model: $e");
      await unloadModel();
      rethrow;
    }
  }

  @override
  Stream<String> generateResponse(String prompt) async* {
    if (_engine == null) {
      yield "Error: No model loaded.";
      return;
    }

    try {
      // Use a basic ChatML-like prompt template
      final fullPrompt = "<|user|>\n$prompt\n<|end|>\n<|assistant|>\n";
      
      String accumulated = "";
      await for (final token in _engine!.generate(fullPrompt)) {
        accumulated += token;
        // Clean up stop patterns
        if (accumulated.contains("<|end|>") || accumulated.contains("<|user|>")) {
          break;
        }
        yield accumulated;
      }
    } catch (e) {
      yield "Error during generation: $e";
    }
  }

  @override
  Future<void> unloadModel() async {
    if (_engine != null) {
      try {
        await _engine!.dispose();
      } catch (_) {}
      _engine = null;
    }
    _backend = null;
  }
}

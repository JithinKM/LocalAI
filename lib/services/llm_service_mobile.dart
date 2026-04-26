import 'dart:async';
import 'dart:io';
import 'package:llamadart/llamadart.dart';
import 'llm_service_interface.dart';

class GemmaService implements LlmService {
  LlamaEngine? _engine;
  LlamaBackend? _backend;
  
  @override
  Future<void> loadModel(String path, {int contextSize = 1024}) async {
    try {
      // Full teardown of previous model
      await unloadModel();
      
      // Initialize backend and engine
      _backend = LlamaBackend();
      _engine = LlamaEngine(_backend!);
      
      // Use optimized parameters for maximum compatibility
      final params = ModelParams(
        contextSize: contextSize,
        gpuLayers: 0, // Disable GPU layers by default for maximum stability
        preferredBackend: GpuBackend.cpu, 
        numberOfThreads: Platform.numberOfProcessors > 4 ? 4 : 0,
        numberOfThreadsBatch: 0, // Let engine decide
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
      String accumulated = "";
      await for (final token in _engine!.generate(prompt)) {
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

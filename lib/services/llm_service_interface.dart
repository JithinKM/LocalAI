import 'dart:async';

abstract class LlmService {
  Future<void> loadModel(String path, {int contextSize = 1024});
  Stream<String> generateResponse(String prompt);
  Future<void> unloadModel();
}

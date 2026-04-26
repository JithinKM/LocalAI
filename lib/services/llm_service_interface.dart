import 'dart:async';

abstract class LlmService {
  Future<void> loadModel(String path);
  Stream<String> generateResponse(String prompt);
  Future<void> unloadModel();
}

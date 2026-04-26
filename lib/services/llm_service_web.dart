import 'dart:async';
import 'dart:js_interop';
import 'llm_service_interface.dart';

@JS('window.loadWebModel')
external JSPromise<JSBoolean> _loadWebModel(JSString path);

@JS('window.generateWebResponse')
external JSPromise<JSString> _generateWebResponse(JSString prompt);

class GemmaService implements LlmService {
  @override
  Future<void> loadModel(String path) async {
    await _loadWebModel(path.toJS).toDart;
  }

  @override
  Stream<String> generateResponse(String prompt) async* {
    try {
      final JSString response = await _generateWebResponse(prompt.toJS).toDart;
      final String fullResponse = response.toDart;
      
      final tokens = fullResponse.split(' ');
      String current = "";
      for (var token in tokens) {
        current += "$token ";
        yield current.trim();
        await Future.delayed(const Duration(milliseconds: 30));
      }
    } catch (e) {
      yield "Error: ${e.toString()}";
    }
  }

  @override
  Future<void> unloadModel() async {
    // Web cleanup if needed
  }
}

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:path_provider/path_provider.dart';

class GemmaModel {
  final String name;
  final String version;
  final String url;
  final String size;
  final int sizeBytes;
  bool isDownloaded = false;
  double downloadProgress = 0;

  GemmaModel({
    required this.name,
    required this.version,
    required this.url,
    required this.size,
    required this.sizeBytes,
  });
}

class DownloadService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 60),
    followRedirects: true,
  ));

  DownloadService() {
    // Bypass SSL certificate verification for the demo
    (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
      return client;
    };
  }
  
  static final List<GemmaModel> availableModels = [
    GemmaModel(
      name: "Gemma 2 2B (Abliterated)",
      version: "UNCENSORED",
      url: "https://huggingface.co/bartowski/gemma-2-2b-it-abliterated-GGUF/resolve/main/gemma-2-2b-it-abliterated-Q4_K_M.gguf",
      size: "1.6 GB",
      sizeBytes: 1600000000, // Approximate, will be refined on first chunk
    ),
    GemmaModel(
      name: "Gemma 4 E4B (Heretic)",
      version: "ULTRA UNCENSORED",
      url: "https://huggingface.co/llmfan46/gemma-4-E4B-it-ultra-uncensored-heretic-GGUF/resolve/main/gemma-4-E4B-it-ultra-uncensored-heretic-Q4_K_M.gguf",
      size: "5.4 GB",
      sizeBytes: 5400000000,
    ),
    GemmaModel(
      name: "Dolphin 2.9 (Llama 3)",
      version: "UNCENSORED",
      url: "https://huggingface.co/bartowski/dolphin-2.9-llama3-8b-GGUF/resolve/main/dolphin-2.9-llama3-8b-Q4_K_M.gguf",
      size: "4.9 GB",
      sizeBytes: 4900000000,
    ),
  ];

  Future<String> getLocalPath(String fileName) async {
    final directory = await getApplicationDocumentsDirectory();
    return "${directory.path}/$fileName";
  }

  Future<void> downloadModel(GemmaModel model, Function(double) onProgress) async {
    final fileName = model.url.split('/').last;
    final savePath = await getLocalPath(fileName);
    final file = File(savePath);
    
    int existingBytes = 0;
    if (await file.exists()) {
      existingBytes = await file.length();
    }

    print("Starting download for ${model.name}. Existing bytes: $existingBytes");

    try {
      final response = await _dio.get<ResponseBody>(
        model.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: existingBytes > 0 ? {'Range': 'bytes=$existingBytes-'} : null,
          followRedirects: true,
        ),
      );

      final totalBytes = int.tryParse(response.headers.value('content-length') ?? '0') ?? 0;
      final fullSize = totalBytes + existingBytes;

      final raf = await file.open(mode: FileMode.append);
      int received = existingBytes;

      await for (final chunk in response.data!.stream) {
        await raf.writeFrom(chunk);
        received += chunk.length;
        if (fullSize > 0) {
          onProgress(received / fullSize);
        }
      }
      await raf.close();
      print("Download completed for ${model.name}");
      model.isDownloaded = true;
    } catch (e) {
      print("Download error: $e");
      rethrow;
    }
  }

  Future<double> getDownloadProgress(GemmaModel model) async {
    final fileName = model.url.split('/').last;
    final path = await getLocalPath(fileName);
    final file = File(path);
    if (await file.exists()) {
      final size = await file.length();
      return (size / model.sizeBytes).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  Future<bool> checkDownloaded(GemmaModel model) async {
    final fileName = model.url.split('/').last;
    final path = await getLocalPath(fileName);
    final file = File(path);
    if (await file.exists()) {
      final size = await file.length();
      return size >= (model.sizeBytes * 0.95);
    }
    return false;
  }
}

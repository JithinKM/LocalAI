import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'services/llm_service.dart';
import 'services/download_service.dart';
import 'services/model_state_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('chats');
  runApp(const ProviderScope(child: LocalAIApp()));
}

class LocalAIApp extends ConsumerWidget {
  const LocalAIApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);

    return MaterialApp(
      title: 'Local AI',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.light,
        ),
        textTheme: GoogleFonts.outfitTextTheme(),
        cardTheme: const CardThemeData(elevation: 0),
        appBarTheme: const AppBarTheme(elevation: 0, scrolledUnderElevation: 0),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.outfitTextTheme(),
        cardTheme: const CardThemeData(elevation: 0),
        appBarTheme: const AppBarTheme(elevation: 0, scrolledUnderElevation: 0),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  List<Map<String, String>> _messages = [
    {'role': 'ai', 'content': 'Hello! I am your offline AI. How can I help you today?'},
  ];

  @override
  void initState() {
    super.initState();
    _tryAutoLoadModel();
  }

  Future<void> _tryAutoLoadModel() async {
    final prefs = await SharedPreferences.getInstance();
    final lastModelName = prefs.getString('last_model_name');
    if (lastModelName != null) {
      final model = DownloadService.availableModels.firstWhere(
        (m) => m.name == lastModelName,
        orElse: () => DownloadService.availableModels.first,
      );
      
      // Check if it's actually downloaded
      if (await _downloadService.checkDownloaded(model)) {
        _selectDownloadedModel(model, isAutoLoad: true);
      }
    }
  }

  final GemmaService _llmService = GemmaService();
  bool _isGenerating = false;
  bool _isLoadingModel = false;
  bool _isThinking = false;
  String? _loadedModelName;
  String? _currentChatId;

  void _sendMessage() async {
    if (_controller.text.isEmpty || _isGenerating || _isLoadingModel) return;

    if (_loadedModelName == null) {
      setState(() {
        _messages.add({
          'role': 'ai',
          'content': 'No model loaded yet. Please download or select a model from the Store to start chatting offline.',
          'action': 'show_store',
        });
      });
      return;
    }
    
    final userPrompt = _controller.text;
    setState(() {
      _messages.add({'role': 'user', 'content': userPrompt});
      _messages.add({'role': 'ai', 'content': ''}); // Placeholder for streaming response
      _controller.clear();
      _isGenerating = true;
      _isThinking = true;
      if (_currentChatId == null) {
        _currentChatId = DateTime.now().millisecondsSinceEpoch.toString();
      }
    });

    final lastIndex = _messages.length - 1;
    
    try {
      await for (final token in _llmService.generateResponse(userPrompt)) {
        if (_isThinking) {
          setState(() => _isThinking = false);
        }
        setState(() {
          _messages[lastIndex]['content'] = token;
        });
      }
      setState(() {
        _messages[lastIndex]['status'] = 'completed';
      });
      
      try {
        _saveCurrentChat();
      } catch (e) {
        print("Silent save error: $e");
      }
    } catch (e) {
      setState(() {
        _messages[lastIndex]['content'] = "Error: $e";
      });
    } finally {
      setState(() {
        _isGenerating = false;
        _isThinking = false;
      });
    }
  }

  void _createNewChat() {
    setState(() {
      _messages = [
        {'role': 'ai', 'content': 'Hello! I am your Local AI. How can I help you today?'},
      ];
      _currentChatId = DateTime.now().millisecondsSinceEpoch.toString();
    });
    _saveCurrentChat();
  }

  void _saveCurrentChat() {
    if (_messages.length <= 1) return;
    final box = Hive.box('chats');
    final chatData = {
      'id': _currentChatId ?? DateTime.now().millisecondsSinceEpoch.toString(),
      'title': _messages.length > 1 
        ? _messages[1]['content']!.substring(0, _messages[1]['content']!.length < 30 ? _messages[1]['content']!.length : 30) 
        : 'New Chat',
      'messages': _messages,
      'timestamp': DateTime.now().toIso8601String(),
    };
    box.put(chatData['id'], chatData);
    if (_currentChatId == null) {
      setState(() => _currentChatId = chatData['id'] as String);
    }
  }

  void _loadChat(Map chat) {
    setState(() {
      _currentChatId = chat['id'];
      _messages = List<Map<String, String>>.from(
        (chat['messages'] as List).map((m) => Map<String, String>.from(m as Map))
      );
    });
    Navigator.pop(context); // Close drawer
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeProvider);
    final isDark = themeMode == ThemeMode.dark;

    return Scaffold(
      drawer: _buildSidebar(),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Local AI', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
            if (_isLoadingModel)
              const Text('Waking up AI...', style: TextStyle(fontSize: 10, color: Colors.orange))
            else if (_loadedModelName != null)
              Text('Offline • $_loadedModelName', style: const TextStyle(fontSize: 10, color: Colors.green)),
          ],
        ),
        actions: const [],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _ChatBubble(
                  content: msg['content']!,
                  isAi: msg['role'] == 'ai',
                  action: msg['action'],
                  onAction: msg['action'] == 'show_store' ? _showModelStore : null,
                  isThinking: msg['role'] == 'ai' && _isThinking && index == _messages.length - 1,
                  isGenerating: msg['role'] == 'ai' && _isGenerating && index == _messages.length - 1 && !_isThinking,
                  status: msg['status'],
                );
              },
            ),
          ),
          if (_loadedModelName != null) 
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('Active Model: $_loadedModelName', 
                style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary)),
            ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Future<void> _loadModel() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any, // MediaPipe models are .bin or .task
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        final name = result.files.single.name;
        setState(() => _isGenerating = true);
        await _llmService.loadModel(path);
        setState(() {
          _isGenerating = false;
          _loadedModelName = name;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Model $name loaded successfully!')),
          );
        });
      }
    } catch (e) {
      setState(() => _isGenerating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading model: $e')),
      );
    }
  }

  final DownloadService _downloadService = DownloadService();

  void _showModelStore() {
    ref.read(modelDownloadProvider.notifier).updateDownloadedStatus(DownloadService.availableModels);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.5,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.all(20),
          child: Consumer(
            builder: (context, ref, child) {
              final downloadState = ref.watch(modelDownloadProvider);
              
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Local AI Store',
                    style: GoogleFonts.outfit(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Download models for 100% offline use.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: DownloadService.availableModels.length,
                      itemBuilder: (context, index) {
                        final model = DownloadService.availableModels[index];
                        final progress = downloadState.progressMap[model.name] ?? 0.0;
                        final isDownloaded = downloadState.downloadedModels.contains(model.name);

                        return _ModelListItem(
                          model: model,
                          progress: progress,
                          isDownloaded: isDownloaded,
                          isDownloading: downloadState.activeDownloads.contains(model.name),
                          onDownload: () async {
                            try {
                              await ref.read(modelDownloadProvider.notifier).startDownload(model);
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Download failed: $e')),
                                );
                              }
                            }
                          },
                          onSelect: () => _selectDownloadedModel(model),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }


  void _selectDownloadedModel(GemmaModel model, {bool isAutoLoad = false}) async {
    final fileName = model.url.split('/').last;
    final path = await _downloadService.getLocalPath(fileName);
    
    // Show loading dialog if not auto-loading
    if (!isAutoLoad && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text('Loading ${model.name} into RAM...', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('This may take 5-10 seconds depending on your device.', 
                textAlign: TextAlign.center, 
                style: TextStyle(fontSize: 12, color: Colors.grey)
              ),
            ],
          ),
        ),
      );
    } else if (isAutoLoad) {
      setState(() => _isLoadingModel = true);
    }

    try {
      await _llmService.loadModel(path);
      if (!isAutoLoad && mounted) Navigator.pop(context); // Close loading dialog
      
      // Save for auto-load next time
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_model_name', model.name);

      setState(() {
        _loadedModelName = model.name;
        _isLoadingModel = false;
      });
      
      if (mounted && !isAutoLoad) {
        Navigator.pop(context); // Close the store
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${model.name} is ready!'),
            backgroundColor: Colors.teal,
          ),
        );
      }
    } catch (e) {
      if (!isAutoLoad && mounted) Navigator.pop(context); // Close loading dialog
      setState(() => _isLoadingModel = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading model: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildSidebar() {
    final themeMode = ref.watch(themeProvider);
    final isDark = themeMode == ThemeMode.dark;
    final box = Hive.box('chats');

    return Drawer(
      child: ValueListenableBuilder(
        valueListenable: box.listenable(),
        builder: (context, Box box, _) {
          final chatList = box.values.toList()..sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
          
          return Column(
            children: [
              DrawerHeader(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: const Icon(Icons.psychology, color: Colors.white),
                    ),
                    const SizedBox(width: 16),
                    Text('Local AI History', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 18)),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: const Text('New Chat'),
                onTap: () {
                  _createNewChat();
                  Navigator.pop(context);
                },
              ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: chatList.length,
                  itemBuilder: (context, index) {
                    final chat = chatList[index] as Map;
                    final isCurrent = chat['id'] == _currentChatId;
                    
                    return ListTile(
                      leading: Icon(Icons.chat_bubble_outline_rounded, 
                        color: isCurrent ? Theme.of(context).colorScheme.primary : null),
                      title: Text(chat['title'] ?? 'Chat ${chat['id']}', 
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: isCurrent ? FontWeight.bold : null)),
                      subtitle: Text(chat['timestamp'].toString().split('T')[0], style: const TextStyle(fontSize: 10)),
                      onTap: () => _loadChat(chat),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        onPressed: () {
                          box.delete(chat['id']);
                        },
                      ),
                    );
                  },
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.storefront_rounded),
                title: const Text('Model Store'),
                onTap: () {
                  Navigator.pop(context);
                  _showModelStore();
                },
              ),
              ListTile(
                leading: Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
                title: Text(isDark ? 'Light Mode' : 'Dark Mode'),
                onTap: () {
                  ref.read(themeProvider.notifier).toggleTheme(!isDark);
                },
              ),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }


  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  hintText: 'Ask anything...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final canSend = _controller.text.trim().isNotEmpty && !_isGenerating;
                return FloatingActionButton(
                  onPressed: canSend ? _sendMessage : null,
                  mini: true,
                  elevation: 0,
                  hoverElevation: 0,
                  focusElevation: 0,
                  highlightElevation: 0,
                  backgroundColor: canSend 
                    ? Theme.of(context).colorScheme.primary 
                    : Theme.of(context).colorScheme.surfaceVariant,
                  foregroundColor: canSend 
                    ? Theme.of(context).colorScheme.onPrimary 
                    : Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.3),
                  child: const Icon(Icons.send_rounded),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelListItem extends StatelessWidget {
  final GemmaModel model;
  final double progress;
  final bool isDownloaded;
  final bool isDownloading;
  final VoidCallback onDownload;
  final VoidCallback onSelect;

  const _ModelListItem({
    required this.model,
    required this.progress,
    required this.isDownloaded,
    required this.isDownloading,
    required this.onDownload,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.psychology, color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('${model.size} • ${model.version}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                    ],
                  ),
                ),
                if (isDownloaded)
                  ElevatedButton(onPressed: onSelect, child: const Text('Use'))
                else if (isDownloading)
                  TextButton.icon(
                    onPressed: null, 
                    icon: const SizedBox(
                      width: 14, 
                      height: 14, 
                      child: CircularProgressIndicator(strokeWidth: 2)
                    ),
                    label: const Text('Downloading...', style: TextStyle(fontSize: 12)),
                  )
                else if (progress > 0 && progress < 1.0)
                  IconButton.filledTonal(
                    onPressed: onDownload, 
                    icon: const Icon(Icons.play_arrow_rounded),
                    color: Colors.orange,
                  )
                else
                  IconButton.filledTonal(onPressed: onDownload, icon: const Icon(Icons.download_rounded)),
              ],
            ),
            if (isDownloading || (progress > 0 && progress < 1.0)) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress, 
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${(progress * 100).toInt()}%',
                  style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final String content;
  final bool isAi;
  final String? action;
  final VoidCallback? onAction;
  final bool isThinking;
  final bool isGenerating;
  final String? status;

  const _ChatBubble({
    required this.content, 
    required this.isAi,
    this.action,
    this.onAction,
    this.isThinking = false,
    this.isGenerating = false,
    this.status,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: isAi ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isAi 
                ? Theme.of(context).colorScheme.surfaceVariant 
                : Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(isAi ? 4 : 20),
                bottomRight: Radius.circular(isAi ? 20 : 4),
              ),
            ),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (content.isNotEmpty)
                  Text(
                    content,
                    style: TextStyle(
                      color: isAi 
                        ? Theme.of(context).colorScheme.onSurfaceVariant 
                        : Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                if (action == 'show_store') ...[
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: onAction,
                    icon: const Icon(Icons.store_rounded, size: 18),
                    label: const Text('Go to Store'),
                    style: ElevatedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (isAi) ...[
            if (isThinking)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 4),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text('Thinking...', 
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary, fontStyle: FontStyle.italic)),
                  ],
                ),
              )
            else if (isGenerating)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Row(
                  children: [
                    Text('Generating', 
                      style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline.withOpacity(0.5))),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5, 
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
              )
            else if (status == 'completed')
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline_rounded, size: 12, color: Colors.teal.withOpacity(0.5)),
                    const SizedBox(width: 4),
                    Text('Response complete', 
                      style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline.withOpacity(0.5))),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'services/llm_service.dart';
import 'services/download_service.dart';
import 'services/model_state_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:read_pdf_text/read_pdf_text.dart';
import 'package:url_launcher/url_launcher.dart';

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
        textTheme: GoogleFonts.outfitTextTheme().copyWith(
          bodyLarge: GoogleFonts.outfit(fontSize: 18),
          bodyMedium: GoogleFonts.outfit(fontSize: 16),
          titleMedium: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        cardTheme: const CardThemeData(elevation: 0),
        appBarTheme: const AppBarTheme(elevation: 0, scrolledUnderElevation: 0),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.outfitTextTheme().copyWith(
          bodyLarge: GoogleFonts.outfit(fontSize: 18),
          bodyMedium: GoogleFonts.outfit(fontSize: 16),
          titleMedium: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600),
        ),
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
  final FocusNode _focusNode = FocusNode();
  List<Map<String, dynamic>> _messages = [
    {'role': 'ai', 'content': 'Hello! I am your offline AI. How can I help you today?'},
  ];

  @override
  void initState() {
    super.initState();
    _tryAutoLoadModel();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
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
  final ScrollController _scrollController = ScrollController();
  bool _isGenerating = false;
  bool _isLoadingModel = false;
  bool _isThinking = false;
  String? _loadedModelName;
  String? _currentChatId;
  String? _attachedFileName;
  String? _attachedFileContent;
  int _currentContextSize = 2048; // Default to Standard Mode (increased from 1024)
  String? _lastLoadedModelPath; // To reload if switching modes

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
    String finalPrompt = userPrompt;
    
    // Determine required context
    int requiredContext = 1024;
    String truncatedContent = "";
    if (_attachedFileContent != null) {
      truncatedContent = _attachedFileContent!;
      if (truncatedContent.length > 5000) {
        requiredContext = 8192; // Use larger context for long docs
        if (truncatedContent.length > 50000) {
          truncatedContent = truncatedContent.substring(0, 50000) + "... [Document Truncated]";
        }
      }
    }

    if (_attachedFileContent != null) {
      finalPrompt = "Document Content (${_attachedFileName}):\n${truncatedContent}\n\nUser Question: ${userPrompt}";
    }

    // --- ADDED: Show user message IMMEDIATELY for better UX ---
    final attachedName = _attachedFileName;
    setState(() {
      _messages.add({
        'role': 'user', 
        'content': userPrompt,
        if (attachedName != null) 'fileName': attachedName,
      });
      _messages.add({'role': 'ai', 'content': ''}); // Placeholder for AI
      _controller.clear();
      _attachedFileName = null; 
      _attachedFileContent = null;
      _isGenerating = true;
      _isThinking = true;
    });
    _scrollToBottom();
    final lastIndex = _messages.length - 1;

    // Check if we need to upgrade to Power Mode
    if (requiredContext > _currentContextSize) {
      final shouldUpgrade = await _showPowerModeDialog();
      if (!shouldUpgrade) {
        // User declined, use Standard Mode limit
        finalPrompt = "Document Content (${_attachedFileName}):\n${truncatedContent}\n\nUser Question: ${userPrompt}";
        requiredContext = 2048;
      } else {
        // User accepted, reload model with larger context
        setState(() => _isLoadingModel = true);
        try {
          await _llmService.loadModel(_lastLoadedModelPath!, contextSize: 8192);
          _currentContextSize = 8192;
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to enter Power Mode: $e')));
          setState(() {
            _isLoadingModel = false;
            _isGenerating = false;
            _isThinking = false;
          });
          return;
        }
        setState(() => _isLoadingModel = false);
      }
    }

    // Initialize Chat ID if this is the first message
    if (_currentChatId == null) {
      _currentChatId = DateTime.now().millisecondsSinceEpoch.toString();
    }

    // 1. Build the full conversation history for context
    String fullConversationContext = "";
    // Increased history: 50 messages in Power Mode, 20 in Standard Mode
    final historyCount = _currentContextSize > 2048 ? 50 : 20;
    // We sublist from length - historyCount - 2 because we just added 2 messages
    final contextHistoryLength = _messages.length - 2;
    final contextMessages = contextHistoryLength > historyCount 
        ? _messages.sublist(contextHistoryLength - historyCount, contextHistoryLength) 
        : _messages.sublist(0, contextHistoryLength);
        
    for (var msg in contextMessages) {
      if (msg['role'] == 'user') {
        fullConversationContext += "<|user|>\n${msg['content']}\n<|end|>\n";
      } else if (msg['role'] == 'ai' && msg['content']!.isNotEmpty) {
        fullConversationContext += "<|assistant|>\n${msg['content']}\n<|end|>\n";
      }
    }

    // 2. Add the current prompt (with attachment if present)
    const formattingInstruction =
        "When helpful, format your response with Markdown using headings, bold, italics, bullet lists, numbered lists, inline code, code blocks, and links.";
    String currentTurn = "<|user|>\n$formattingInstruction\n\n${finalPrompt}\n<|end|>\n<|assistant|>\n";
    String finalEnginePrompt = fullConversationContext + currentTurn;
    
    try {
      await for (final token in _llmService.generateResponse(finalEnginePrompt)) {
        if (_isThinking) {
          setState(() => _isThinking = false);
        }
        setState(() {
          _messages[lastIndex]['content'] = token;
        });
        _scrollToBottom();
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
      
      // Automatically switch back to Standard Mode if we were in Power Mode
      if (_currentContextSize > 2048 && _lastLoadedModelPath != null) {
        // We do this in the background to keep the UI responsive
        _llmService.loadModel(_lastLoadedModelPath!, contextSize: 2048).then((_) {
          setState(() => _currentContextSize = 2048);
        });
      }
    }
  }

  void _editMessage(int index) {
    if (_isGenerating) return;
    
    final content = _messages[index]['content'] ?? '';
    
    setState(() {
      _controller.text = content;
      // Remove all messages from this one onwards
      _messages.removeRange(index, _messages.length);
      _attachedFileName = null;
      _attachedFileContent = null;
    });
    
    _focusNode.requestFocus();
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

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutQuart,
        );
      });
    }
  }

  void _saveCurrentChat() {
    if (_messages.length <= 1) return;
    final box = Hive.box('chats');
    final chatData = {
      'id': _currentChatId ?? DateTime.now().millisecondsSinceEpoch.toString(),
      'title': _messages.length > 1 
        ? _messages[1]['content']!.substring(0, _messages[1]['content']!.length < 100 ? _messages[1]['content']!.length : 100) 
        : 'New Chat',
      'messages': _messages,
      'timestamp': DateTime.now().toIso8601String(),
    };
    box.put(chatData['id'], chatData);
    if (_currentChatId == null) {
      setState(() => _currentChatId = chatData['id'] as String);
    }
  }

  void _startNewChat() {
    setState(() {
      _messages = [];
      _currentChatId = null;
      _attachedFileName = null;
      _attachedFileContent = null;
    });
    // Reset to Standard Mode for new conversations if currently in Power Mode
    if (_currentContextSize > 2048 && _lastLoadedModelPath != null) {
      _llmService.loadModel(_lastLoadedModelPath!, contextSize: 2048);
      _currentContextSize = 2048;
    }
  }

  Future<bool> _showPowerModeDialog() async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Power Mode?'),
        content: const Text(
          'This document is large and requires more memory to process accurately. '
          'Power Mode uses more RAM and might be slower to start, but allows for much better document analysis.\n\n'
          'Continue in Power Mode?'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Use Fast Mode (Truncated)'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enter Power Mode'),
          ),
        ],
      ),
    ) ?? false;
  }

  void _loadChat(Map chat) {
    setState(() {
      _currentChatId = chat['id'];
      _attachedFileName = null;
      _attachedFileContent = null;
      _messages = List<Map<String, String>>.from(
        (chat['messages'] as List).map((m) => Map<String, String>.from(m as Map))
      );
    });
    Navigator.pop(context); // Close drawer
  }

  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'txt'],
      );

      if (result != null) {
        final file = result.files.first;
        String content = "";

        if (file.extension == 'pdf') {
          content = await ReadPdfText.getPDFtext(file.path!);
        } else if (file.extension == 'txt') {
          content = await File(file.path!).readAsString();
        }

        setState(() {
          _attachedFileName = file.name;
          _attachedFileContent = content;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error reading file: $e'), backgroundColor: Colors.red),
      );
    }
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
              const Text('Waking up AI...', style: TextStyle(fontSize: 12, color: Colors.orange))
            else if (_loadedModelName != null)
              Text('Offline • $_loadedModelName', style: const TextStyle(fontSize: 12, color: Colors.green)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Chip(
              label: Text(
                _currentContextSize > 2048 ? 'Power Mode' : 'Standard Mode',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: _currentContextSize > 2048 ? Colors.orange : Theme.of(context).colorScheme.primary,
                ),
              ),
              backgroundColor: _currentContextSize > 2048 
                ? Colors.orange.withOpacity(0.1) 
                : Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _AnimatedMessage(
                  key: ValueKey('msg_${index}_${msg['role']}'),
                  child: _ChatBubble(
                    content: msg['content']!,
                    isAi: msg['role'] == 'ai',
                    action: msg['action'],
                    onAction: msg['action'] == 'show_store' ? _showModelStore : null,
                    isThinking: msg['role'] == 'ai' && _isThinking && index == _messages.length - 1,
                    isGenerating: msg['role'] == 'ai' && _isGenerating && index == _messages.length - 1 && !_isThinking,
                    status: msg['status'],
                    onEdit: msg['role'] == 'user' ? () => _editMessage(index) : null,
                    fileName: msg['fileName'],
                  ),
                );
              },
            ),
          ),
          if (_loadedModelName != null) 
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('Active Model: $_loadedModelName', 
                style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary)),
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
          _isLoadingModel = false;
          _loadedModelName = name;
          _lastLoadedModelPath = path;
          _currentContextSize = 2048; // Default to Standard Mode on load
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
                          isSelected: _loadedModelName == model.name,
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
        _lastLoadedModelPath = path;
        _isLoadingModel = false;
        _currentContextSize = 2048;
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
      width: MediaQuery.of(context).size.width * 0.85,
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
                      subtitle: Text(chat['timestamp'].toString().split('T')[0], style: const TextStyle(fontSize: 11)),
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
    final colorScheme = Theme.of(context).colorScheme;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_attachedFileName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12, left: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colorScheme.primary.withOpacity(0.2)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.description_rounded, size: 16, color: colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(_attachedFileName!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorScheme.primary)),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _attachedFileName = null;
                                _attachedFileContent = null;
                              });
                            },
                            child: Icon(Icons.close_rounded, size: 16, color: colorScheme.primary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: _isGenerating ? null : _pickFile,
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 28),
                  color: colorScheme.primary,
                  padding: const EdgeInsets.only(bottom: 8),
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      onChanged: (val) => setState(() {}),
                      style: const TextStyle(fontSize: 17),
                      decoration: InputDecoration(
                        hintText: _attachedFileName != null ? 'Ask about the document...' : 'Message Local AI...',
                        hintStyle: TextStyle(color: colorScheme.outline.withOpacity(0.7)),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      ),
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) {
                    final canSend = (_controller.text.trim().isNotEmpty || _attachedFileContent != null) && !_isGenerating;
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
  final bool isSelected;
  final VoidCallback onDownload;
  final VoidCallback onSelect;

  const _ModelListItem({
    required this.model,
    required this.progress,
    required this.isDownloaded,
    required this.isDownloading,
    required this.isSelected,
    required this.onDownload,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isSelected
          ? colorScheme.primaryContainer.withOpacity(0.35)
          : colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isSelected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withOpacity(0.5),
          width: isSelected ? 1.5 : 1,
        ),
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
                    color: isSelected
                        ? colorScheme.primary.withOpacity(0.14)
                        : colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.psychology, color: colorScheme.primary),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              model.name,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: isSelected ? colorScheme.primary : null,
                              ),
                            ),
                          ),
                          if (isSelected)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: colorScheme.primary,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'Current',
                                style: TextStyle(
                                  color: colorScheme.onPrimary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Text(
                        '${model.size} • ${model.version}',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isDownloaded && !isSelected)
                  ElevatedButton(onPressed: onSelect, child: const Text('Use'))
                else if (isDownloaded && isSelected)
                  const SizedBox.shrink()
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
  final String? fileName;
  final VoidCallback? onEdit;

  const _ChatBubble({
    required this.content, 
    required this.isAi,
    this.action,
    this.onAction,
    this.isThinking = false,
    this.isGenerating = false,
    this.status,
    this.onEdit,
    this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: isAi ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: isAi 
                ? colorScheme.surfaceContainerHighest.withOpacity(0.7)
                : colorScheme.primary,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(24),
                topRight: const Radius.circular(24),
                bottomLeft: Radius.circular(isAi ? 6 : 24),
                bottomRight: Radius.circular(isAi ? 24 : 6),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (fileName != null) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.description_rounded, size: 14, color: isAi ? colorScheme.primary : colorScheme.onPrimary.withOpacity(0.9)),
                      const SizedBox(width: 6),
                      Text(
                        fileName!,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isAi ? colorScheme.primary : colorScheme.onPrimary.withOpacity(0.9),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (content.isNotEmpty)
                  isAi
                      ? _FormattedAiMessage(content: content)
                      : SelectableText(
                          content,
                          style: TextStyle(
                            color: colorScheme.onPrimary,
                            fontSize: 17,
                            height: 1.4,
                            letterSpacing: 0.1,
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
                      backgroundColor: colorScheme.primaryContainer,
                      foregroundColor: colorScheme.onPrimaryContainer,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (isAi) ...[
            if (isThinking)
              Padding(
                padding: const EdgeInsets.only(top: 10, left: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text('AI is thinking...', 
                      style: TextStyle(fontSize: 13, color: colorScheme.primary, fontStyle: FontStyle.italic, fontWeight: FontWeight.w500)),
                  ],
                ),
              )
            else if (isGenerating)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 8),
                child: Row(
                  children: [
                    Text('Streaming response', 
                      style: TextStyle(fontSize: 11, color: colorScheme.outline.withOpacity(0.6))),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5, 
                        color: colorScheme.outline.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              )
            else if (status == 'completed')
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline_rounded, size: 14, color: Colors.teal.withOpacity(0.6)),
                    const SizedBox(width: 4),
                    Text('Offline Response', 
                      style: TextStyle(fontSize: 11, color: colorScheme.outline.withOpacity(0.6))),
                    const SizedBox(width: 12),
                    _ChatActionButton(
                      icon: Icons.copy_rounded,
                      label: 'Copy',
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: content));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Copied to clipboard'),
                            duration: Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                            width: 220,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
          ],
          if (!isAi && onEdit != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: _ChatActionButton(
                icon: Icons.edit_rounded,
                label: 'Edit',
                onTap: onEdit!,
                isUser: true,
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isUser;

  const _ChatActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isUser = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = isUser ? colorScheme.outline.withOpacity(0.7) : colorScheme.primary.withOpacity(0.8);
    
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isUser) Icon(icon, size: 12, color: color),
            if (!isUser) const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
            if (isUser) const SizedBox(width: 4),
            if (isUser) Icon(icon, size: 12, color: color),
          ],
        ),
      ),
    );
  }
}

class _AnimatedMessage extends StatefulWidget {
  final Widget child;
  const _AnimatedMessage({super.key, required this.child});

  @override
  State<_AnimatedMessage> createState() => _AnimatedMessageState();
}

class _AnimatedMessageState extends State<_AnimatedMessage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: widget.child,
      ),
    );
  }
}


class _FormattedAiMessage extends StatelessWidget {
  final String content;

  const _FormattedAiMessage({required this.content});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return MarkdownBody(
      data: _normalizeMarkdown(content),
      selectable: true,
      softLineBreak: true,
      onTapLink: (text, href, title) => _handleLinkTap(context, href ?? text),
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontSize: 17,
          height: 1.6,
          letterSpacing: 0.2,
        ),
        strong: TextStyle(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 17,
        ),
        em: TextStyle(
          color: Colors.teal.shade400,
          fontStyle: FontStyle.italic,
          fontSize: 17,
        ),
        a: TextStyle(
          color: colorScheme.primary,
          decoration: TextDecoration.underline,
          fontWeight: FontWeight.w600,
        ),
        h1: TextStyle(
          color: colorScheme.primary,
          fontSize: 24,
          fontWeight: FontWeight.w800,
          height: 1.4,
        ),
        h2: TextStyle(
          color: colorScheme.secondary,
          fontSize: 21,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        h3: TextStyle(
          color: colorScheme.tertiary,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        code: TextStyle(
          color: colorScheme.primary,
          backgroundColor: colorScheme.primaryContainer.withOpacity(0.3),
          fontFamily: 'monospace',
          fontSize: 15,
        ),
        codeblockPadding: const EdgeInsets.all(16),
        codeblockDecoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.4)),
        ),
        blockquote: TextStyle(
          color: colorScheme.secondary,
          fontStyle: FontStyle.italic,
          fontSize: 17,
          height: 1.6,
        ),
        blockquotePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        blockquoteDecoration: BoxDecoration(
          color: colorScheme.secondaryContainer.withOpacity(0.2),
          borderRadius: BorderRadius.circular(16),
          border: Border(
            left: BorderSide(color: colorScheme.secondary, width: 4),
          ),
        ),
        listBullet: TextStyle(
          color: colorScheme.primary,
          fontWeight: FontWeight.w700,
          fontSize: 17,
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
          ),
        ),
      ),
    );
  }

  static String _normalizeMarkdown(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return value;

    final hasMarkdown = RegExp(
      r'(^#{1,6}\s)|(\*\*[^*]+\*\*)|(\*[^*\n]+\*)|(```)|(`[^`\n]+`)|(\[[^\]]+\]\([^)]+\))|(^\s*[-*+]\s)|(^\s*\d+\.\s)|(>\s)',
      multiLine: true,
    ).hasMatch(trimmed);

    if (hasMarkdown) {
      return trimmed;
    }

    return trimmed;
  }

  static Future<void> _handleLinkTap(BuildContext context, String? href) async {
    if (href == null || href.isEmpty) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(href);
    if (uri == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('This link could not be opened.')),
      );
      return;
    }

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      await Clipboard.setData(ClipboardData(text: href));
      if (context.mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Link could not be opened, so it was copied instead.')),
        );
      }
    }
  }
}

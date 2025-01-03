// This file is part of ChatBot.
//
// ChatBot is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// ChatBot is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with ChatBot. If not, see <https://www.gnu.org/licenses/>.

import "chat.dart";
import "message.dart";
import "current.dart";
import "../util.dart";
import "../config.dart";
import "../gen/l10n.dart";

import "dart:io";
import "package:http/http.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:langchain/langchain.dart";
import "package:image_picker/image_picker.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:langchain_openai/langchain_openai.dart";
import "package:flutter_image_compress/flutter_image_compress.dart";

class InputWidget extends ConsumerStatefulWidget {
  static final FocusNode focusNode = FocusNode();

  const InputWidget({super.key});

  @override
  ConsumerState<InputWidget> createState() => _InputWidgetState();

  static void unFocus() => focusNode.unfocus();
}

class _InputWidgetState extends ConsumerState<InputWidget> {
  Client? client;
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _inputCtrl = TextEditingController();

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = CurrentChat.image != null;
    final isResponding = CurrentChat.chatStatus.isResponding;

    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 8, left: 4, right: 4, bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: Badge(
                smallSize: 8,
                isLabelVisible: hasImage,
                child: Icon(
                  hasImage ? Icons.delete : Icons.add_photo_alternate,
                ),
              ),
              onPressed: _addImage,
            ),
            Expanded(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height / 4,
                ),
                child: TextField(
                  maxLines: null,
                  autofocus: false,
                  controller: _inputCtrl,
                  focusNode: InputWidget.focusNode,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: S.of(context).enter_message,
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: _sendMessage,
              icon: Icon(isResponding ? Icons.stop_circle : Icons.send),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addImage() async {
    if (CurrentChat.image != null) {
      setState(() => CurrentChat.image = null);
      return;
    }

    InputWidget.unFocus();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: const BoxDecoration(
                color: Colors.grey,
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              minTileHeight: 48,
              shape: const StadiumBorder(),
              title: Text(S.of(context).camera),
              leading: const Icon(Icons.camera_outlined),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              minTileHeight: 48,
              shape: const StadiumBorder(),
              title: Text(S.of(context).gallery),
              leading: const Icon(Icons.photo_library_outlined),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final XFile? result;
    Uint8List? compressed;

    try {
      result = await _imagePicker.pickImage(source: source);
      if (result == null) return;
    } catch (e) {
      return;
    }

    if (Config.cic.enable ?? true) {
      try {
        compressed = await FlutterImageCompress.compressWithFile(
          result.path,
          quality: Config.cic.quality ?? 95,
          minWidth: Config.cic.minWidth ?? 1920,
          minHeight: Config.cic.minHeight ?? 1080,
        );
        if (compressed == null) throw false;
      } catch (e) {
        if (mounted) {
          Util.showSnackBar(
            context: context,
            content: Text(S.of(context).image_compress_failed),
          );
        }
      }
    }

    final bytes = compressed ?? await File(result.path).readAsBytes();
    setState(() => CurrentChat.image = bytes);
  }

  Future<void> _sendMessage() async {
    if (!CurrentChat.chatStatus.isNothing) {
      CurrentChat.chatStatus = ChatStatus.nothing;
      client?.close();
      client = null;
      return;
    }

    final text = _inputCtrl.text;
    if (text.isEmpty) return;

    final messages = CurrentChat.messages;
    final apiUrl = CurrentChat.apiUrl;
    final apiKey = CurrentChat.apiKey;
    final model = CurrentChat.model;

    if (apiUrl == null || apiKey == null || model == null) {
      Util.showSnackBar(
        context: context,
        content: Text(S.of(context).setup_api_model_first),
      );
      return;
    }

    messages.add(Message.fromItem(MessageItem(
      text: text,
      role: MessageRole.user,
      image: CurrentChat.image,
    )));

    final chatContext = buildChatContext(messages);
    final item = MessageItem(
      text: "",
      model: CurrentChat.model,
      role: MessageRole.assistant,
      time: Util.formatDateTime(DateTime.now()),
    );
    final assistant = Message.fromItem(item);

    messages.add(assistant);
    ref.read(messagesProvider.notifier).notify();

    setState(() {
      _inputCtrl.clear();
      CurrentChat.image = null;
      CurrentChat.chatStatus = ChatStatus.responding;
    });

    try {
      client ??= Client();
      final llm = ChatOpenAI(
        client: client,
        apiKey: apiKey,
        baseUrl: apiUrl,
        defaultOptions: ChatOpenAIOptions(
          model: model,
          maxTokens: CurrentChat.maxTokens,
          temperature: CurrentChat.temperature,
        ),
      );

      if (CurrentChat.stream ?? true) {
        final stream = llm.stream(PromptValue.chat(chatContext));
        await for (final chunk in stream) {
          item.text += chunk.output.content;
          ref.read(messageProvider(assistant).notifier).notify();
        }
      } else {
        final result = await llm.invoke(PromptValue.chat(chatContext));
        item.text += result.output.content;
        ref.read(messageProvider(assistant).notifier).notify();
      }
    } catch (e) {
      if (CurrentChat.chatStatus.isResponding && mounted) {
        Dialogs.error(context: context, error: e);
      }
      if (item.text.isEmpty) {
        messages.length -= 2;
        _inputCtrl.text = text;
        ref.read(messagesProvider.notifier).notify();
      }
    }

    setState(() => CurrentChat.chatStatus = ChatStatus.nothing);
    ref.read(messageProvider(assistant).notifier).notify();

    final hasFile = CurrentChat.hasFile;
    CurrentChat.save();

    if (!hasFile) {
      ref.read(chatsProvider.notifier).notify();
      ref.read(chatProvider.notifier).notify();
    }
  }
}

List<ChatMessage> buildChatContext(List<Message> list) {
  final context = <ChatMessage>[];
  final items = [
    for (final message in list) message.item,
  ];
  if (items.last.role.isAssistant) items.removeLast();

  if (CurrentChat.systemPrompts != null) {
    context.add(ChatMessage.system(CurrentChat.systemPrompts!));
  }

  for (final item in items) {
    switch (item.role) {
      case MessageRole.assistant:
        context.add(ChatMessage.ai(item.text));
        break;

      case MessageRole.user:
        if (item.image == null) {
          context.add(ChatMessage.humanText(item.text));
        } else {
          context.add(ChatMessage.human(ChatMessageContent.multiModal([
            ChatMessageContent.text(item.text),
            ChatMessageContent.image(
              mimeType: "image/jpeg",
              data: item.imageBase64!,
            ),
          ])));
        }
        break;
    }
  }

  return context;
}

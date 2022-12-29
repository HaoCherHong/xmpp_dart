import 'package:collection/collection.dart' show IterableExtension;
import 'package:tuple/tuple.dart';
import 'package:xmpp_stone/src/chat/Chat.dart';
import 'package:xmpp_stone/src/data/Jid.dart';
import 'package:xmpp_stone/src/elements/stanzas/MessageStanza.dart';
import '../elements/XmppElement.dart';
import '../logger/Log.dart';

class Message {
  static String TAG = 'Message';
  MessageStanza _messageStanza;

  MessageStanza get messageStanza => _messageStanza;

  set messageStanza(MessageStanza value) {
    _messageStanza = value;
  }

  Jid _to;
  Jid _from;
  String? _text;
  DateTime _time;
  DateTime? _delayTime;

  //TODO: check purpose vs stanza_id
  String? _messageId;
  String? _stanzaId;
  String? _threadId;
  String? _queryId; //To be determined if needed
  bool _isForwarded;
  MessageStanzaType? _type;

  ChatState? _chatState; // optional element

  String? get messageId => _messageId;

  ChatMarkerType? chatMarkerType;
  String? chatMarkerId;

  Message(this._messageStanza, this._to, this._from, this._text, this._time,
      {String? stanzaId = '',
      String? threadId = '',
      bool isForwarded = false,
      DateTime? delayTime,
      String? queryId,
      String? messageId,
      MessageStanzaType? type,
      ChatState? chatState,
      this.chatMarkerType,
      this.chatMarkerId,
      }) :
      this._isForwarded = isForwarded {
    _stanzaId = stanzaId;
    _threadId = threadId;
    _queryId = queryId;
    _messageId = messageId;
    _type = type;
    _chatState = chatState;
    this._delayTime = delayTime;
  }

  ChatState? get chatState => _chatState;

  static Message fromStanza(MessageStanza stanza) {
    Message? message;
    var isCarbon = stanza.children.any(
        (element) => (element.name == 'sent' || element.name == 'received'));
    var isArchivedMessage =
        stanza.children.any((element) => (element.name == 'result'));
    if (isCarbon) {
      message = _parseCarbon(stanza);
    } else if (isArchivedMessage) {
      message = _parseArchived(stanza);
    }
    message ??= _parseRegularMessage(stanza);
    return message;
  }

  static Message? _parseCarbon(MessageStanza stanza) {
    var carbon = stanza.children.firstWhereOrNull(
        (element) => (element.name == 'sent' || element.name == 'received'));
    if (carbon == null) {
      Log.e(TAG,
          'Error while parsing message, coudn\'t find \'sent\' or \'received\' element');
      return null;
    }
    try {
      var forwarded = carbon.getChild('forwarded');
      if (forwarded != null) {
        var message = forwarded.getChild('message');
        if (message != null) {
          var to = Jid.fromFullJid(message.getAttribute('to')!.value);
          var from = Jid.fromFullJid(message.getAttribute('from')!.value);
          var body = message.getChild('body')?.textValue;
          var type = (_parseType(message));
          var chatState = _parseState(message);
          var threadId = message.getChild('thread')?.textValue;
          var delayTime = _parseDelayed(forwarded);
          if (delayTime == null) {
            Log.e(TAG, 'No delay found in forwarded message ${stanza.buildXml().toXmlString()}');
          }
          final chatMarker = _parserChatMarker(message);
          return Message(stanza, to, from, body, DateTime.now(),
              messageId: message.getAttribute('id')?.value,
              threadId: threadId,
              isForwarded: true,
              delayTime: delayTime,
              chatState: chatState,
              type: type,
              chatMarkerType: chatMarker.item1,
              chatMarkerId: chatMarker.item2,
          );
        }
      }
    } catch (e) {
      Log.e(TAG, 'Error while parsing message');
    }
    return null;
  }

  static Message? _parseArchived(MessageStanza stanza) {
    var result = stanza.children.firstWhereOrNull(
        (element) => (element.name == 'result'));
    if (result == null) {
      Log.e(TAG, 'Error while parsing archived message, couldn\'t find result');
      return null;
    }
    try {
      var queryId = result.getAttribute('queryid')?.value;
      var forwarded = result.getChild('forwarded');
      if (forwarded != null) {
        var message = forwarded.getChild('message');
        if (message != null) {
          var to = Jid.fromFullJid(message.getAttribute('to')!.value);
          var from = Jid.fromFullJid(message.getAttribute('from')!.value);
          var body = message.getChild('body')?.textValue;
          var threadId = message.getChild('thread')?.textValue;
          var stanzaId =
              message.getChild('stanza-id')?.getAttribute('id')?.value;
          var type = (_parseType(message));
          var dateTime = _parseDelayed(forwarded) ?? DateTime.now();
          var chatState = _parseState(message);
          final chatMarker = _parserChatMarker(message);
          return Message(stanza, to, from, body, dateTime,
              messageId: message.getAttribute('id')?.value,
              threadId: threadId,
              isForwarded: true,
              queryId: queryId,
              stanzaId: stanzaId,
              chatState: chatState,
              type: type,
              chatMarkerType: chatMarker.item1,
              chatMarkerId: chatMarker.item2,
            );
        }
      }
    } catch (e) {
      Log.e(TAG, 'Error while parsing archived message ${e}');
    }
    return null;
  }

  static MessageStanzaType? _parseType(XmppElement element) {
    var typeString = element.getAttribute('type');
    MessageStanzaType? type;
    if (typeString == null) {
      Log.w(TAG, 'No type found for iq stanza');
    } else {
      switch (typeString.value) {
        case 'chat':
          type = MessageStanzaType.CHAT;
          break;
        case 'error':
          type = MessageStanzaType.ERROR;
          break;
        case 'groupchat':
          type = MessageStanzaType.GROUPCHAT;
          break;
        case 'headline':
          type = MessageStanzaType.HEADLINE;
          break;
        case 'normal':
          type = MessageStanzaType.NORMAL;
          break;
      }
    }
    return type;
  }

  static ChatState? _parseState(XmppElement element) {
    var stateElement = element.children.firstWhereOrNull(
        (element) =>
            element.getAttribute('xmlns')?.value ==
            'http://jabber.org/protocol/chatstates');
    if (stateElement != null) {
      return _stateFromString(stateElement.name);
    } else {
      return null;
    }
  }

  static Tuple2<ChatMarkerType?, String?> _parserChatMarker(XmppElement element) {
    var marker = element.children.firstWhereOrNull(
        (element) =>
          element.getAttribute('xmlns')?.value == 'urn:xmpp:chat-markers:0'
    );
    if (marker == null) {
      return Tuple2(null, null);
    }
    late final ChatMarkerType markerType;
    late final String? markerId;
    switch(marker.name) {
      case 'markable':
        markerType = ChatMarkerType.MARKABLE;
        break;
      case 'received':
        markerType = ChatMarkerType.RECEIVED;
        break;
      case 'displayed':
        markerType = ChatMarkerType.DISPLAYED;
        break;
      case 'acknowledged':
        markerType = ChatMarkerType.ACKNOWLEDGED;
        break;
      default:
        Log.e(TAG, 'Unexpected chat marker: ${marker.name}');
        return Tuple2(null, null);
    }
    if (markerType == ChatMarkerType.MARKABLE) {
      markerId = null;
    } else {
      markerId = marker.getAttribute('id')?.value;
      if (markerId == null) {
        Log.e(TAG, 'Expected marker id but got null');
        return Tuple2(null, null);
      }
    }
    return Tuple2(markerType, markerId);
  }

  static ChatState _stateFromString(String? chatStateString) {
    switch (chatStateString) {
      case 'inactive':
        return ChatState.INACTIVE;
      case 'active':
        return ChatState.ACTIVE;
      case 'gone':
        return ChatState.GONE;
      case 'composing':
        return ChatState.COMPOSING;
      case 'paused':
        return ChatState.PAUSED;
    }
    return ChatState.INACTIVE;
  }

  static Message _parseRegularMessage(MessageStanza stanza) {
    final chatMarker = _parserChatMarker(stanza);
    return Message(
        stanza, stanza.toJid!, stanza.fromJid!, stanza.body, DateTime.now(),
        messageId: stanza.id,
        chatState: _parseState(stanza),
        threadId: stanza.thread,
        type: _parseType(stanza),
        chatMarkerType: chatMarker.item1,
        chatMarkerId: chatMarker.item2,
      );
  }

  static DateTime? _parseDelayed(XmppElement element) {
    var delayed = element.getChild('delay');
    if (delayed != null) {
      var stamped = delayed.getAttribute('stamp')!.value;
      try {
        var dateTime = DateTime.parse(stamped);
        return dateTime;
      } catch (e) {
        Log.e(TAG, 'Date Parsing problem');
      }
    }
    return null;
  }

  Jid get to => _to;

  set to(Jid value) {
    _to = value;
  }

  Jid get from => _from;

  set from(Jid value) {
    _from = value;
  }

  String? get text => _text;

  set text(String? value) {
    _text = value;
  }

  DateTime get time => _time;

  set time(DateTime value) {
    _time = value;
  }

  DateTime? get delayTime => _delayTime;

  set delayTime(DateTime? value) {
    _delayTime = value;
  }

  String? get stanzaId => _stanzaId;

  String? get threadId => _threadId;

  String? get queryId => _queryId;

  bool get isDelayed => _isForwarded || _delayTime != null;

  bool get isForwarded => _isForwarded;

  MessageStanzaType? get type => _type;
}

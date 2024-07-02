import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart';

import 'dom_builder.dart';

/// Register DOM view in browser.
DomView registerView({
  required Element root,
  required DomBuilderFn<Element, Event> builderFn,
  bool skipInitialUpdate = false,
}) {
  final view = _View(root, builderFn);
  if (!skipInitialUpdate) view.update();
  return view;
}

class _View extends DomView {
  final Element _root;
  final DomBuilderFn<Element, Event> _builderFn;

  Future? _invalidate;
  bool _isDisposed = false;

  _View(this._root, this._builderFn);

  @override
  Future? invalidate() {
    return _invalidate ??= Future.microtask(() {
      try {
        update();
      } finally {
        _invalidate = null;
      }
    });
  }

  @override
  Future? dispose() async {
    _isDisposed = true;
    return invalidate();
  }

  @override
  void update() {
    if (_isDisposed) {
      _updateWith((_) {});
    } else {
      _updateWith(_builderFn);
    }
  }

  void _updateWith(DomBuilderFn<Element, Event> fn) {
    final builder = _DomBuilder(this, _root);
    fn(builder);
    builder.close();
    for (final fn in builder._callbacks) {
      fn();
    }
  }
}

class _Position {
  final String tag;
  final Element container;
  int cursor = 0;
  bool mayHaveContent = true;

  _Position(this.tag, this.container);

  Node? get current => container.childNodes.length > cursor ? container.childNodes.item(cursor) : null;
}

class _DomBuilder extends DomBuilder<Element, Event> {
  final _View _view;
  final _positions = <_Position>[];
  final _callbacks = <Function>[];
  _DomBuilder(this._view, Element container) {
    _positions.add(_Position(container.tagName, container));
  }

  @override
  void open(
    String tag, {
    String? key,
    String? id,
    Iterable<String>? classes,
    Map<String, String>? styles,
    Map<String, String>? attributes,
    Map<String, DomEventFn<Element, Event>>? events,
    DomLifecycleEventFn<Element>? onCreate,
    DomLifecycleEventFn<Element>? onUpdate,
    DomLifecycleEventFn<Element>? onRemove,
  }) {
    late final tagLc = tag.toLowerCase();
    final last = _positions.last;
    if (!last.mayHaveContent) {
      throw AssertionError('Must not have content at this point.');
    }
    final current = last.current;
    Element? elem;
    late Set<String> attributesToRemove;
    var isNewElem = true;

    final reuseKey = key ?? id;
    // ignore: unnecessary_null_comparison
    if (elem == null) {
      Element? matched;
      for (final n in last.container.childNodes.skip(last.cursor)) {
        if (n.isA<Element>()) {
          final node = n as Element;
          if (node.tagName.toLowerCase() == tagLc) {
            final nd = node.getData();
            if (nd?.key == reuseKey) {
              matched = node;
              break;
            }
          }
        }
      }
      if (matched != null && matched != current) {
        last.container.insertBefore(matched, last.current);
      }
      if (matched != null) {
        elem = matched;
        isNewElem = false;
        last.cursor++;
      }
    }

    if (elem == null) {
      elem = document.createElement(tag);
      attributesToRemove = <String>{};
      if (current == null) {
        last.container.append(elem);
      } else {
        last.container.insertBefore(elem, current);
      }
      last.cursor++;
    } else {
      attributesToRemove = elem.attributes.keys.toSet();
    }
    _positions.add(_Position(tag, elem));
    elem.clearOrSetAttribute('id', id);
    elem.clearOrSetAttribute('class', classes == null || classes.isEmpty ? null : classes.join(' '));
    elem.clearOrSetAttribute('style',
        styles == null || styles.isEmpty ? null : styles.entries.map((e) => '${e.key}: ${e.value}').join('; '));
    attributes?.forEach((name, value) {
      elem!.clearOrSetAttribute(name, value);
    });
    attributesToRemove.removeAll(['id', 'class', 'style', ...?attributes?.keys]);
    for (final name in attributesToRemove) {
      elem.removeAttribute(name);
    }
    var data = elem.getData();
    final hadData = data != null;

    if (events != null && events.isNotEmpty) {
      data ??= _ElementData();
      final prevEventTypes = data.events?.keys.toSet();
      data.events ??= <String, _EventBinding>{};
      final dataEvents = data.events!;
      events.forEach((type, fn) {
        prevEventTypes?.remove(type);
        final currentBinding = dataEvents[type];
        if (currentBinding != null) {
          currentBinding.fn = fn;
        } else {
          dataEvents[type] = _EventBinding(_view, elem!, type, fn)..bind();
        }
      });
      prevEventTypes?.forEach((type) {
        dataEvents.remove(type)?.clear();
      });
    } else if (data != null) {
      data.clearEvents();
    }

    if (onRemove != null) {
      data ??= _ElementData();
      data.onRemove = onRemove;

      for (var i = _positions.length - 2; i > 0; i--) {
        final elem = _positions[i].container;
        var data = elem.getData();
        if (data == null) {
          data = _ElementData();
          _elemExpando[elem] = data;
        }
        if (data.subTreeOnRemove) break;
        data.subTreeOnRemove = true;
      }
    } else if (data?.onRemove != null) {
      data!.onRemove = null;
    }

    if (data != null) {
      data.key = reuseKey;
    } else if (reuseKey != null) {
      data ??= _ElementData();
      data.key = reuseKey;
    }

    if (!hadData && data != null && data.isNotEmpty) {
      _elemExpando[elem] = data;
    } else if (hadData && (data == null || data.isEmpty)) {
      _elemExpando[elem] = null;
    }

    if (isNewElem && onCreate != null) {
      _callbacks.add(() {
        onCreate(_DomLifecycleEvent(_view, elem!));
      });
    }
    if (!isNewElem && onUpdate != null) {
      _callbacks.add(() {
        onUpdate(_DomLifecycleEvent(_view, elem!));
      });
    }
  }

  @override
  Element close({String? tag}) {
    final last = _positions.removeLast();
    if (tag != null && last.tag != tag) {
      throw AssertionError('Tag missmatch: "$tag" != "$last".');
    }

    while (last.container.childNodes.length > last.cursor) {
      final node = last.container.childNodes.item(last.container.childNodes.length - 1);
      if (node != null) {
        _onRemove(node);
      }
    }

    return last.container;
  }

  void _onRemove(Node removed) {
    if (removed.isA<Element>()) {
      final data = (removed as Element).getData();
      if (data == null) return;
      if (data.subTreeOnRemove) {
        final childNodes = removed.childNodes;
        for (var i = 0; i < childNodes.length; i++) {
          _onRemove(childNodes.item(i)!);
        }
      }
      if (data.onRemove != null) {
        _callbacks.add(() {
          data.onRemove!(_DomLifecycleEvent(_view, removed));
        });
      }
    }
  }

  @override
  void skipNode() {
    final last = _positions.last;
    if (!last.mayHaveContent) {
      throw AssertionError('Must not have content at this point.');
    }
    if (last.container.childNodes.length > last.cursor) {
      last.cursor++;
    } else {
      throw AssertionError('No node to skip.');
    }
  }

  @override
  void skipRemainingNodes() {
    final last = _positions.last;
    if (!last.mayHaveContent) {
      throw AssertionError('Must not have content at this point.');
    }
    if (last.container.childNodes.length > last.cursor) {
      last.cursor = last.container.childNodes.length;
      last.mayHaveContent = false;
    } else {
      throw AssertionError('No node to skip.');
    }
  }

  @override
  void text(String value) {
    final last = _positions.last;
    if (!last.mayHaveContent) {
      throw AssertionError('Must not have content at this point.');
    }
    final current = last.current;
    if (current == null) {
      last.container.append(Text(value));
    } else if (current.isA<Text>()) {
      final t = current as Text;
      if (t.data == value) {
        // nothing
      } else {
        current.text = value;
      }
    } else {
      (last as Element).replaceWith([Text(value)].toJS);
    }
    last.cursor++;
  }

  @override
  void innerHtml(String value) {
    final last = _positions.last;
    if (last.cursor != 0) {
      throw AssertionError('Cursor has been moved.');
    }
    if (!last.mayHaveContent) {
      throw AssertionError('Must not have content at this point.');
    }
    last.container.innerHTML = value;
    last.cursor = last.container.childNodes.length;
    last.mayHaveContent = false;
  }
}

extension on Element {
  void clearOrSetAttribute(String name, String? value) {
    final current = getAttribute(name);
    if (current == value) return;
    if (value == null) {
      removeAttribute(name);
    } else {
      setAttribute(name, value);
    }
  }

  _ElementData? getData() {
    return _elemExpando[this];
  }
}

class _ElementData {
  String? key;
  Map<String, _EventBinding>? events;
  DomLifecycleEventFn<Element>? onRemove;
  bool subTreeOnRemove = false;

  bool get isNotEmpty => key != null || (events != null && events!.isNotEmpty) || onRemove != null || subTreeOnRemove;
  bool get isEmpty => !isNotEmpty;

  void clearEvents() {
    events?.forEach((type, binding) {
      binding.clear();
    });
    events = null;
  }
}

class _EventBinding {
  final _View view;
  final Element element;
  final String type;
  DomEventFn<Element, Event> fn;

  _EventBinding(this.view, this.element, this.type, this.fn);

  void _callback(dynamic event) {
    fn(_DomEvent(view, type, element, event));
  }

  void bind() {
    element.addEventListener(type, _callback.toJS);
  }

  void clear() {
    element.removeEventListener(type, _callback.toJS);
  }
}

final _elemExpando = Expando<_ElementData>();

class _DomLifecycleEvent implements DomLifecycleEvent<Element> {
  @override
  final DomView view;
  @override
  final Element source;

  _DomLifecycleEvent(this.view, this.source);
}

class _DomEvent implements DomEvent<Element, Event> {
  @override
  final DomView view;
  @override
  final String type;
  @override
  final Element source;
  @override
  final Event event;

  _DomEvent(this.view, this.type, this.source, this.event);
}

extension _NodeListExtension on NodeList {
  Iterable<Node> skip(int count) {
    assert(count >= 0);
    final result = <Node>[];
    for (var i = count; i < length; i++) {
      result.add(item(i)!);
    }
    return result;
  }
}

extension _NamedNodeMapExtension on NamedNodeMap {
  Iterable<String> get keys {
    final result = <String>[];
    for (var i = 0; i < length; i++) {
      result.add(item(i)!.name);
    }
    return result;
  }
}

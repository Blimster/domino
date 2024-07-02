import 'dart:js_interop';

import 'package:domino/browser.dart';
import 'package:web/web.dart';

void main() {
  window.addEventListener('onload', ((_) => _main()).toJS);
}

void _main() {
  final root = document.getElementById('root')!;
  final app = _App();
  registerView(root: root, builderFn: app.build);
}

class _App extends DomNode {
  int _counter = 0;

  @override
  void build(DomBuilder b) {
    b.visitAll([
      DomElement('button', id: 'app-button', events: {
        'click': (e) {
          _counter++;
          e.view.invalidate();
        },
      }),
      DomElement('span', id: 'app-count', text: 'Counter: $_counter'),
    ]);
  }
}

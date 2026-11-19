// Image maps (`<img usemap>` + `<map>`/`<area>`) and embedded content
// (`<embed>`, `<object>`): the logic the widgets are built on.
import 'package:aseman/src/elpian/html_widgets/html_embed.dart';
import 'package:aseman/src/elpian/html_widgets/html_img.dart';
import 'package:aseman/src/elpian/html_widgets/html_object.dart';
import 'package:aseman/src/elpian/models/elpian_node.dart';
import 'package:flutter_test/flutter_test.dart';

ElpianNode area(String shape, String coords) =>
    ElpianNode(type: 'area', props: {'shape': shape, 'coords': coords});

ElpianNode param(String name, String value) =>
    ElpianNode(type: 'param', props: {'name': name, 'value': value});

void main() {
  group('image map regions', () {
    test('rect, in either corner order', () {
      final r = ImageMapArea.of(area('rect', '10,10,50,40'));
      expect(r.contains(10, 10), isTrue);
      expect(r.contains(50, 40), isTrue);
      expect(r.contains(51, 20), isFalse);
      final flipped = ImageMapArea.of(area('rect', '50,40,10,10'));
      expect(flipped.contains(30, 20), isTrue);
    });

    test('circle (and its "circ" alias)', () {
      for (final shape in ['circle', 'circ']) {
        final c = ImageMapArea.of(area(shape, '100,100,20'));
        expect(c.contains(100, 120), isTrue);
        expect(c.contains(115, 115), isFalse); // 21.2 away
      }
    });

    test('poly by the even-odd rule', () {
      final p = ImageMapArea.of(area('poly', '0,0,100,0,50,100'));
      expect(p.contains(50, 30), isTrue);
      expect(p.contains(5, 90), isFalse);
    });

    test('default is the whole image; short coords match nothing', () {
      expect(ImageMapArea.of(area('default', '')).contains(7, 9), isTrue);
      expect(ImageMapArea.of(area('rect', '1,2')).contains(1, 2), isFalse);
      expect(ImageMapArea.of(area('circle', '1,2')).contains(1, 2), isFalse);
      expect(ImageMapArea.of(area('poly', '0,0,1,1')).contains(0, 0), isFalse);
    });
  });

  group('embed and object', () {
    test('looksLikeImage by type or extension', () {
      expect(HtmlEmbed.looksLikeImage('image/png', 'x'), isTrue);
      expect(HtmlEmbed.looksLikeImage('', 'a.svg'), isTrue);
      expect(HtmlEmbed.looksLikeImage('application/pdf', 'a.pdf'), isFalse);
    });

    test("an object's params become query parameters of its data", () {
      final node = ElpianNode(
        type: 'object',
        props: {'data': 'https://e.com/x.pdf'},
        children: [param('a b', '1&2'), param('c', '3')],
      );
      expect(HtmlObject.withParams(node, 'https://e.com/x.pdf'),
          'https://e.com/x.pdf?a+b=1%262&c=3');
      final withQuery = ElpianNode(
          type: 'object', props: {}, children: [param('k', 'v')]);
      expect(HtmlObject.withParams(withQuery, 'https://e.com/x?q=1'),
          'https://e.com/x?q=1&k=v');
    });

    test('images take no params', () {
      final node = ElpianNode(
          type: 'object', props: {'type': 'image/png'}, children: [param('k', 'v')]);
      expect(HtmlObject.withParams(node, 'https://e.com/x.png'),
          'https://e.com/x.png');
    });
  });
}

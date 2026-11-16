// A third way to click a point on the Mac screen (after the Swift tool and System Events): osascript -l JavaScript click.js <x> <y>
function run(argv) {
  ObjC.import('CoreGraphics');
  var p = $.CGPointMake(parseFloat(argv[0]), parseFloat(argv[1]));
  var down = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, p, $.kCGMouseButtonLeft);
  var up = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, p, $.kCGMouseButtonLeft);
  $.CGEventPost($.kCGHIDEventTap, down);
  delay(0.12);
  $.CGEventPost($.kCGHIDEventTap, up);
  return 'clicked ' + argv[0] + ' ' + argv[1];
}

/// Not a browser: the phone's map raises its own long press. Returns a function that stops listening.
void Function() listenMapMouse(void Function(double clientX, double clientY, double localX, double localY) onRing) => () {};

/// Not a browser: a phone has no mouse to hover with.
void Function() listenMapHover(void Function(double? localX, double? localY) onMove) => () {};

/// Not a browser: there is no cursor to change.
void setMapCursor(bool pointer) {}

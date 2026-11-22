/// Not a browser: the phone's map raises its own long press. Returns a function that stops listening.
void Function() listenMapMouse(void Function(double clientX, double clientY, double localX, double localY) onRing) => () {};

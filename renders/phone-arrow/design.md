# Phone map arrow, matching the car's

Branch `feat/phone-map-arrow` (off `rel-1.1`). For the build after 51. Render first; the behaviour change is small and is in the branch.

## What changes

During guidance the phone's map showed a round dot with a small heading triangle on top. It now shows the car's arrow, the same
shape the car's main map draws (`CarOverlayPainter.arrowBitmap` / `drawArrow`, from car/build50b).

- Shape: a notched arrowhead, 30 x 34 points at density 1, outline included. The position is the point 19 behind the tip on the
  middle line (the middle of the picture), so the arrow turns about the position.
- Colours: the theme's `position` colour fills it; the theme's `positionRing` is its outline (3 points wide, round joins).
- Turn: by the heading, clockwise from north, as the style turned the old triangle (`icon-rotate` = heading, map-aligned). On
  the guidance map (turned to the heading) that is up the screen, on a north-up map it points where the phone is going.
- Dot: only when no heading was ever known (the position feature has no `heading`). The style hides the dot on any feature that
  has one. The screen already keeps the last heading it was given (`_lastHeading`), so a fix without a heading while moving keeps
  the arrow, as the car does while the trip is guiding.

## Outside guidance too?

Yes. The car's rule is "arrow once a heading is known, dot before that", and the car's main map applies it whether or not a trip
is guiding; only the keep-the-last-heading part is tied to guiding there. The phone's one position layer is shared by guidance,
browsing and the route preview, so the same rule applies everywhere on the phone map. Say so if you want the arrow limited to guidance.

## Reuse, not a copy

Kotlin cannot be called from the Flutter map, so the geometry lives once on the Dart side, `VehicleArrow`
(`app/lib/maps/ui/vehicle_arrow.dart`): the same numbers and the same path steps as `drawArrow`. The picture the map is given
(`VehicleArrow.png`) and the render stand-ins both come from that one class. A test reads `CarOverlayPainter.kt` and fails if
width, height, ahead, outline, notch or padding differ, so the two cannot drift apart without it showing.

The picture is drawn at the map's own density (the screen's pixels per point on a phone, 1 in a browser), so it is 30 x 38
points plus 2 pixels all round at every density.

## Fit and reach

The arrow reaches further than the old triangle: 21.2 points from the position at its tails, 19 at its tip (the old reach
was 15.5 on a 3x screen). The route fit's allowance for what is drawn at the start of a route uses `VehicleArrow.reach` and no longer
depends on the screen's density. Two existing fit tests were updated for the new number.

## Not changed

The dot keeps the phone's size (radius 8, ring 3); the car's dot is a little bigger (10 and 4). The accuracy circle is as it was.

## Renders (390 wide, 3x, the guidance screen)

The map itself is a platform view and is not drawn in a test, so the map area is a stand-in: land colour, the route, the arrow's
actual image as the screen gives it to the map (turned by heading less the map's bearing), and the dot when the position the
screen sets has no heading. Everything over the map is the real screen. Roads and labels are not drawn.

- `arrow-390-light.png`, `arrow-390-dark.png`, `arrow-390-tactical.png`, `arrow-390-parchment.png`: guiding, heading known (the
  road runs a little north of east; the map is turned so it points up, the arrow follows the road).
- `dot-390-light.png`: guiding, no heading ever known: the dot, and the map turned along the route.

Tests: `app/test/vehicle_arrow_test.dart` (the Kotlin numbers; the arrow with a heading; the four-way rotation and its reach;
the picture at several densities; the dot-only-without-heading rule in the style, all four themes) and the render test
`app/test_shots/phone_arrow_renders_test.dart`, which also asserts what the screen puts on the map.

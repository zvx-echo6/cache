# id, start, end, start_cat, end_cat, boundary
FOOT, PATH, TRACK, ALL = "natural:peak", "highway:path", "highway:track", "highway:residential"
ROUTES = [
 ("R01-wild-to-road",      (44.03164,-114.98780), (44.13596,-114.91450), FOOT, ALL, "pragmatic"),
 ("R02-road-to-wild",      (44.13596,-114.91450), (44.03164,-114.98780), ALL, FOOT, "pragmatic"),
 ("R03-wild-to-wild",      (43.98000,-115.00000), (44.10000,-114.93000), FOOT, FOOT, "pragmatic"),
 ("R04-walkout-then-drive",(44.03164,-114.98780), (44.21008,-114.92566), FOOT, ALL, "pragmatic"),
 ("R05-track-4w",          (44.18793,-114.95605), (44.25092,-115.00720), TRACK, TRACK, "pragmatic"),
 ("R06-foothills-2w",      (43.71957,-116.09776), (43.77661,-116.06566), PATH, PATH, "pragmatic"),
 ("R07-yellowpine-long",   (44.95441,-115.48184), (45.16382,-115.43481), TRACK, ALL, "pragmatic"),
 ("R08-barrier-strict",    (44.18000,-114.95000), (44.23000,-114.90000), FOOT, FOOT, "strict"),
 ("R09-barrier-pragmatic", (44.18000,-114.95000), (44.23000,-114.90000), FOOT, FOOT, "pragmatic"),
 ("R10-barrier-emergency", (44.18000,-114.95000), (44.23000,-114.90000), FOOT, FOOT, "emergency"),
 ("R11-foot-mountain",     (44.03000,-114.97000), (43.93000,-115.01000), FOOT, FOOT, "pragmatic"),
 ("R12-northidaho",        (47.61594,-116.60005), (47.61513,-116.56211), ALL, PATH, "pragmatic"),
]

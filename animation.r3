Rebol [
	title: "Rebol/FastNoise animated demo"
	needs: 3.22.14
	purpose: {
		Flowing noise in a Pugl window: each frame is one slice of 3D noise,
		taken a little further along Z, coloured through a gradient.

		The noise kind and the gradient are chosen by radio buttons; the
		sliders set the speed, the detail and the octaves of the fractal
		ones. Space pauses, Escape closes.

		Per frame there is no loop in Rebol, and nothing is allocated: `grid`
		fills a float32 vector, `interpolate` maps its range to 0..255 bytes
		(clamped and rounded) and `remap` paints them into the image through
		the gradient - all into series made once, before the first frame.
	}
]

fn: import 'fastnoise
ui: do %..\Rebol-Pugl\widgets.reb


res:  256                                           ;; the noise is computed at res x res
;; Everything a frame writes into, made once - a frame allocates nothing.
out:    make vector! reduce ['float32! res * res]   ;; the noise
idx:    make vector! reduce ['uint8!   res * res]   ;; ... as gradient indexes
pic:    make image! as-pair res res                 ;; ... coloured
counts: reduce [res res 1]                          ;; a 3D grid one slice deep
start:  copy [0.0 0.0 0.0]                          ;; the slice's position: x 0 z
steps:  copy [1.0 1.0 1.0]                          ;; set by the detail slider
range:  make vector! [float32! 2]                   ;; lo hi of the noise ...
bytes:  #(float32! [0.0 255.0])                     ;; ... mapped to 0 and 255


;;-- gradients ------------------------------------------------------------------

;; A 256x1 gradient image from [position color ...] stops, positions from
;; 0.0 to 1.0; used as the palette of `remap`.
gradient: function [stops [block!]][
	pos: copy []  rgb: copy []
	foreach [p c] stops [append pos p  repend rgb [c/1 c/2 c/3]]
	img: make image! 256x1
	img/rgb: interpolate/stride
		make vector! reduce ['float32! pos]
		make vector! reduce ['uint8! rgb]
		256 3
	img
]

palettes: [
	marble  [0.0 30.25.20  0.45 120.100.80  0.5 240.230.210  0.55 120.100.80  1.0 30.25.20]
	sky     [0.0 40.90.170  0.5 120.170.230  0.75 230.240.250  1.0 255.255.255]
	terrain [0.0 8.24.80  0.42 30.90.170  0.48 210.200.140  0.52 80.150.60  0.7 40.90.35  0.85 120.110.100  1.0 250.250.250]
	fire    [0.0 0.0.0  0.4 120.10.0  0.7 240.120.10  1.0 255.250.200]
	ice     [0.0 255.255.255  0.3 150.210.240  1.0 10.30.80]
	plasma  [0.0 20.0.60  0.35 120.20.160  0.65 240.80.120  1.0 255.230.120]
	grey    [0.0 0.0.0  1.0 255.255.255]
]

gradients: make map! []
foreach [name stops] palettes [gradients/:name: gradient stops]

;;-- noise ----------------------------------------------------------------------

octaves: 4
;; How each kind is built - evaluated again when it or the octaves change.
kinds: [
	Warped   [fn/make-node/with 'DomainWarpGradient [
		source: fn/make-node/with 'FractalFBm [source: fn/make-node 'Simplex octaves: octaves]
		warp-amplitude: 40
	]]
	FBm      [fn/make-node/with 'FractalFBm    [source: fn/make-node 'Simplex octaves: octaves]]
	Ridged   [fn/make-node/with 'FractalRidged [source: fn/make-node 'Simplex octaves: octaves]]
	Simplex  [fn/make-node 'Simplex]
	Perlin   [fn/make-node 'Perlin]
	Cellular [fn/make-node 'CellularDistance]
]

kind:    'Warped
palette: gradients/marble
speed:   30.0     ;; noise units per second along Z (and X when drifting)
step:    1.0      ;; distance between samples - bigger is finer
seed:    1337
x: z:    0.0      ;; where the slice is
lo: hi:  0.0      ;; the value range mapped to the gradient, followed smoothly
reset?:  true     ;; take the range of the next frame as it is
dirty?:  true     ;; render even when paused


rebuild: does [
	node: do select kinds kind
	reset?: dirty?: true
]
rebuild

;; One frame: the slice at `z` coloured into `pic`.
render-frame: does [
	start/1: x  start/3: z
	mm: fn/grid/offset/step/seed/minmax node out counts start steps seed
	;; The range of a single frame jumps, so it is only followed - except
	;; right after the noise changed.
	either reset? [lo: mm/x  hi: mm/y  reset?: false][
		lo: lo + (mm/x - lo * 0.05)
		hi: hi + (mm/y - hi * 0.05)
	]
	range/1: lo  range/2: hi
	interpolate/into range bytes out idx
	remap/into idx palette pic
	redraw view
	dirty?: false
]

;;-- window ---------------------------------------------------------------------

win: open-window/title 760x540 "FastNoise2 animation"

ui/init win

bg:   add-image/size win make image! [1x1 30.30.38] 0x0 win/size
view: add-image win pic 220x12
view/filter: 'linear

;; The picture: square, as big as fits right of the controls.
fit: does [
	bg/size: win/size
	side: to integer! max 64 min win/size/x - 232 win/size/y - 24
	view/size: as-pair side side
	view/offset: as-pair 220 + to integer! (win/size/x - 232 - side) / 2  12
]
fit

heading: function [text y][
	h: ui/add-label win text as-pair 12 y
	h/tint: 170.170.185
	h
]

;; Radio buttons, one per name, calling `act` with the chosen name.
radios: function [names [block!] y [integer!] default [word!] act [any-function!]][
	set-of: copy []
	foreach name names [
		c: either name = default [
			ui/make-choice/radio/checked win form name as-pair 12 y set-of
		][	ui/make-choice/radio         win form name as-pair 12 y set-of ]
		c/action: func [c] compose [(:act) to word! c/text]
		y: y + 20
	]
]

heading "Noise" 12
radios extract kinds 2 32 kind func [name][kind: name  rebuild]

heading "Gradient" 160
radios extract palettes 2 180 'marble func [name][palette: gradients/:name  dirty?: true]

speed-label: heading "" 328
speed-slider: ui/make-slider/value win 12x346 180x18 0.3
speed-slider/action: func [s][
	speed: s/value * 100
	speed-label/text: ajoin ["Speed: " to integer! speed]
]

detail-label: heading "" 372
detail-slider: ui/make-slider/value win 12x390 180x18 0.5
detail-slider/action: func [s][
	step: 0.25 * (16 ** s/value)            ;; 0.25 .. 4, 1.0 in the middle
	steps/1: steps/2: step
	detail-label/text: ajoin ["Detail: " round/to step 0.01]
	dirty?: true
]

octaves-label: heading "" 416
octaves-slider: ui/make-slider/value/steps win 12x434 180x18 3 / 7 7
octaves-slider/action: func [s][
	n: 1 + to integer! round s/value * 7
	octaves-label/text: ajoin ["Octaves: " n]
	if n <> octaves [octaves: n  rebuild]
]
;; the labels show the values from the start
foreach s reduce [speed-slider detail-slider octaves-slider][s/action s]

pause: ui/make-button/toggle win "Pause" 12x464 70x0
pause/action: func [b][ui/set-text b either b/on? ["Play"]["Pause"]]
reseed: ui/make-button win "New seed" 90x464 0x0
reseed/action: func [b][seed: random 1000000  reset?: dirty?: true]
drift: ui/make-choice win "Drift" 12x494

info: heading "" 516

;;-- the loop -------------------------------------------------------------------

t0: now/precise
frames: 0
work: 0.0

forever [
	foreach evt poll-events [
		unless ui/handle evt [
			switch evt/type [
				close     [if evt/source == win [close-window win]]
				resize    [fit]
				key       [if evt/key = #" " [ui/click pause]]
				named-key [if evt/key = 'escape [close-window win]]
			]
		]
		unless win/open? [break]
	]
	unless win/open? [break]

	t: now/precise
	dt: min 0.1 to decimal! difference t t0
	t0: t
	unless pause/on? [
		z: z + (speed * dt)
		if drift/on? [x: x + (speed * 0.5 * dt)]
		dirty?: true
	]
	if dirty? [
		render-frame
		work: work + to decimal! difference now/precise t
		if 30 = frames: frames + 1 [
			info/text: ajoin ["Frame: " round/to work / frames * 1000 0.1 " ms"]
			frames: 0  work: 0.0
		]
	]
	wait 0.01
]

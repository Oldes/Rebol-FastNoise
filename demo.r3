Rebol [
	title: "Rebol/FastNoise demo"
	purpose: {
		Renders eight FastNoise2 node graphs into coloured PNG images,
		plus a mosaic of all of them (%demo-mosaic.png):

		  perlin   - plain Perlin noise, grey
		  clouds   - Simplex fBm, sky gradient
		  terrain  - Simplex fBm, height map coloured as land and water
		  ridged   - ridged fractal, fire gradient
		  cells    - cellular distance, ice gradient
		  veins    - ridged fractal over Perlin, plasma gradient
		  warped   - domain-warped fBm, marble gradient
		  tiled    - tileable noise, repeated 2x2 to show the seams are gone
	}
]

fn: import 'fastnoise

size:  256x256
out:   make vector! [float32! 65536]

;;-- colouring ----------------------------------------------------------------

;; A 256x1 gradient image from [position color ...] stops, positions from
;; 0.0 to 1.0; used as the palette of `remap`.
gradient: function [stops [block!]][
	pos: copy []  rgb: copy []
	foreach [p c] stops [append pos p  append rgb reduce [c/1 c/2 c/3]]
	img: make image! 256x1
	img/rgb: interpolate/stride
		make vector! reduce ['float32! pos]
		make vector! reduce ['uint8! rgb]
		256 3
	img
]

palettes: [
	grey    [0.0 0.0.0  1.0 255.255.255]
	sky     [0.0 40.90.170  0.5 120.170.230  0.75 230.240.250  1.0 255.255.255]
	terrain [0.0 8.24.80  0.42 30.90.170  0.48 210.200.140  0.52 80.150.60  0.7 40.90.35  0.85 120.110.100  1.0 250.250.250]
	fire    [0.0 0.0.0  0.4 120.10.0  0.7 240.120.10  1.0 255.250.200]
	ice     [0.0 255.255.255  0.3 150.210.240  1.0 10.30.80]
	marble  [0.0 30.25.20  0.45 120.100.80  0.5 240.230.210  0.55 120.100.80 1.0 30.25.20]
	plasma  [0.0 20.0.60  0.35 120.20.160  0.65 240.80.120  1.0 255.230.120]
]
gradients: make map! []
foreach [name stops] palettes [gradients/:name: gradient stops]

;; Renders the first values of `out` into a new image: min..max is mapped
;; to the 0..255 palette indexes, which `remap` replaces with the colours.
render: function [mm [pair!] palette [word!] /area sz [pair!]][
	unless area [sz: size]
	v: copy/part out sz/x * sz/y
	v: v - mm/x * (255 / max 1e-6 mm/y - mm/x)
	remap/into make vector! [uint8! :v] gradients/:palette make image! sz
]

;;-- node graphs --------------------------------------------------------------

;; Builds a node; a type or member missing in this FastNoise2 version only
;; skips its demo instead of stopping the script.
node: func [type [word!] settings [block!]][
	try [fn/make-node/with type settings]
]

simplex: fn/make-node 'Simplex

;; FastNoise2 generators divide positions by their `feature-scale` (100 by
;; default), so a step of 1.0 makes noise cells ~100 pixels wide.
demos: compose/deep [
	perlin  grey    1.5   [(node 'Perlin [])]
	clouds  sky     0.8   [(node 'FractalFBm [source: simplex octaves: 6 gain: 0.55])]
	terrain terrain 0.6   [(node 'FractalFBm [source: simplex octaves: 7 lacunarity: 2.1])]
	ridged  fire    0.7   [(node 'FractalRidged [source: simplex octaves: 5])]
	cells   ice     2.5   [(node 'CellularDistance [])]
	veins   plasma  1.0   [(node 'FractalRidged [source: node 'Perlin [] octaves: 4])]
	warped  marble  0.6   [(node 'DomainWarpGradient [
		source: node 'FractalFBm [source: simplex octaves: 4]
		warp-amplitude: 40
	])]
]

;;-- rendering ----------------------------------------------------------------

images: copy []
foreach [name palette step graph] demos [
	g: first graph
	either error? :g [
		print [as-red "skip" name "-" g/id mold/flat g/arg1]
	][
		t: now/precise
		mm: fn/grid/step/seed/minmax g out reduce [size/x size/y] reduce [step step] 2026
		img: render mm palette
		save rejoin [%demo- name %.png] img
		repend images [name img]
		print [as-green pad form name 8 "range:" pad mm 25 "time:" difference now/precise t]
	]
]

;; Tileable: a 128x128 tile, repeated 2x2 - there are no visible seams.
unless error? g: node 'FractalFBm [source: simplex octaves: 5] [
	mm: fn/tileable/step/minmax g out 128x128 1.5x1.5
	tile: render/area mm 'terrain 128x128
	img: make image! size
	foreach pos [0x0 128x0 0x128 128x128][change atz img pos tile]
	save %demo-tiled.png img
	repend images ['tiled img]
	print [as-green pad "tiled" 8 "range:" pad mm 25]
]

;; All of them side by side, 4 per row.
cols:  4
total: (length? images) // 2
rows:  total + cols - 1 // cols
mosaic: make image! as-pair cols * size/x rows * size/y
i: 0
foreach [name img] images [
	change atz mosaic as-pair i % cols * size/x  i // cols * size/y img
	++ i
]
save %demo-mosaic.png mosaic
print ["^/Saved" total "images and %demo-mosaic.png"]

import 'pugl
ui: do %c:\Dev\Builder\tree\rebol\Rebol-Pugl\widgets.reb
ui/view %demo-mosaic.png


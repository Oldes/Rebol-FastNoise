Rebol [title: "Rebol/FastNoise extension smoke test"]

print ["Running test on Rebol build:" mold to-block system/build]
system/options/quiet: false
system/options/log/rebol: 4

;; make sure that we load a fresh extension
try [system/modules/fastnoise: none]

if modules-dir: get-env 'REBOL_MODULES_DIR [
    system/options/modules: to-real-file modules-dir
    ls (system/options/modules)
]

;; import the extension
fn: import 'fastnoise

print as-yellow "Content of the module..."
? fn


fails: 0
check: func [name [string!] code [block!] /local r][
	r: try code
	either :r = true [print ["[ ok ]" name]][
		fails: fails + 1
		print ["[FAIL]" name "=>" mold/flat/part :r 80]
	]
]

check "Node types are known"       [all [map? fn/node-types  0 < length? fn/node-types]]
check "Simplex has metadata"       [object? fn/node-info 'Simplex]
check "make-node"                  [handle? simplex: fn/make-node 'Simplex]
check "node-type"                  ["Simplex" = fn/node-type simplex]
check "make-node/with"             [handle? fbm: fn/make-node/with 'FractalFBm [source: simplex octaves: 4]]
check "Released source is kept"    [simplex: none recycle  handle? fbm]
check "Hybrid constant (gain)"      [handle? fn/set-node fbm 'gain 0.6]
check "Unknown member is refused"  [error? try [fn/set-node fbm 'nope 1]]

out: make vector! [float32! 64]
check "grid 2D returns the vector" [same? out fn/grid fbm out [8 8]]
check "grid fills the vector"      [0 < length? exclude to block! out [0.0]]
check "grid/minmax"                [pair? mm: fn/grid/minmax fbm out [8 8]]
check "minmax matches the data"    [all [mm/x <= mm/y  mm/x >= -1.5  mm/y <= 1.5]]
check "Same seed, same noise"      [equal? copy fn/grid/seed fbm out [8 8] 42 copy fn/grid/seed fbm out [8 8] 42]
check "Too short vector"           [error? try [fn/grid fbm out [9 8]]]
check "Wrong vector type"          [error? try [fn/grid fbm make vector! [float64! 64] [8 8]]]
check "1D grid is refused"         [error? try [fn/grid fbm out [8]]]
check "grid 3D"                    [vector? fn/grid/step fbm out [4 4 4] [0.1 0.1 0.1]]
check "tileable"                   [vector? fn/tileable fbm out 8x8]
check "single equals grid"         [
	fn/grid/offset fbm out [8 8] [3 5]
	(abs out/1 - fn/single fbm [3 5]) < 1e-4
]
xs: #(float32! [0.0 1.0 2.0])
ys: #(float32! [0.0 0.0 0.0])
check "positions"                  [vector? fn/positions fbm out reduce [xs ys]]
check "positions match grid"       [
	p: copy/part fn/positions fbm out reduce [xs ys] 3
	g: copy/part fn/grid fbm out [3 1] 3
	equal? p g
]

print ["^/failed:" fails]
quit/return either fails > 0 [1][0]

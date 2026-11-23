[![rebol-fastnoise](https://github.com/user-attachments/assets/df1e9be8-451f-4889-9e03-2473ec51a76c)](https://github.com/Oldes/Rebol-FastNoise)

# Rebol/FastNoise

Rebol3 extension for [FastNoise2](https://github.com/Auburn/FastNoise2) - SIMD noise
generation from node graphs (Simplex, Perlin, Cellular, fractals, domain warps...).

```rebol
fn: import 'fastnoise

;; a node tree from the FastNoise2 Node Editor...
node: fn/load-node "<encoded tree>"

;; ...or built node by node (member names: see fn/node-info 'FractalFBm)
node: fn/make-node/with 'FractalFBm [
    source:  fn/make-node 'Simplex
    octaves: 5
    gain:    0.5
]

out: make vector! [float32! 65536]
fn/grid/step node out [256 256] [0.02 0.02]   ;== out, row-major, X fastest
fn/grid/minmax node out [256 256]             ;== range of the values as a pair
```

## Extension commands:


#### `node-metadata`
Returns metadata of all node types as UTF-8 source (used to build `node-types`)

#### `load-node` `:encoded`
Creates a node tree from an encoded string (as exported by the FastNoise2 Node Editor)
* `encoded` `[string!]`
* `/simd` Limit the SIMD feature set
* `level` `[integer!]` Maximum FastSIMD feature set

#### `new-node` `:id`
Creates a node from its metadata ID (low-level, see `make-node`)
* `id` `[integer!]`
* `/simd` Limit the SIMD feature set
* `level` `[integer!]` Maximum FastSIMD feature set

#### `node-id` `:node`
Returns the metadata ID of a node
* `node` `[handle!]` FNNode

#### `node-simd` `:node`
Returns the SIMD feature set active for a node
* `node` `[handle!]` FNNode

#### `set-variable` `:node` `:index` `:value`
Sets a float, int or enum variable of a node by its index (low-level, see `set-node`)
* `node` `[handle!]` FNNode
* `index` `[integer!]` Variable index
* `value` `[decimal! integer!]`

#### `set-lookup` `:node` `:index` `:source`
Connects a source node by its index (low-level, see `set-node`)
* `node` `[handle!]` FNNode
* `index` `[integer!]` Node lookup index
* `source` `[handle!]` FNNode

#### `set-hybrid` `:node` `:index` `:value`
Sets a hybrid input by its index (low-level, see `set-node`)
* `node` `[handle!]` FNNode
* `index` `[integer!]` Hybrid index
* `value` `[decimal! integer! handle! none!]` Constant (disconnects a node), FNNode, or none to disconnect

#### `grid` `:node` `:out` `:size`
Generates noise on a uniform 2D, 3D or 4D grid; X varies fastest
* `node` `[handle!]` FNNode
* `out` `[vector!]` float32! vector with room for all samples (from its index)
* `size` `[block!]` 2 to 4 sample counts - also the dimension
* `/offset` Start position (default 0)
* `start` `[block!]` One number per dimension
* `/step` Distance between samples (default 1)
* `steps` `[block!]` One number per dimension
* `/seed` Default 1337
* `value` `[integer!]`
* `/minmax` Return the range of generated values (min x max) instead of the vector

#### `tileable` `:node` `:out` `:size`
Generates seamlessly tileable 2D noise
* `node` `[handle!]` FNNode
* `out` `[vector!]` float32! vector with room for all samples (from its index)
* `size` `[pair!]` Width x height
* `/step` Distance between samples (default 1x1)
* `steps` `[pair!]`
* `/seed` Default 1337
* `value` `[integer!]`
* `/minmax` Return the range of generated values (min x max) instead of the vector

#### `positions` `:node` `:out` `:coords`
Generates noise at arbitrary 2D, 3D or 4D positions
* `node` `[handle!]` FNNode
* `out` `[vector!]` float32! vector (from its index)
* `coords` `[block!]` 2 to 4 float32! vectors (x y z w); the shortest one (or out) limits the count
* `/offset` Added to all positions (default 0)
* `start` `[block!]` One number per dimension
* `/seed` Default 1337
* `value` `[integer!]`
* `/minmax` Return the range of generated values (min x max) instead of the vector

#### `single` `:node` `:position`
Generates a single noise value (slow - prefer the batch commands)
* `node` `[handle!]` FNNode
* `position` `[block!]` 2 to 4 numbers
* `/seed` Default 1337
* `value` `[integer!]`


## Other extension values:
```rebol
;- Node types by name (word), each an object with:
;-   id          - metadata ID
;-   name        - type name as used by FastNoise2
;-   description - text from the library
;-   groups      - category path
;-   fields      - map of member name -> [kind index default min max enums description]
;-                 where kind is one of: float int enum node hybrid
;- Member names are lowercased with dashes ("Weighted Strength" -> weighted-strength);
;- per-dimension members get an axis suffix (scale-x scale-y ...).
node-types: make map! []
;- Type names indexed by metadata ID + 1
node-names: make block! 64

do function [] [
	key: func [name [string!] dim [integer!] /local s][
		s: lowercase copy name
		replace/all s #" " #"-"
		if dim >= 0 [append s pick ["-x" "-y" "-z" "-w"] dim + 1]
		to word! s
	]
	foreach [id name desc groups vars lookups hybrids] load node-metadata [
		fields: make map! []
		i: 0
		foreach [n type dim def lo hi d enums] vars [
			put fields key n dim reduce [
				pick [float int enum] type + 1  i  def  lo  hi
				collect [foreach e enums [keep key e -1]]
				d
			]
			++ i
		]
		i: 0
		foreach [n dim d] lookups [
			put fields key n dim reduce ['node i none none none none d]
			++ i
		]
		i: 0
		foreach [n dim def d] hybrids [
			put fields key n dim reduce ['hybrid i def none none none d]
			++ i
		]
		append node-names name
		put node-types to word! name make object! compose/only [
			id: (id)
			name: (name)
			description: (desc)
			groups: (groups)
			fields: (fields)
		]
	]
]

node-info: function [
	"Returns information about a node type (none if unknown)"
	type [word! string! handle!] "Type name, or a node"
][
	if handle? type [type: pick node-names 1 + node-id type]
	select node-types to word! type
]

node-type: func [
	"Returns the type name of a node"
	node [handle!] "FNNode"
][
	pick node-names 1 + node-id node
]

set-node: function [
	"Sets a member of a node: a variable, a source node or a hybrid input"
	node  [handle!] "FNNode"
	key   [word!]   "Member name (see `fields` of node-info)"
	value [number! word! handle! none!] "Number, enum name, FNNode, or none to disconnect a hybrid input"
][
	info: node-info node
	unless field: select info/fields key [
		cause-error 'script 'invalid-arg key
	]
	index: field/2
	if all [word? value  field/1 = 'enum][
		unless pos: find field/6 value [cause-error 'script 'invalid-arg value]
		value: (index? pos) - 1
	]
	unless switch field/1 [
		float int enum [all [number? value  set-variable node index value]]
		node   [all [handle? value  set-lookup node index value]]
		hybrid [all [not word? value  set-hybrid node index value]]
	][
		cause-error 'script 'invalid-arg reduce [key value]
	]
	node
]

make-node: function [
	"Creates a node of the given type"
	type [word! string!] "Node type name (see node-types)"
	/with "Set members of the new node"
	 settings [block!] "Set-word/value pairs, e.g. [source: simplex octaves: 4]; values are evaluated"
	/simd "Limit the SIMD feature set"
	 level [integer!] "Maximum FastSIMD feature set"
][
	unless info: select node-types to word! type [
		cause-error 'script 'invalid-arg type
	]
	node: either simd [new-node/simd info/id level][new-node info/id]
	if with [
		foreach [key value] reduce/no-set settings [
			unless set-word? key [cause-error 'script 'invalid-arg key]
			set-node node to word! key :value
		]
	]
	node
]
```

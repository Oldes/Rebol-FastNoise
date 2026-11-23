REBOL [
	Title:   "Rebol FastNoise2 Extension"
	Name:    fastnoise
	Version: 0.1.0
	Needs:   3.22.10
	Author:  @Oldes
	License: MIT
	Options: [delay]
	Url:     https://github.com/Siskin-framework/Rebol-FastNoise
	Exports: []
	Purpose: {
		Noise generation using Jordan Peck's FastNoise2 library - SIMD
		node graphs (Simplex, Perlin, Cellular, fractals, domain warps...)
		built either from the Node Editor's encoded strings or node by node.

		Data only - never evaluated. The C header (gen-fastnoise.h) and
		the command table (gen-fastnoise.c) are generated from this file
		by make-extension.r3.
	}
]

;; ---------------------------------------------------------------------------
;; Banner put on top of the generated files.
logo: {//   ____  __   __        ______        __
//  / __ \/ /__/ /__ ___ /_  __/__ ____/ /
// / /_/ / / _  / -_|_-<_ / / / -_) __/ _ \
// \____/_/\_,_/\__/___(@)_/  \__/\__/_// /
//  ~~~ oldes.huhuman at gmail.com ~~~ /_/
//
// Project: Rebol/FastNoise extension
// SPDX-License-Identifier: MIT
// =============================================================================
// NOTE: auto-generated file, do not modify!}

;; ---------------------------------------------------------------------------
;; C-side configuration
c-header: {
extern REBCNT Handle_FNNode;

typedef struct FNNode_t {
	void* node;  // node reference from FastNoise's C API (ref counted)
} FNNode;

int FNNode_free(void *hndl);
int FNNode_mold(REBHOB *hob, REBSER *str);
}

;; ---------------------------------------------------------------------------
;; No `handles:` block: FNNode is registered by hand in fastnoise.c's
;; Fastnoise_Init (size, free and mold). It has no path-accessible field.

;; ---------------------------------------------------------------------------
;; Commands. Order is significant - it fixes the command indices.
;; The `_init` command is injected as the first one by the generator.
commands: [
	node-metadata: [
		"Returns metadata of all node types as UTF-8 source (used to build `node-types`)"
	]
	load-node: [
		"Creates a node tree from an encoded string (as exported by the FastNoise2 Node Editor)"
		encoded [string!]
		/simd "Limit the SIMD feature set"
		 level [integer!] "Maximum FastSIMD feature set"
	]
	new-node: [
		"Creates a node from its metadata ID (low-level, see `make-node`)"
		id [integer!]
		/simd "Limit the SIMD feature set"
		 level [integer!] "Maximum FastSIMD feature set"
	]
	node-id: [
		"Returns the metadata ID of a node"
		node [handle!] "FNNode"
	]
	node-simd: [
		"Returns the SIMD feature set active for a node"
		node [handle!] "FNNode"
	]
	set-variable: [
		"Sets a float, int or enum variable of a node by its index (low-level, see `set-node`)"
		node  [handle!] "FNNode"
		index [integer!] "Variable index"
		value [decimal! integer!]
	]
	set-lookup: [
		"Connects a source node by its index (low-level, see `set-node`)"
		node   [handle!] "FNNode"
		index  [integer!] "Node lookup index"
		source [handle!] "FNNode"
	]
	set-hybrid: [
		"Sets a hybrid input by its index (low-level, see `set-node`)"
		node  [handle!] "FNNode"
		index [integer!] "Hybrid index"
		value [decimal! integer! handle! none!] "Constant (disconnects a node), FNNode, or none to disconnect"
	]
	grid: [
		"Generates noise on a uniform 2D, 3D or 4D grid; X varies fastest"
		node [handle!] "FNNode"
		out  [vector!] "float32! vector with room for all samples (from its index)"
		size [block!]  "2 to 4 sample counts - also the dimension"
		/offset "Start position (default 0)"
		 start [block!] "One number per dimension"
		/step "Distance between samples (default 1)"
		 steps [block!] "One number per dimension"
		/seed "Default 1337"
		 value [integer!]
		/minmax "Return the range of generated values (min x max) instead of the vector"
	]
	tileable: [
		"Generates seamlessly tileable 2D noise"
		node [handle!] "FNNode"
		out  [vector!] "float32! vector with room for all samples (from its index)"
		size [pair!]   "Width x height"
		/step "Distance between samples (default 1x1)"
		 steps [pair!]
		/seed "Default 1337"
		 value [integer!]
		/minmax "Return the range of generated values (min x max) instead of the vector"
	]
	positions: [
		"Generates noise at arbitrary 2D, 3D or 4D positions"
		node   [handle!] "FNNode"
		out    [vector!] "float32! vector (from its index)"
		coords [block!]  "2 to 4 float32! vectors (x y z w); the shortest one (or out) limits the count"
		/offset "Added to all positions (default 0)"
		 start [block!] "One number per dimension"
		/seed "Default 1337"
		 value [integer!]
		/minmax "Return the range of generated values (min x max) instead of the vector"
	]
	single: [
		"Generates a single noise value (slow - prefer the batch commands)"
		node     [handle!] "FNNode"
		position [block!]  "2 to 4 numbers"
		/seed "Default 1337"
		 value [integer!]
	]
]

;; ---------------------------------------------------------------------------
;; Module body.
mezzanine: [
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
]

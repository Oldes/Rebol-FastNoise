//   ____  __   __        ______        __
//  / __ \/ /__/ /__ ___ /_  __/__ ____/ /
// / /_/ / / _  / -_|_-<_ / / / -_) __/ _ \
// \____/_/\_,_/\__/___(@)_/  \__/\__/_// /
//  ~~~ oldes.huhuman at gmail.com ~~~ /_/
//
// Project: Rebol/FastNoise extension
// SPDX-License-Identifier: MIT
// =============================================================================
// Command implementations, using FastNoise2's plain C API.
//
// One function per command; the enum, the declarations, the dispatch table
// and the `_init` handler are all generated from fastnoise.reb.
//
// Node references from the C API are ref counted (SmartNode), so a node
// connected to another one stays alive after its own handle is released.
//

#include "gen-fastnoise.h"
#include <stdbool.h>  // FastNoise_C.h uses `bool`
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "FastNoise/FastNoise_C.h"

#define DEFAULT_SEED     1337
#define NO_SIMD_LIMIT    (~0u)

static const REBYTE* ERR_INVALID_HANDLE = (const REBYTE*)"Invalid FNNode handle!";
static const REBYTE* ERR_NO_HANDLE      = (const REBYTE*)"Failed to create the FNNode handle!";
static const REBYTE* ERR_BAD_TREE       = (const REBYTE*)"Invalid encoded node tree!";
static const REBYTE* ERR_BAD_ID         = (const REBYTE*)"Invalid node metadata ID!";
static const REBYTE* ERR_BAD_VECTOR     = (const REBYTE*)"Expected a writable float32! vector!";
static const REBYTE* ERR_BAD_COORDS     = (const REBYTE*)"Expected 2 to 4 float32! vectors!";
static const REBYTE* ERR_BAD_SIZE       = (const REBYTE*)"Expected 2 to 4 positive integer counts!";
static const REBYTE* ERR_BAD_NUMBERS    = (const REBYTE*)"Expected one number per dimension!";
static const REBYTE* ERR_SHORT_VECTOR   = (const REBYTE*)"Output vector is too short!";
static const REBYTE* ERR_NO_MEMORY      = (const REBYTE*)"Out of memory!";


//== helpers ==================================================================

// Node reference of a FNNode handle argument, or NULL when the argument is
// not one (or was already released).
static void* Arg_Node(RXIFRM *frm, int n) {
	REBHOB *hob;
	if (!FRM_IS_HANDLE(n, Handle_FNNode)) return NULL;
	hob = RXA_HANDLE_CONTEXT(frm, n);
	if (!hob || !IS_USED_HOB(hob) || !hob->data) return NULL;
	return ((FNNode*)hob->data)->node;
}

// Wraps a node reference into a new handle in the result slot.
// Takes the ownership - the reference is released when the handle fails.
static int Return_Node(RXIFRM *frm, void *node) {
	REBHOB *hob = RL_MAKE_HANDLE_CONTEXT(Handle_FNNode);
	if (hob == NULL) {
		fnDeleteNodeRef(node);
		RETURN_ERROR(ERR_NO_HANDLE);
	}
	((FNNode*)hob->data)->node = node;
	RETURN_HANDLE(hob);
}

// Data of a float32! vector at its index, and how many floats are left.
static float* Vector_Floats(REBSER *ser, REBCNT index, REBCNT info, REBCNT *avail) {
	REBCNT tail;
	if (!ser || !RXI_VECTOR_FLOAT(info) || RXI_VECTOR_BITS(info) != 32) return NULL;
	// Read through the struct, not RL_SERIES: its REBUPT result can be
	// truncated to 32 bits on Win64.
	tail = SERIES_TAIL(ser);
	*avail = (index < tail) ? tail - index : 0;
	return (float*)SERIES_DATA(ser) + index;
}

// The output vector argument `n`; NULL when unusable.
static float* Arg_Out(RXIFRM *frm, int n, REBCNT *avail) {
	REBSER *ser = RXA_VECTOR_SERIES(frm, n);
	if (!ser || IS_PROTECT_SERIES(ser)) return NULL;
	return Vector_Floats(ser, RXA_VECTOR_INDEX(frm, n), RXA_VECTOR_INFO(frm, n), avail);
}

// Reads the numbers of a block (from its index) into `out`.
// Returns how many were read, or -1 for a non-number or more than `max`.
static int Block_Numbers(REBSER *blk, REBCNT index, double *out, int max) {
	RXIARG val;
	int n = 0, type;
	while ((type = RL_GET_VALUE(blk, index++, &val)) && type != RXT_END) {
		if (n >= max) return -1;
		if      (type == RXT_INTEGER) out[n++] = (double)val.int64;
		else if (type == RXT_DECIMAL) out[n++] = val.dec64;
		else return -1;
	}
	return n;
}

// Reads exactly `dims` numbers of a refinement's block argument into `out`.
// Returns FALSE when the count or a type does not fit.
static int Arg_Floats(RXIFRM *frm, int n, float *out, int dims) {
	double tmp[4];
	int i;
	if (Block_Numbers(RXA_SERIES(frm, n), RXA_INDEX(frm, n), tmp, 4) != dims) return FALSE;
	for (i = 0; i < dims; i++) out[i] = (float)tmp[i];
	return TRUE;
}

// Result of the generators: the vector itself, or the min x max pair.
static int Return_Out(RXIFRM *frm, int out_arg, int minmax, float *mm) {
	if (minmax) {
		RXA_PAIR(frm, 1).x = mm[0];
		RXA_PAIR(frm, 1).y = mm[1];
		RXA_TYPE(frm, 1) = RXT_PAIR;
	} else {
		RXA_ARG(frm, 1)  = RXA_ARG(frm, out_arg);
		RXA_TYPE(frm, 1) = RXT_VECTOR;
	}
	return RXR_VALUE;
}


//== handle callbacks =========================================================

int FNNode_free(void *hndl) {
	REBHOB *hob;
	FNNode *data;

	if (!hndl) return 0;
	hob  = (REBHOB*)hndl;
	data = (FNNode*)hob->data;
	if (!data) return 0;

	debug_print("releasing FNNode handle: %p node: %p\n", (void*)data, data->node);
	if (data->node) fnDeleteNodeRef(data->node);
	CLEARS(data);
	UNMARK_HOB(hob);
	return 0;
}

int FNNode_mold(REBHOB *hob, REBSER *str) {
	int len;
	FNNode *data;

	if (!str || !hob || !(data = (FNNode*)hob->data) || !data->node) return 0;

	SERIES_TAIL(str) = 0;
	APPEND_STRING(str, "%s", fnGetMetadataName(fnGetMetadataID(data->node)));
	return len;
}


//== metadata =================================================================

// Growable byte buffer for the metadata source.
typedef struct {
	char  *data;
	size_t len;
	size_t cap;
	int    failed;
} Buf;

static void Buf_Add(Buf *b, const char *src, size_t len) {
	if (b->failed) return;
	if (b->len + len + 1 > b->cap) {
		size_t cap = b->cap ? b->cap : 4096;
		char *p;
		while (b->len + len + 1 > cap) cap *= 2;
		p = (char*)realloc(b->data, cap);
		if (!p) { b->failed = 1; return; }
		b->data = p;
		b->cap  = cap;
	}
	memcpy(b->data + b->len, src, len);
	b->len += len;
}

static void Buf_Printf(Buf *b, const char *fmt, ...) {
	char tmp[64];
	va_list args;
	int len;
	va_start(args, fmt);
	len = vsnprintf(tmp, sizeof(tmp), fmt, args);
	va_end(args);
	if (len > 0) Buf_Add(b, tmp, (size_t)MIN(len, (int)sizeof(tmp) - 1));
}

// A Rebol string literal, with the caret escapes Rebol uses.
static void Buf_String(Buf *b, const char *str) {
	const char *s;
	Buf_Add(b, " \"", 2);
	for (s = str ? str : ""; *s; s++) {
		switch (*s) {
		case '"':  Buf_Add(b, "^\"", 2); break;
		case '^':  Buf_Add(b, "^^", 2);  break;
		case '\n': Buf_Add(b, "^/", 2);  break;
		case '\t': Buf_Add(b, "^-", 2);  break;
		case '\r': break;
		default:
			if ((unsigned char)*s < 0x20) Buf_Printf(b, "^(%02X)", (unsigned char)*s);
			else Buf_Add(b, s, 1);
		}
	}
	Buf_Add(b, "\"", 1);
}

// A decimal! literal (never an integer), or `none` for an infinite bound.
static void Buf_Float(Buf *b, float f) {
	char tmp[32];
	int len;
	if (!isfinite(f)) { Buf_Add(b, " none", 5); return; }
	len = snprintf(tmp, sizeof(tmp), " %.9g", (double)f);
	if (len <= 0 || len >= (int)sizeof(tmp)) return;
	if (!strpbrk(tmp, ".e")) { tmp[len++] = '.'; tmp[len++] = '0'; tmp[len] = 0; }
	Buf_Add(b, tmp, (size_t)len);
}

// Layout of one node type (strings are UTF-8, indexes 0-based):
//   id "Name" "Description" ["Group" ...]
//   [var-name type dim default min max "description" ["Enum" ...] ...]
//   [lookup-name dim "description" ...]
//   [hybrid-name dim default "description" ...]
// where type is 0 = float, 1 = int, 2 = enum and dim is -1 unless the member
// is registered once per dimension.
COMMAND cmd_fastnoise_node_metadata(RXIFRM *frm, void *ctx) {
	Buf b = {0};
	REBSER *bin;
	int id, i, e, n, count, type;

	count = fnGetMetadataCount();
	for (id = 0; id < count; id++) {
		Buf_Printf(&b, "%d", id);
		Buf_String(&b, fnGetMetadataName(id));
		Buf_String(&b, fnGetMetadataDescription(id));

		Buf_Add(&b, " [", 2);
		n = fnGetMetadataGroupCount(id);
		for (i = 0; i < n; i++) Buf_String(&b, fnGetMetadataGroupName(id, i));
		Buf_Add(&b, "]\n [", 4);

		n = fnGetMetadataVariableCount(id);
		for (i = 0; i < n; i++) {
			type = fnGetMetadataVariableType(id, i);
			Buf_String(&b, fnGetMetadataVariableName(id, i));
			Buf_Printf(&b, " %d %d", type, fnGetMetadataVariableDimensionIdx(id, i));
			if (type == 0) {
				Buf_Float(&b, fnGetMetadataVariableDefaultFloat(id, i));
				Buf_Float(&b, fnGetMetadataVariableMinFloat(id, i));
				Buf_Float(&b, fnGetMetadataVariableMaxFloat(id, i));
			} else {
				Buf_Printf(&b, " %d none none", fnGetMetadataVariableDefaultIntEnum(id, i));
			}
			Buf_String(&b, fnGetMetadataVariableDescription(id, i));
			Buf_Add(&b, " [", 2);
			if (type == 2) {
				int ne = fnGetMetadataEnumCount(id, i);
				for (e = 0; e < ne; e++) Buf_String(&b, fnGetMetadataEnumName(id, i, e));
			}
			Buf_Add(&b, "]", 1);
		}
		Buf_Add(&b, "]\n [", 4);

		n = fnGetMetadataNodeLookupCount(id);
		for (i = 0; i < n; i++) {
			Buf_String(&b, fnGetMetadataNodeLookupName(id, i));
			Buf_Printf(&b, " %d", fnGetMetadataNodeLookupDimensionIdx(id, i));
			Buf_String(&b, fnGetMetadataNodeLookupDescription(id, i));
		}
		Buf_Add(&b, "]\n [", 4);

		n = fnGetMetadataHybridCount(id);
		for (i = 0; i < n; i++) {
			Buf_String(&b, fnGetMetadataHybridName(id, i));
			Buf_Printf(&b, " %d", fnGetMetadataHybridDimensionIdx(id, i));
			Buf_Float(&b, fnGetMetadataHybridDefault(id, i));
			Buf_String(&b, fnGetMetadataHybridDescription(id, i));
		}
		Buf_Add(&b, "]\n", 2);
	}

	if (b.failed) {
		free(b.data);
		RETURN_ERROR(ERR_NO_MEMORY);
	}
	bin = (REBSER*)RL_MAKE_BINARY((u32)b.len);
	if (b.len) COPY_MEM(BIN_HEAD(bin), b.data, b.len);
	SERIES_TAIL(bin) = (REBLEN)b.len;
	free(b.data);

	RXA_SERIES(frm, 1) = bin;
	RXA_INDEX(frm, 1)  = 0;
	RXA_TYPE(frm, 1)   = RXT_BINARY;
	return RXR_VALUE;
}


//== nodes ====================================================================

COMMAND cmd_fastnoise_load_node(RXIFRM *frm, void *ctx) {
	REBYTE  *str = NULL;
	unsigned simd = RXA_REF(frm, 2) ? (unsigned)ARG_Int32(3) : NO_SIMD_LIMIT;
	void    *node;

	RL_GET_UTF8_STRING(RXA_SERIES(frm, 1), RXA_INDEX(frm, 1), (void**)&str);
	if (!str || !*str) RETURN_ERROR(ERR_BAD_TREE);

	node = fnNewFromEncodedNodeTree((const char*)str, simd);
	if (!node) RETURN_ERROR(ERR_BAD_TREE);
	return Return_Node(frm, node);
}

COMMAND cmd_fastnoise_new_node(RXIFRM *frm, void *ctx) {
	i64      id   = ARG_Int64(1);
	unsigned simd = RXA_REF(frm, 2) ? (unsigned)ARG_Int32(3) : NO_SIMD_LIMIT;
	void    *node;

	if (id < 0 || id >= fnGetMetadataCount()) RETURN_ERROR(ERR_BAD_ID);
	node = fnNewFromMetadata((int)id, simd);
	if (!node) RETURN_ERROR(ERR_BAD_ID);
	return Return_Node(frm, node);
}

COMMAND cmd_fastnoise_node_id(RXIFRM *frm, void *ctx) {
	void *node = Arg_Node(frm, 1);
	if (!node) RETURN_ERROR(ERR_INVALID_HANDLE);
	RXA_INT64(frm, 1) = fnGetMetadataID(node);
	RXA_TYPE(frm, 1)  = RXT_INTEGER;
	return RXR_VALUE;
}

COMMAND cmd_fastnoise_node_simd(RXIFRM *frm, void *ctx) {
	void *node = Arg_Node(frm, 1);
	if (!node) RETURN_ERROR(ERR_INVALID_HANDLE);
	RXA_INT64(frm, 1) = (i64)fnGetActiveFeatureSet(node);
	RXA_TYPE(frm, 1)  = RXT_INTEGER;
	return RXR_VALUE;
}

// The setters return false for an index out of range (and the C API checks
// it), so the index is passed on as long as it fits an int.
#define ARG_Index(n) ((ARG_Int64(n) < 0 || ARG_Int64(n) > MAX_I32) ? -1 : ARG_Int32(n))

COMMAND cmd_fastnoise_set_variable(RXIFRM *frm, void *ctx) {
	void *node  = Arg_Node(frm, 1);
	int   index = ARG_Index(2);
	int   type;
	bool  ok;

	if (!node) RETURN_ERROR(ERR_INVALID_HANDLE);
	type = fnGetMetadataVariableType(fnGetMetadataID(node), index);
	if (type < 0) return RXR_FALSE;

	if (type == 0) {
		float value = (RXA_TYPE(frm, 3) == RXT_DECIMAL) ? ARG_Float(3) : (float)ARG_Int64(3);
		ok = fnSetVariableFloat(node, index, value);
	} else {
		if (RXA_TYPE(frm, 3) != RXT_INTEGER) return RXR_FALSE;
		if (ARG_Int64(3) < MIN_I32 || ARG_Int64(3) > MAX_I32) return RXR_FALSE;
		if (type == 2 && (ARG_Int64(3) < 0 ||
			ARG_Int64(3) >= fnGetMetadataEnumCount(fnGetMetadataID(node), index))) return RXR_FALSE;
		ok = fnSetVariableIntEnum(node, index, ARG_Int32(3));
	}
	return ok ? RXR_TRUE : RXR_FALSE;
}

COMMAND cmd_fastnoise_set_lookup(RXIFRM *frm, void *ctx) {
	void *node   = Arg_Node(frm, 1);
	void *source = Arg_Node(frm, 3);

	if (!node || !source) RETURN_ERROR(ERR_INVALID_HANDLE);
	return fnSetNodeLookup(node, ARG_Index(2), source) ? RXR_TRUE : RXR_FALSE;
}

COMMAND cmd_fastnoise_set_hybrid(RXIFRM *frm, void *ctx) {
	void *node  = Arg_Node(frm, 1);
	int   index = ARG_Index(2);
	void *source;

	if (!node) RETURN_ERROR(ERR_INVALID_HANDLE);
	switch (RXA_TYPE(frm, 3)) {
	case RXT_HANDLE:
		if (!(source = Arg_Node(frm, 3))) RETURN_ERROR(ERR_INVALID_HANDLE);
		return fnSetHybridNodeLookup(node, index, source) ? RXR_TRUE : RXR_FALSE;
	case RXT_NONE:
		return fnSetHybridNodeLookup(node, index, NULL) ? RXR_TRUE : RXR_FALSE;
	default: {
		// NOTE: fnSetHybridNodeLookup(node, index, NULL) returns false, so a
		// connected node cannot be disconnected that way (to be checked in
		// FastNoise_C.cpp) - the constant is set on its own.
		float value = (RXA_TYPE(frm, 3) == RXT_DECIMAL) ? ARG_Float(3) : (float)ARG_Int64(3);
		return fnSetHybridFloat(node, index, value) ? RXR_TRUE : RXR_FALSE;
	}
	}
}


//== generators ===============================================================

// grid: node out size /offset start /step steps /seed value /minmax
COMMAND cmd_fastnoise_grid(RXIFRM *frm, void *ctx) {
	void  *node = Arg_Node(frm, 1);
	float *out;
	float  start[4] = {0, 0, 0, 0};
	float  step[4]  = {1, 1, 1, 1};
	float  mm[2]    = {0, 0};
	double size[4];
	int    count[4];
	int    dims, i;
	int    seed   = RXA_REF(frm, 8) ? ARG_Int32(9) : DEFAULT_SEED;
	int    minmax = RXA_REF(frm, 10);
	REBCNT avail;
	i64    total = 1;

	if (!node) RETURN_ERROR(ERR_INVALID_HANDLE);
	if (!(out = Arg_Out(frm, 2, &avail))) RETURN_ERROR(ERR_BAD_VECTOR);

	dims = Block_Numbers(RXA_SERIES(frm, 3), RXA_INDEX(frm, 3), size, 4);
	if (dims < 2) RETURN_ERROR(ERR_BAD_SIZE);
	for (i = 0; i < dims; i++) {
		if (size[i] < 1 || size[i] > MAX_I32 || size[i] != floor(size[i])) RETURN_ERROR(ERR_BAD_SIZE);
		count[i] = (int)size[i];
		total *= count[i];
		if (total > (i64)avail) RETURN_ERROR(ERR_SHORT_VECTOR);
	}
	if (RXA_REF(frm, 4) && !Arg_Floats(frm, 5, start, dims)) RETURN_ERROR(ERR_BAD_NUMBERS);
	if (RXA_REF(frm, 6) && !Arg_Floats(frm, 7, step,  dims)) RETURN_ERROR(ERR_BAD_NUMBERS);

	switch (dims) {
	case 2:
		fnGenUniformGrid2D(node, out, start[0], start[1],
			count[0], count[1], step[0], step[1],
			seed, minmax ? mm : NULL);
		break;
	case 3:
		fnGenUniformGrid3D(node, out, start[0], start[1], start[2],
			count[0], count[1], count[2], step[0], step[1], step[2],
			seed, minmax ? mm : NULL);
		break;
	default:
		fnGenUniformGrid4D(node, out, start[0], start[1], start[2], start[3],
			count[0], count[1], count[2], count[3],
			step[0], step[1], step[2], step[3],
			seed, minmax ? mm : NULL);
	}
	return Return_Out(frm, 2, minmax, mm);
}

// tileable: node out size /step steps /seed value /minmax
COMMAND cmd_fastnoise_tileable(RXIFRM *frm, void *ctx) {
	void  *node = Arg_Node(frm, 1);
	float *out;
	float  mm[2] = {0, 0};
	float  sx = 1, sy = 1;
	float  w  = RXA_PAIR(frm, 3).x;
	float  h  = RXA_PAIR(frm, 3).y;
	int    seed   = RXA_REF(frm, 6) ? ARG_Int32(7) : DEFAULT_SEED;
	int    minmax = RXA_REF(frm, 8);
	REBCNT avail;

	if (!node) RETURN_ERROR(ERR_INVALID_HANDLE);
	if (!(out = Arg_Out(frm, 2, &avail))) RETURN_ERROR(ERR_BAD_VECTOR);
	if (w < 1 || h < 1 || w != floorf(w) || h != floorf(h)) RETURN_ERROR(ERR_BAD_SIZE);
	if ((double)w * (double)h > (double)avail) RETURN_ERROR(ERR_SHORT_VECTOR);
	if (RXA_REF(frm, 4)) {
		sx = RXA_PAIR(frm, 5).x;
		sy = RXA_PAIR(frm, 5).y;
	}

	fnGenTileable2D(node, out, (int)w, (int)h, sx, sy, seed, minmax ? mm : NULL);
	return Return_Out(frm, 2, minmax, mm);
}

// positions: node out coords /offset start /seed value /minmax
COMMAND cmd_fastnoise_positions(RXIFRM *frm, void *ctx) {
	void   *node = Arg_Node(frm, 1);
	float  *out;
	float  *pos[4];
	float   start[4] = {0, 0, 0, 0};
	float   mm[2]    = {0, 0};
	REBSER *blk   = RXA_SERIES(frm, 3);
	REBCNT  index = RXA_INDEX(frm, 3);
	int     seed   = RXA_REF(frm, 6) ? ARG_Int32(7) : DEFAULT_SEED;
	int     minmax = RXA_REF(frm, 8);
	int     dims = 0, type;
	REBCNT  avail, n;
	RXIARG  val;

	if (!node) RETURN_ERROR(ERR_INVALID_HANDLE);
	if (!(out = Arg_Out(frm, 2, &avail))) RETURN_ERROR(ERR_BAD_VECTOR);

	while ((type = RL_GET_VALUE(blk, index++, &val)) && type != RXT_END) {
		if (dims >= 4 || type != RXT_VECTOR) RETURN_ERROR(ERR_BAD_COORDS);
		pos[dims] = Vector_Floats(val.vector.series, val.vector.index, val.vector.info, &n);
		if (!pos[dims]) RETURN_ERROR(ERR_BAD_COORDS);
		if (n < avail) avail = n;
		dims++;
	}
	if (dims < 2) RETURN_ERROR(ERR_BAD_COORDS);
	if (RXA_REF(frm, 4) && !Arg_Floats(frm, 5, start, dims)) RETURN_ERROR(ERR_BAD_NUMBERS);
	if (avail > MAX_I32) avail = MAX_I32;

	if (avail > 0) switch (dims) {
	case 2:
		fnGenPositionArray2D(node, out, (int)avail, pos[0], pos[1],
			start[0], start[1], seed, minmax ? mm : NULL);
		break;
	case 3:
		fnGenPositionArray3D(node, out, (int)avail, pos[0], pos[1], pos[2],
			start[0], start[1], start[2], seed, minmax ? mm : NULL);
		break;
	default:
		fnGenPositionArray4D(node, out, (int)avail, pos[0], pos[1], pos[2], pos[3],
			start[0], start[1], start[2], start[3], seed, minmax ? mm : NULL);
	}
	return Return_Out(frm, 2, minmax, mm);
}

// single: node position /seed value
COMMAND cmd_fastnoise_single(RXIFRM *frm, void *ctx) {
	void  *node = Arg_Node(frm, 1);
	int    seed = RXA_REF(frm, 3) ? ARG_Int32(4) : DEFAULT_SEED;
	double p[4];
	float  value;

	if (!node) RETURN_ERROR(ERR_INVALID_HANDLE);
	switch (Block_Numbers(RXA_SERIES(frm, 2), RXA_INDEX(frm, 2), p, 4)) {
	case 2: value = fnGenSingle2D(node, (float)p[0], (float)p[1], seed); break;
	case 3: value = fnGenSingle3D(node, (float)p[0], (float)p[1], (float)p[2], seed); break;
	case 4: value = fnGenSingle4D(node, (float)p[0], (float)p[1], (float)p[2], (float)p[3], seed); break;
	default: RETURN_ERROR(ERR_BAD_NUMBERS);
	}
	RXA_DEC64(frm, 1) = (double)value;
	RXA_TYPE(frm, 1)  = RXT_DECIMAL;
	return RXR_VALUE;
}

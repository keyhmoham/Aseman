package spaces

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
)

// pngSignature is the 8-byte PNG file signature.
var pngSignature = []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

// pngValidName reports whether a 4-byte chunk name is a valid PNG chunk type
// (ASCII letters).
func pngValidName(name []byte) bool {
	if len(name) != 4 {
		return false
	}
	for _, c := range name {
		if (c < 'A' || c > 'Z') && (c < 'a' || c > 'z') {
			return false
		}
	}
	return true
}

// pngChunkOK reports whether b is a structurally valid PNG whose every chunk
// CRC matches its content, starting right after the 8-byte signature.
func pngChunkOK(b []byte) bool {
	off := 8
	for off+8 <= len(b) {
		length := int(binary.BigEndian.Uint32(b[off : off+4]))
		name := b[off+4 : off+8]
		if !pngValidName(name) {
			return false
		}
		start := off + 8
		end := start + length
		if end+4 > len(b) {
			return false
		}
		if crc32.ChecksumIEEE(b[off+4:end]) != binary.BigEndian.Uint32(b[end:end+4]) {
			return false
		}
		if string(name) == "IEND" {
			return true
		}
		off = end + 4
	}
	return false
}

// fixPNGCRCs rewrites every chunk CRC that does not match its content. It
// returns the repaired bytes only when the chunk stream is structurally valid
// (every chunk type is a valid name and stays in bounds); otherwise it returns
// the original bytes untouched.
func fixPNGCRCs(b []byte) []byte {
	out := append([]byte(nil), b...)
	off := 8
	for off+8 <= len(out) {
		length := int(binary.BigEndian.Uint32(out[off : off+4]))
		name := out[off+4 : off+8]
		if !pngValidName(name) {
			return b
		}
		start := off + 8
		end := start + length
		if end+4 > len(out) {
			return b
		}
		if want := crc32.ChecksumIEEE(out[off+4 : end]); want != binary.BigEndian.Uint32(out[end:end+4]) {
			binary.BigEndian.PutUint32(out[end:end+4], want)
		}
		if string(name) == "IEND" {
			return out
		}
		off = end + 4
	}
	return b
}

// repairPNG attempts to repair a common corruption produced by hand-rolled
// encoders that write each chunk as [length][crc][type][data] (the CRC before
// the type name, with no trailing CRC) instead of the standard
// [length][type][data][crc]. It rewrites the chunk stream into the standard
// layout, fixes any mismatched CRCs, and returns the repaired PNG only when the
// result is structurally sound; otherwise it returns the original bytes.
func repairPNG(b []byte) []byte {
	if len(b) < 12 || !bytes.Equal(b[:8], pngSignature) {
		return b
	}
	if pngChunkOK(b) {
		return b
	}
	var out []byte
	out = append(out, b[:8]...)
	off := 8
	for off+8 <= len(b) {
		length := int(binary.BigEndian.Uint32(b[off : off+4]))
		if length < 0 || length > len(b) {
			return b
		}
		var name, data, crc []byte
		next := 0
		switch {
		case off+12 <= len(b) && pngValidName(b[off+4:off+8]):
			// Standard layout: [len][type][data][crc].
			dataStart := off + 8
			end := dataStart + length
			if end+4 > len(b) {
				return b
			}
			name, data, crc = b[off+4:off+8], b[dataStart:end], b[end:end+4]
			next = end + 4
		case off+12 <= len(b) && pngValidName(b[off+8:off+12]):
			// Buggy layout: [len][crc][type][data].
			crc = b[off+4 : off+8]
			name = b[off+8 : off+12]
			dataStart := off + 12
			end := dataStart + length
			if end > len(b) {
				return b
			}
			data = b[dataStart:end]
			next = end
		default:
			return b
		}
		// Rebuild in the standard layout: [len][type][data][crc].
		out = append(out, b[off:off+4]...)
		out = append(out, name...)
		out = append(out, data...)
		out = append(out, crc...)
		if string(name) == "IEND" {
			break
		}
		off = next
	}
	// Fix any mismatched CRCs and require a structurally sound result.
	if fixed := fixPNGCRCs(out); pngChunkOK(fixed) {
		return fixed
	}
	return b
}

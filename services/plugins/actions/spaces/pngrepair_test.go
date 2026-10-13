package spaces

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"hash/crc32"
	"testing"
)

// buildPNG constructs a minimal valid RGB PNG (width x height) with one IDAT.
func buildPNG(t *testing.T, width, height uint32) []byte {
	t.Helper()
	sig := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

	ihdrData := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdrData[0:4], width)
	binary.BigEndian.PutUint32(ihdrData[4:8], height)
	ihdrData[8] = 8  // bit depth
	ihdrData[9] = 2  // color type: truecolor RGB
	ihdrData[10] = 0 // compression
	ihdrData[11] = 0 // filter
	ihdrData[12] = 0 // interlace

	// One scanline per row: filter byte 0 + RGB pixels.
	raw := make([]byte, 0, int(height)*(1+3*int(width)))
	for y := uint32(0); y < height; y++ {
		raw = append(raw, 0)
		for x := uint32(0); x < width; x++ {
			raw = append(raw, byte(x), byte(y), 128)
		}
	}
	var idat bytes.Buffer
	zw := zlib.NewWriter(&idat)
	zw.Write(raw)
	zw.Close()

	chunk := func(typ string, data []byte) []byte {
		out := make([]byte, 0, 12+len(data))
		var l [4]byte
		binary.BigEndian.PutUint32(l[:], uint32(len(data)))
		out = append(out, l[:]...)
		out = append(out, typ...)
		out = append(out, data...)
		crc := crc32.ChecksumIEEE(append([]byte(typ), data...))
		var c [4]byte
		binary.BigEndian.PutUint32(c[:], crc)
		out = append(out, c[:]...)
		return out
	}

	var b bytes.Buffer
	b.Write(sig)
	b.Write(chunk("IHDR", ihdrData))
	b.Write(chunk("IDAT", idat.Bytes()))
	b.Write(chunk("IEND", nil))
	return b.Bytes()
}

// corruptMoveCRC models the observed hand-rolled-encoder bug: every chunk is
// written as [length][crc][type][data] (CRC before the type, no trailing CRC)
// instead of the standard [length][type][data][crc].
func corruptMoveCRC(png []byte) []byte {
	out := []byte{}
	out = append(out, png[:8]...)
	off := 8
	for off+8 <= len(png) {
		length := int(binary.BigEndian.Uint32(png[off : off+4]))
		name := png[off+4 : off+8]
		dataStart := off + 8
		end := dataStart + length
		crc := png[end : end+4]
		out = append(out, png[off:off+4]...)
		out = append(out, crc...)
		out = append(out, name...)
		out = append(out, png[dataStart:end]...)
		if string(name) == "IEND" {
			break
		}
		off = end + 4
	}
	return out
}

func TestRepairPNGPassesThroughValidPNG(t *testing.T) {
	png := buildPNG(t, 64, 32)
	got := repairPNG(png)
	if !bytes.Equal(got, png) {
		t.Fatal("valid PNG must pass through unchanged")
	}
}

func TestRepairPNGFixesInsertedGarbage(t *testing.T) {
	png := buildPNG(t, 4, 4)
	corrupted := corruptMoveCRC(png)
	if pngChunkOK(corrupted) {
		t.Fatal("corrupted PNG should not validate")
	}
	fixed := repairPNG(corrupted)
	if !pngChunkOK(fixed) {
		t.Fatal("repair must produce a structurally valid, CRC-correct PNG")
	}
	// The fixed bytes must decode to the same dimensions.
	wantW := binary.BigEndian.Uint32(png[16:20])
	wantH := binary.BigEndian.Uint32(png[20:24])
	gotW := binary.BigEndian.Uint32(fixed[16:20])
	gotH := binary.BigEndian.Uint32(fixed[20:24])
	if gotW != wantW || gotH != wantH {
		t.Fatalf("dimensions mismatch: got %dx%d want %dx%d", gotW, gotH, wantW, wantH)
	}
}

func TestRepairPNGLeavesNonPNGAlone(t *testing.T) {
	notPNG := []byte("hello world, definitely not an image")
	if got := repairPNG(notPNG); !bytes.Equal(got, notPNG) {
		t.Fatal("non-PNG bytes must pass through unchanged")
	}
	// A PNG whose corruption is too deep to repair is also left alone.
	png := buildPNG(t, 8, 8)
	truncated := png[:len(png)-10] // chop off IEND
	if got := repairPNG(truncated); !bytes.Equal(got, truncated) {
		t.Fatal("unrepairable bytes must pass through unchanged")
	}
}

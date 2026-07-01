package main

import (
	"fmt"
	"io"
	"strings"

	"rsc.io/qr"
)

const qrQuietZone = 4

func writeQRHalfBlock(w io.Writer, text string) {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return
	}

	writeQRHalfBlockCode(w, code)
}

func writeQRHalfBlockCode(w io.Writer, code *qr.Code) {
	const (
		blackBlack = " "
		blackWhite = "\u2584"
		whiteBlack = "\u2580"
		whiteWhite = "\u2588"
	)

	if qrQuietZone%2 != 0 {
		fmt.Fprintln(w, strings.Repeat(blackWhite, code.Size+qrQuietZone*2))
	}
	for range qrQuietZone / 2 {
		fmt.Fprintln(w, strings.Repeat(whiteWhite, code.Size+qrQuietZone*2))
	}

	for y := 0; y <= code.Size; y += 2 {
		fmt.Fprint(w, strings.Repeat(whiteWhite, qrQuietZone))
		for x := 0; x <= code.Size; x++ {
			top := code.Black(x, y)
			bottom := false
			if y+1 < code.Size {
				bottom = code.Black(x, y+1)
			}

			switch {
			case top && bottom:
				fmt.Fprint(w, blackBlack)
			case top && !bottom:
				fmt.Fprint(w, blackWhite)
			case !top && bottom:
				fmt.Fprint(w, whiteBlack)
			default:
				fmt.Fprint(w, whiteWhite)
			}
		}
		fmt.Fprintln(w, strings.Repeat(whiteWhite, qrQuietZone-1))
	}

	if qrQuietZone%2 == 0 {
		for range qrQuietZone/2 - 1 {
			fmt.Fprintln(w, strings.Repeat(whiteWhite, code.Size+qrQuietZone*2))
		}
		fmt.Fprintln(w, strings.Repeat(whiteBlack, code.Size+qrQuietZone*2))
		return
	}

	for range qrQuietZone / 2 {
		fmt.Fprintln(w, strings.Repeat(whiteWhite, code.Size+qrQuietZone*2))
	}
}

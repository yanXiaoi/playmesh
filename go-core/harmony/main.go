//go:build cgo && openharmony

// Package main exports the Playmesh Core mobile lifecycle through a stable C
// ABI. HarmonyOS consumes this library through a small Node-API wrapper.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	core "go-core/mobile"
)

// PlaymeshCoreStart starts the embedded Core and returns its actual bound
// address. Both returned strings are allocated with malloc and must be released
// by PlaymeshCoreFree.
//
//export PlaymeshCoreStart
func PlaymeshCoreStart(
	address *C.char,
	boundAddress **C.char,
	errorMessage **C.char,
) C.int {
	if boundAddress == nil || errorMessage == nil {
		return 2
	}
	*boundAddress = nil
	*errorMessage = nil

	requestedAddress := "0.0.0.0:0"
	if address != nil {
		requestedAddress = C.GoString(address)
	}
	actualAddress, err := core.Start(requestedAddress)
	if err != nil {
		*errorMessage = C.CString(err.Error())
		return 1
	}
	*boundAddress = C.CString(actualAddress)
	return 0
}

// PlaymeshCoreStop stops the embedded Core and releases its listener.
//
//export PlaymeshCoreStop
func PlaymeshCoreStop(errorMessage **C.char) C.int {
	if errorMessage == nil {
		return 2
	}
	*errorMessage = nil
	if err := core.Stop(); err != nil {
		*errorMessage = C.CString(err.Error())
		return 1
	}
	return 0
}

// PlaymeshCoreFree releases a string returned by this ABI.
//
//export PlaymeshCoreFree
func PlaymeshCoreFree(value *C.char) {
	if value != nil {
		C.free(unsafe.Pointer(value))
	}
}

func main() {}

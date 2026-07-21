//go:build windows

package main

import "syscall"

const (
	synchronizeAccess = 0x00100000
	infiniteWait      = 0xffffffff
	waitObject0       = 0
)

var (
	kernel32            = syscall.NewLazyDLL("kernel32.dll")
	openProcess         = kernel32.NewProc("OpenProcess")
	waitForSingleObject = kernel32.NewProc("WaitForSingleObject")
	closeHandle         = kernel32.NewProc("CloseHandle")
)

func watchParent(parentPID int) <-chan struct{} {
	exited := make(chan struct{})
	go func() {
		defer close(exited)
		handle, _, _ := openProcess.Call(
			synchronizeAccess,
			0,
			uintptr(uint32(parentPID)),
		)
		if handle == 0 {
			return
		}
		defer closeHandle.Call(handle)
		result, _, _ := waitForSingleObject.Call(handle, infiniteWait)
		if result != waitObject0 {
			return
		}
	}()
	return exited
}

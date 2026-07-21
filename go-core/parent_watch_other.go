//go:build !windows

package main

func watchParent(_ int) <-chan struct{} {
	return make(chan struct{})
}

// cloak-pay's start, in the Linux guest only (zz_cloak_pay.go says what it
// is). Its init runs before the daemon's main and never returns to it, so
// none of the daemon's own commands runs, its local API among them.
//
// Usage: cloak-pay
// It prints "ready" on standard output once it listens on vsock, and nothing
// else there. Its log goes to standard error: the daemon's request lines,
// which carry no content, and a line for each connection that got no answer.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"

	"golang.org/x/sys/unix"
)

func init() {
	logger := log.New(os.Stderr, "cloak-pay ", log.LstdFlags)
	if err := payMain(os.Args[1:], logger); err != nil {
		logger.Printf("ERROR %s", err)
		os.Exit(1)
	}
	os.Exit(0)
}

func payMain(args []string, logger *log.Logger) error {
	if len(args) != 0 {
		return errors.New("usage: cloak-pay")
	}
	c, err := payConfig()
	if err != nil {
		return err
	}
	life := context.Background()
	p, err := newPay(life, c, logger)
	if err != nil {
		return err
	}
	listener, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	if err := unix.Bind(listener, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: payPort}); err != nil {
		return err
	}
	if err := unix.Listen(listener, unix.SOMAXCONN); err != nil {
		return err
	}
	fmt.Println("ready")
	for {
		fd, peer, err := unix.Accept4(listener, unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC)
		if err != nil {
			return err
		}
		// Non-blocking, so the runtime's poller serves it and a close ends
		// a read waiting on it.
		conn := os.NewFile(uintptr(fd), "vsock")
		if vm, ok := peer.(*unix.SockaddrVM); !ok || !payFromHost(vm.CID) {
			conn.Close()
			continue
		}
		go func() {
			defer conn.Close()
			if err := p.serve(life, conn); err != nil {
				logger.Printf("connection ended with no answer: %s", err)
			}
		}()
	}
}

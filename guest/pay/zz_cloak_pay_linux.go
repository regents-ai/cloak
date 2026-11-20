// cloak-pay's start, in the Linux guest only (zz_cloak_pay.go says what it
// is). Its init runs before the daemon's main and never returns to it, so
// none of the daemon's own commands runs, its local API among them.
//
// Usage: cloak-pay
// It prints "ready" on standard output once it listens on vsock, and nothing
// else there. Its log goes to standard error: the daemon's request lines,
// which carry no content, a line for each connection that got no answer, and
// "stopped" once a SIGTERM has ended it, after which it exits 0.
package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"syscall"

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
	life, stop := payLife()
	defer stop()
	p, err := newPay(life, c, logger)
	if err != nil {
		return err
	}
	listener, err := listenVsock()
	if err != nil {
		return err
	}
	fmt.Println("ready")
	if err := p.run(life, listener); err != nil {
		return err
	}
	logger.Print("stopped")
	return nil
}

// payVsock is the guest's vsock port. Its socket is non-blocking, so the
// runtime's poller serves it and Close ends an Accept waiting: a close from
// another thread does not wake a blocking accept on Linux.
type payVsock struct {
	file *os.File
	raw  syscall.RawConn
}

func listenVsock() (payVsock, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return payVsock{}, err
	}
	file := os.NewFile(uintptr(fd), "vsock")
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: payPort}); err != nil {
		file.Close()
		return payVsock{}, err
	}
	if err := unix.Listen(fd, unix.SOMAXCONN); err != nil {
		file.Close()
		return payVsock{}, err
	}
	raw, err := file.SyscallConn()
	if err != nil {
		file.Close()
		return payVsock{}, err
	}
	return payVsock{file, raw}, nil
}

// Accept gives the next connection from the host; one from anywhere else is
// closed unanswered.
func (v payVsock) Accept() (io.ReadWriteCloser, error) {
	for {
		var fd int
		var peer unix.Sockaddr
		var err error
		if waitErr := v.raw.Read(func(listener uintptr) bool {
			fd, peer, err = unix.Accept4(int(listener), unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC)
			return err != unix.EAGAIN
		}); waitErr != nil {
			return nil, waitErr
		}
		if err != nil {
			return nil, err
		}
		// Non-blocking, so the runtime's poller serves it and a close ends
		// a read waiting on it.
		conn := os.NewFile(uintptr(fd), "vsock")
		if vm, ok := peer.(*unix.SockaddrVM); ok && payFromHost(vm.CID) {
			return conn, nil
		}
		conn.Close()
	}
}

func (v payVsock) Close() error { return v.file.Close() }

// cloak-pay's start, in the Linux guest only (zz_cloak_pay.go says what it
// is). Its init runs before the daemon's main and never returns to it, so
// none of the daemon's own commands runs, its local API among them.
//
// Usage: cloak-pay
// It keeps its configuration in the daemon's default folder,
// $HOME/.config/zkapi-clientd (the payer's home is the payment disk), starts
// its companion and waits for it, then prints "ready" on standard output once
// it listens on vsock, and nothing else there. Its log goes to standard
// error: "wallet: no note" or "wallet: a note" once the companion answers,
// the daemon's request lines, which carry no content, a line for each
// connection that got no answer, and "stopped" once a SIGTERM has ended it,
// after which it exits 0. The companion's end ends it, as it ends the
// daemon's serve, and it exits 1.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/config"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/relay"
	"github.com/ethereum/zkapi/zkapi-clientd/internal/zkapi"
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
	dir, err := config.DefaultDir()
	if err != nil {
		return err
	}
	if err := config.EnsureDir(dir); err != nil {
		return err
	}
	signalled, stop := payLife()
	defer stop()
	life, end := context.WithCancel(signalled)
	companion, err := startPayCompanion(life, c, dir)
	if err != nil {
		end()
		return err
	}
	defer func() {
		end()
		<-companion.done
		companion.proxy.Close()
	}()
	go func() {
		<-companion.done
		end()
	}()
	p, err := newPay(life, c, dir, logger)
	if err != nil {
		return err
	}
	if err := waitCompanion(life, c); err != nil {
		return err
	}
	readiness, err := p.wallet.Readiness(life)
	if err != nil {
		return err
	}
	state := "no note"
	if readiness.HasNote {
		state = "a note"
	}
	logger.Printf("wallet: %s", state)
	listener, err := listenVsock()
	if err != nil {
		return err
	}
	fmt.Println("ready")
	if err := p.run(life, listener); err != nil {
		return err
	}
	if signalled.Err() == nil {
		return errors.New("the companion stopped")
	}
	logger.Print("stopped")
	return nil
}

// payCompanion is the companion, run as the daemon's serveSnapshot runs it:
// zkapi.CompanionCommand behind relay.StartConnectProxy, with its state in
// the configuration folder's zkapi, its output discarded (it may hold wallet
// details), a SIGTERM when its context ends and a kill 5 s later. done closes
// once it has ended.
type payCompanion struct {
	proxy *relay.ConnectProxy
	done  chan struct{}
}

func startPayCompanion(ctx context.Context, c config.Config, dir string) (*payCompanion, error) {
	client, err := relay.NewClient(c.RelayURL)
	if err != nil {
		return nil, err
	}
	proxy, err := relay.StartConnectProxy(ctx, c.RelayURL)
	if err != nil {
		return nil, err
	}
	cmd, err := zkapi.CompanionCommand(ctx, zkConfig(c, client), zkapi.CompanionConfig{Binary: c.ZKAPI.Binary,
		SetupDir: c.ZKAPI.ProofSetupDir, StateDir: filepath.Join(dir, "zkapi"), VerifierURL: c.VerifierURL, ProxyURL: proxy.URL})
	if err != nil {
		proxy.Close()
		return nil, err
	}
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 5 * time.Second
	if err := cmd.Start(); err != nil {
		proxy.Close()
		return nil, errors.New("failed to start zkAPI companion")
	}
	companion := &payCompanion{proxy: proxy, done: make(chan struct{})}
	go func() {
		_ = cmd.Wait()
		close(companion.done)
	}()
	return companion, nil
}

// waitCompanion waits as the daemon's guided start waits (start.go), with its
// check and its pace: until the companion answers its wallet status, or the
// time allowed ends, or ctx does.
func waitCompanion(ctx context.Context, c config.Config) error {
	runtime := configuredRuntime(c)
	ctx, cancel := context.WithTimeout(ctx, runtime.timeout)
	defer cancel()
	for runtime.companion(ctx, c) != nil {
		select {
		case <-ctx.Done():
			return errors.New("the companion did not start")
		case <-time.After(runtime.interval):
		}
	}
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

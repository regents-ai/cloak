// Command cloak-tor-port is the guest's Tor port, its one way out (Decision 5
// in docs/plan.md). It listens where the reference's tor listens, so the
// daemon's Tor route and the torsocks settings stay as they are, and carries
// each connection's bytes unchanged over vsock to the host (CID 2, port 9050).
// The host passes a connection on to tor only if it opens with a SOCKS5
// greeting, and closes anything else. This program reads nothing, adds
// nothing and connects nowhere else; the guest has no network device.
package main

import (
	"fmt"
	"io"
	"log"
	"net"

	"github.com/mdlayher/vsock"
)

const (
	listen   = "127.0.0.1:9050"
	hostCID  = 2
	hostPort = 9050
)

func main() {
	log.SetFlags(0)
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatal(err)
	}
	// The guest's boot waits for this one line before it runs the daemon.
	fmt.Println("ready")
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go carry(conn)
	}
}

// carry copies both ways until either end closes, then closes both: tor
// ends a stream whose client stops sending, so nothing is lost.
func carry(guest net.Conn) {
	defer guest.Close()
	host, err := vsock.Dial(hostCID, hostPort, nil)
	if err != nil {
		return
	}
	defer host.Close()
	ended := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(host, guest); ended <- struct{}{} }()
	go func() { _, _ = io.Copy(guest, host); ended <- struct{}{} }()
	<-ended
}

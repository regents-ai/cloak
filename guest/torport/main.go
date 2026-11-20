// Command cloak-port carries one of the guest's ports to the host: it listens
// on 127.0.0.1:<port> and carries each connection's bytes unchanged over
// vsock to the host (CID 2) on the same port. The guest runs it for two
// ports, each as its own user:
//
//   - 9050, the Tor port, the guest's one way out (Decision 5 in
//     docs/plan.md). It listens where the reference's tor listens, so the
//     daemon's Tor route and the torsocks settings stay as they are. The host
//     passes a connection on to tor only if it opens with a SOCKS5 greeting,
//     and closes anything else. A guest with the payment disk runs a second
//     one in the payer's own network namespace, the payer's one way out.
//   - 8742, the door port, in a guest that serves (decision 12): where the
//     agent's model requests go, to the app's door on the Mac, which checks
//     each request's pass as it checks any app's.
//
// This program reads nothing, adds nothing and connects nowhere else; the
// guest has no network device.
package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"

	"github.com/mdlayher/vsock"
)

const hostCID = 2

func main() {
	log.SetFlags(0)
	if len(os.Args) != 2 {
		log.Fatal("usage: cloak-port <port>")
	}
	port, err := strconv.ParseUint(os.Args[1], 10, 16)
	if err != nil || port == 0 {
		log.Fatal("usage: cloak-port <port>")
	}
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		log.Fatal(err)
	}
	// The guest's boot waits for this one line before it goes on.
	fmt.Println("ready")
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go carry(conn, uint32(port))
	}
}

// carry copies both ways until either end closes, then closes both. tor ends
// a stream whose client stops sending, so nothing is lost there; on the door
// port, a client that stops sending before its answer has come loses it.
func carry(guest net.Conn, port uint32) {
	defer guest.Close()
	host, err := vsock.Dial(hostCID, port, nil)
	if err != nil {
		return
	}
	defer host.Close()
	ended := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(host, guest); ended <- struct{}{} }()
	go func() { _, _ = io.Copy(guest, host); ended <- struct{}{} }()
	<-ended
}

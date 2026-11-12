// Command cloak-vsock-probe is an instrument for the routing checks, not
// part of the path. It is static, so torsocks never loads into it, and it
// talks vsock to the host directly, past the guest's Tor port, as any guest
// program could:
//
//	cloak-vsock-probe <port> <bytes>
//
// It connects to the host (CID 2) on the port, sends the bytes (Go escapes
// such as \x05 are read), and prints the first answer: "refused (...)" when
// nothing listens there, "closed, no answer (...)" when the host closed
// without a byte, or "answered <hex>".
package main

import (
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/mdlayher/vsock"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: cloak-vsock-probe <port> <bytes>")
		os.Exit(2)
	}
	port, err := strconv.ParseUint(os.Args[1], 10, 32)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	payload, err := strconv.Unquote(`"` + os.Args[2] + `"`)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	conn, err := vsock.Dial(2, uint32(port), nil)
	if err != nil {
		fmt.Printf("refused (%v)\n", err)
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := io.WriteString(conn, payload); err != nil {
		fmt.Printf("closed, no answer (%v)\n", err)
		return
	}
	answer := make([]byte, 512)
	n, err := conn.Read(answer)
	if n == 0 {
		fmt.Printf("closed, no answer (%v)\n", err)
		return
	}
	fmt.Printf("answered %s\n", hex.EncodeToString(answer[:n]))
}

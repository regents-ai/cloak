// Command cloak-adapter is the guest end of the rewrite channel (spec section
// 7). It listens on guest loopback where the daemon's rewriter URL points,
// accepts only the daemon's authenticated chat request, and carries the bytes
// unchanged over vsock to the host, which relays them to the native worker.
// The reply comes back the same way. It adds nothing, repairs nothing and
// forwards nothing else; the daemon's reply checks stay authoritative.
//
// Channel to the host, per request: a new vsock connection to the host (CID 2)
// that starts with the 32-byte host token, then one frame: kind 'R', a 4-byte
// big-endian length and the request body. The host answers with kind 'A', a
// 4-byte length, a 2-byte big-endian HTTP status and the reply body. Closing
// the connection before the answer cancels the rewrite.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"

	"github.com/mdlayher/vsock"
)

const (
	listen       = "127.0.0.1:8012"
	hostCID      = 2
	hostPort     = 8012
	maxRequest   = 1 << 20
	maxReply     = 1<<20 + 1 // one byte over the daemon's limit, so the daemon still decides
	tokenPath    = "/run/cloak/adapter-token"
	rewriterPath = "/run/cloak/rewriter-key"
)

type adapter struct {
	token []byte // host channel token, 32 bytes
	key   string // the daemon's rewriter API key
}

func main() {
	log.SetFlags(0)
	token, err := readSecret(tokenPath)
	if err != nil {
		log.Fatal(err)
	}
	raw, err := hex.DecodeString(token)
	if err != nil || len(raw) != 32 {
		log.Fatal("adapter token must be 32 bytes in hex")
	}
	key, err := readSecret(rewriterPath)
	if err != nil {
		log.Fatal(err)
	}
	a := &adapter{token: raw, key: key}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatal(err)
	}
	// The guest's init waits for this one line before it runs the daemon.
	fmt.Println("ready")
	server := &http.Server{Handler: a, ErrorLog: log.New(io.Discard, "", 0)}
	log.Fatal(server.Serve(ln))
}

func readSecret(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func (a *adapter) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/chat/completions" || r.URL.RawQuery != "" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+a.key)) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequest))
	if err != nil {
		http.Error(w, "request too large", http.StatusRequestEntityTooLarge)
		return
	}
	conn, err := vsock.Dial(hostCID, hostPort, nil)
	if err != nil {
		http.Error(w, "rewriter unavailable", http.StatusBadGateway)
		return
	}
	defer conn.Close()
	// The daemon closing its request (its own deadline, or cancellation)
	// closes the channel, which cancels the rewrite on the host.
	stop := context.AfterFunc(r.Context(), func() { conn.Close() })
	defer stop()

	status, reply, err := a.exchange(conn, body)
	if err != nil {
		http.Error(w, "rewriter unavailable", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = io.Copy(w, reply)
}

func (a *adapter) exchange(conn net.Conn, body []byte) (int, io.Reader, error) {
	frame := make([]byte, 0, 32+5+len(body))
	frame = append(frame, a.token...)
	frame = append(frame, 'R')
	frame = binary.BigEndian.AppendUint32(frame, uint32(len(body)))
	frame = append(frame, body...)
	if _, err := conn.Write(frame); err != nil {
		return 0, nil, err
	}
	var header [7]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(header[1:5])
	if header[0] != 'A' || length < 2 {
		return 0, nil, errors.New("unexpected frame from host")
	}
	status := int(binary.BigEndian.Uint16(header[5:7]))
	if status < 200 || status > 599 {
		return 0, nil, fmt.Errorf("status %d from host", status)
	}
	return status, io.LimitReader(conn, min(int64(length)-2, maxReply)), nil
}

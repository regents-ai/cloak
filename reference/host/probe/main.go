// probe is a statically linked program that asks check.torproject.org whether
// its own HTTPS request arrived through Tor, and whether it can send a UDP
// DNS query. Statically linked programs ignore torsocks' LD_PRELOAD, so this
// shows whether the sandbox itself stops a direct connection. It prints
// whether the request came through Tor, never the address it came from.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"time"
)

func main() {
	// Resolve names directly at 1.1.1.1, as any program that ships its own
	// resolver does, instead of through a system resolver file.
	resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "udp", "1.1.1.1:53")
	}}
	dialer := &net.Dialer{Resolver: resolver}
	client := http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{DialContext: dialer.DialContext}}
	resp, err := client.Get("https://check.torproject.org/api/ip")
	if err != nil {
		fmt.Printf("tcp: blocked (%v)\n", err)
	} else {
		var body struct{ IsTor bool }
		json.NewDecoder(resp.Body).Decode(&body)
		resp.Body.Close()
		fmt.Printf("tcp: connected, through Tor: %v\n", body.IsTor)
	}

	conn, err := net.DialTimeout("udp", "1.1.1.1:53", 5*time.Second)
	if err == nil {
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		// DNS query for example.com, type A.
		query := []byte{0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1}
		if _, err = conn.Write(query); err == nil {
			_, err = conn.Read(make([]byte, 512))
		}
		conn.Close()
	}
	if err != nil {
		fmt.Printf("udp dns: blocked (%v)\n", err)
	} else {
		fmt.Println("udp dns: answered directly")
	}
}

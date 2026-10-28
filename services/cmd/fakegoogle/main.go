// Command fakegoogle serves the test Google (pkg/fakegoogle): an invented
// inbox and calendar, and an OAuth that consents at once. Run it, set
// ASEMAN_FAKE_GOOGLE_URL to its address and restart the node.
//
//	go run ./cmd/fakegoogle -addr 127.0.0.1:4900
package main

import (
	"flag"
	"log"
	"net/http"

	"github.com/aseman/aseman/pkg/fakegoogle"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:4900", "listen address")
	flag.Parse()
	log.Printf("fake Google on http://%s (signs in as %s)", *addr, fakegoogle.Owner)
	log.Fatal(http.ListenAndServe(*addr, fakegoogle.New()))
}

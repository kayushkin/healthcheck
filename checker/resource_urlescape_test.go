package checker

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// urlProbes are the session ids the bridge can mint. Only the first is
// well-formed; the rest each carry a byte that means something to a URL path.
//
// Which probe carries which arm is a measurement, not a guess (see the README
// beside this repo's instruments):
//
//   - "sess one" cannot witness the defect at all. net/url escapes a raw space
//     to %20 unaided, so it round-trips correctly whether or not the caller
//     escapes. It is here only as a PathEscape-vs-QueryEscape control: those
//     two disagree on it (%20 against +) and on "sess?replay=1" (= against
//     %3D), and on nothing else in this list.
//   - The other five are defect witnesses.
var urlProbes = []string{
	"sess_01HXYZ",   // well-formed control — must pass before and after
	"sess#frag",     // # truncates the path at a fragment
	"sess?replay=1", // ? truncates the path at a query
	"a/b",           // an extra path segment
	"../instances",  // climbs out of /sessions/ entirely
	"sess one",      // wrong-repair control only; see above
	"sess%2Fb",      // already-encoded; a second escape must not be skipped
}

// assertSendAddressedSession reads the WIRE, not the decoded path. Go's server
// decodes %2F back to a slash before it fills r.URL.Path, so a URL.Path
// assertion reads identically whether or not the client escaped anything — it
// cannot detect this defect in either direction. RequestURI is the raw request
// line.
func assertSendAddressedSession(t *testing.T, requestURI, wantID string) {
	t.Helper()
	u, err := url.ParseRequestURI(requestURI)
	if err != nil {
		t.Fatalf("send request line %q did not parse: %v", requestURI, err)
	}
	if u.RawQuery != "" || u.Fragment != "" {
		t.Fatalf("send for id %q leaked into the query/fragment: request line was %q", wantID, requestURI)
	}
	segs := strings.Split(strings.Trim(u.EscapedPath(), "/"), "/")
	if len(segs) != 3 || segs[0] != "sessions" || segs[2] != "send" {
		t.Fatalf("send for id %q addressed %q, want exactly /sessions/<one segment>/send", wantID, u.EscapedPath())
	}
	got, err := url.PathUnescape(segs[1])
	if err != nil {
		t.Fatalf("send for id %q wrote an undecodable segment %q: %v", wantID, segs[1], err)
	}
	if got != wantID {
		t.Fatalf("send addressed session %q, want %q (request line %q)", got, wantID, requestURI)
	}
}

// newBridgeStubRecording answers a create with the given session id and records
// the raw request line of the send that follows.
func newBridgeStubRecording(t *testing.T, sessionID string, requestURI *string, hit *bool) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/sessions", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"session_id": sessionID})
	})
	// Registering "/" rather than the exact send route is deliberate: a request
	// that escaped /sessions/<id>/send must be RECORDED so the assertion can
	// name where it went, not 404'd into silence.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		*hit = true
		*requestURI = r.RequestURI
		w.WriteHeader(http.StatusOK)
	})
	return httptest.NewServer(mux)
}

func TestSpawnCCAgentSendsToTheSessionTheBridgeMinted(t *testing.T) {
	for _, id := range urlProbes {
		t.Run(id, func(t *testing.T) {
			var requestURI string
			var hit bool
			srv := newBridgeStubRecording(t, id, &requestURI, &hit)
			defer srv.Close()

			c := New(&Config{LLMBridgeURL: srv.URL})
			res := ResourceConfig{Name: "disk-root", Type: "disk", Threshold: 90, CCAgent: true}
			state := &ResourceState{Name: "disk-root", Type: "disk", UsagePct: 97.5, Detail: "1GB free"}
			c.spawnCCAgent(res, state)

			if !hit {
				t.Fatalf("no send request reached the bridge at all for id %q", id)
			}
			assertSendAddressedSession(t, requestURI, id)
		})
	}
}

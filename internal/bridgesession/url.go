// Package bridgesession builds the llm-bridge-server URLs healthcheck calls
// when it escalates an alert into an agent session.
package bridgesession

import (
	"net/url"
	"strings"
)

// SendMessageURL returns the address of the send-message endpoint for one
// bridge session.
//
// sessionID is minted by llm-bridge-server and read back out of the create
// answer, so healthcheck does not choose it and must not assume its shape.
// Concatenating it raw let a '/', a '#' or a '?' in the id re-address the
// request: an id of "../instances" sent the prompt to /instances/send, a
// different endpoint that answers 200. PathEscape keeps the id one path
// segment whatever it contains.
func SendMessageURL(baseURL, sessionID string) string {
	return strings.TrimSuffix(baseURL, "/") + "/sessions/" + url.PathEscape(sessionID) + "/send"
}

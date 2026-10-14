package admin

import "github.com/tradera/tradera/plugins/actions/support/helper"

// Do not expose hashes, encrypted private keys or credentials through generic
// table/query responses.
func redactCredentials(value any) any { return helper.RedactCredentials(value) }

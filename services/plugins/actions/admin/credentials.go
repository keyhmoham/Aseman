package admin

import (
	"encoding/json"
	"strings"
)

// Table inspection bypasses model JSON tags. Do not expose hashes, encrypted
// private keys or credentials through generic table/query responses.
func credentialField(name string) bool {
	name = strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(name, "-", ""), "_", ""))
	if strings.Contains(name, "password") || strings.Contains(name, "secret") || strings.HasSuffix(name, "apikey") || strings.HasSuffix(name, "privatekey") {
		return true
	}
	switch name {
	case "password", "passwordhash", "currentpassword", "newpassword", "apikey", "privatekey", "privatekeyenc", "recoverykeyenc", "token", "tokenhash", "accesstoken", "refreshtoken", "clientsecret", "secret", "secrets", "codehash", "authorization", "cookie", "setcookie", "backendsecret":
		return true
	}
	return false
}

func redactCredentials(value any) any {
	switch v := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, item := range v {
			if credentialField(k) {
				out[k] = "[redacted]"
			} else {
				out[k] = redactCredentials(item)
			}
		}
		return out
	case []map[string]any:
		out := make([]map[string]any, len(v))
		for i, item := range v {
			out[i] = redactCredentials(item).(map[string]any)
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = redactCredentials(item)
		}
		return out
	case json.RawMessage:
		var decoded any
		if json.Unmarshal(v, &decoded) == nil {
			return redactCredentials(decoded)
		}
	case []byte:
		var decoded any
		if json.Unmarshal(v, &decoded) == nil {
			return redactCredentials(decoded)
		}
	case string:
		if strings.HasPrefix(v, "tradera:secret:") || strings.HasPrefix(v, "$2a$") || strings.HasPrefix(v, "$2b$") || strings.HasPrefix(v, "$2y$") {
			return "[redacted]"
		}
		var decoded any
		if len(v) > 0 && (v[0] == '{' || v[0] == '[') && json.Unmarshal([]byte(v), &decoded) == nil {
			return redactCredentials(decoded)
		}
	}
	return value
}

class_name InMemoryAuthIdentityVerifier
extends AuthIdentityVerifier

## Local/CI identity provider. Production can inject another implementation without
## changing lobby, session, or adapter code.

var allow_anonymous := true
var _tokens: Dictionary = {}


func _init(anonymous_allowed := true, token_subjects: Dictionary = {}) -> void:
	allow_anonymous = anonymous_allowed
	for token: Variant in token_subjects:
		var value: Variant = token_subjects[token]
		if value is Dictionary:
			_tokens[String(token)] = (value as Dictionary).duplicate(true)
		else:
			_tokens[String(token)] = {"subject": String(value), "claims": {}}


func verify(auth_context: Dictionary, request_context: Dictionary = {}) -> Dictionary:
	var token := String(auth_context.get("bearer_token", ""))
	if not token.is_empty() and _tokens.has(token):
		var record: Dictionary = _tokens[token]
		var subject := String(record.get("subject", "")).strip_edges()
		if subject.is_empty():
			return V3.reject(V3.REJECT_UNAUTHORIZED, "configured identity has no subject")
		return {
			"ok": true,
			"subject": subject,
			"claims": (record.get("claims", {}) as Dictionary).duplicate(true),
			"provider": "in_memory",
		}
	if not allow_anonymous:
		return V3.reject(V3.REJECT_UNAUTHORIZED, "valid product credential required")
	# Server-owned connection context creates the anonymous subject. Client fields
	# such as identity/reconnect_token are deliberately ignored.
	var peer_id := int(request_context.get("peer_id", 0))
	return {
		"ok": true,
		"subject": "anonymous:%d" % peer_id,
		"claims": {"anonymous": true},
		"provider": "in_memory",
	}

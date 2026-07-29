class_name AuthIdentityVerifier
extends RefCounted

## Product identity boundary for Match Platform V3.
##
## Session recovery tokens never enter this interface. A caller supplies the
## product-auth fields from `join.auth_context` and server-owned request context;
## successful implementations return a stable subject plus non-secret claims.

const V3 = preload("../platform/match_platform_v3.gd")


func verify(_auth_context: Dictionary, _request_context: Dictionary = {}) -> Dictionary:
	return V3.reject(V3.REJECT_UNAUTHORIZED, "identity verifier is not configured")

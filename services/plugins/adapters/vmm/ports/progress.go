package vmm

import "github.com/tradera/tradera/pkg/errs"

// CodeExecutionStalled identifies a bounded execution that stopped making
// progress. Its partial report must still be verified; it is not completion.
const CodeExecutionStalled errs.Code = "EXECUTION_STALLED"

// CodeExecutionTurnLimit is an invocation boundary, independent of token usage.
// The controller verifies receipts and can continue remaining work.
const CodeExecutionTurnLimit errs.Code = "EXECUTION_TURN_LIMIT"

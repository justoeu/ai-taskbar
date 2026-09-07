import Testing

/// Boolean assertions that actually fail when they should.
///
/// The former Apple Swift 6.3.2 / Testing 0.99.0 stack mis-evaluated
/// `Bool`-typed sub-expressions. The following all PASSED with values that
/// made them false, verified by running them:
///
/// ```swift
/// #expect(false == true)                          // passes (!)
/// let x: Bool? = false; #expect(x ?? false)        // passes (!)
/// let x: Bool? = true;  #expect(x.map { !$0 } ?? false)  // passes (!)
/// let x: Bool? = true;  #expect(x == Optional(false))    // passes (!)
/// ```
///
/// and one is inverted outright — `#expect(!(x ?? true))` FAILS for
/// `x == .some(false)`, where plain Swift evaluates the same expression to
/// `true`. Anything the macro can decompose into a boolean comparison is
/// suspect; what it handles correctly is a bare `Bool` identifier, and
/// comparisons of non-`Bool` types (`#expect(3 == 4)` and
/// `#expect(s == "b")` fail correctly).
///
/// These helpers take a plain `Bool` **parameter**, so the condition is
/// evaluated as ordinary Swift at the call site and the macro only ever sees
/// the bare identifier `value`. Verified in all six directions (true / false /
/// nil, for both helpers) before adoption.
///
/// Use these for any condition that involves an optional. A bare non-optional
/// `Bool` — `#expect(flag)` or `#expect(!flag)` — is safe as-is.
/// The bundled-Testing migration retains this convention; negative controls in
/// TestingInfrastructureTests verify that helper failures reach the runner.
public func expectTrue(_ value: Bool,
                       _ comment: Comment? = nil,
                       sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, comment, sourceLocation: sourceLocation)
}

/// Inverse of ``expectTrue(_:_:sourceLocation:)``. Prefer passing the whole
/// condition (e.g. `expectFalse(v?.dropPending ?? true)`) over negating at the
/// call site, so the negation also happens outside the macro.
public func expectFalse(_ value: Bool,
                        _ comment: Comment? = nil,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, comment, sourceLocation: sourceLocation)
}

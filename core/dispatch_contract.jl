# =============================================================================
# B-SPEC Dispatch Contract  —  dispatch_contract.jl
# =============================================================================
#
# This file is the authoritative specification for the DISPATCH PIPELINE
# PROTOCOL: the rule that every result-producing file in B-SPEC (CommandParser,
# SolverRegistry, every solver module, and any future file) must package its
# output as a registered, typed struct and route it through dispatch().
#
# This is a DIFFERENT contract from solver_contract.jl:
#   solver_contract.jl    — governs physics solver MODULES (SolverVariant/fn)
#   dispatch_contract.jl  — governs PIPELINE STAGES (the dispatcher's spine)
#
# A physics solver author reads solver_contract.jl and never needs to touch
# this file. A contributor adding a NEW PIPELINE STAGE (a new kind of
# intermediate result that flows between CommandParser, the Registry, and
# solvers) reads this file.
#
# Reading order for a new contributor extending the pipeline itself:
#   dispatch_contract.jl  →  dispatcher.jl  (reference implementation of
#   the existing 4-stage chain: RegistryLookupResult → VariantSelectionResult
#   → SolverInvocationResult → DispatchResult)
#
# =============================================================================

module DispatchContract

export validate_dispatch_type, DispatchContractViolation

using ..Dispatcher: is_registered_dispatch_type
import ..Dispatcher   # needed so Dispatcher.dispatch is resolvable as a qualified name in R-5


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — THE CONTRACT
# ─────────────────────────────────────────────────────────────────────────────
#
# ── 1.1  THE CORE RULE ───────────────────────────────────────────────────────
#
# Every file in B-SPEC that produces a result destined for another part of
# the system MUST NOT return that result as a bare value (Nothing, a raw
# Dict, an untyped tuple, a thrown exception). It MUST:
#
#   1. Define a dedicated struct for that result
#   2. Register the struct with register_dispatch_type!(StructName)
#   3. Define a dispatch(::StructName) method that:
#        a. Checks the struct's own success/failure state
#        b. On failure, returns a DispatchResult (or calls dispatch() on a
#           failure-carrying value of the NEXT stage, never throws)
#        c. On success, performs this stage's work and produces the NEXT
#           stage's struct, then calls dispatch() on it (tail call —
#           this is what makes the pipeline a chain, not a single function)
#
# This means: no file in B-SPEC is allowed to hand a caller an untyped or
# unioned-with-Nothing result and consider its job done. The result must
# be wrapped, registered, and dispatched.
#
#
# ── 1.2  WHY THIS EXISTS ─────────────────────────────────────────────────────
#
# Before this contract, CommandParser returned Union{ParsedRequest, Nothing},
# SolverRegistry returned Union{SolverEntry, Nothing}, and Dispatcher itself
# absorbed both of those Nothings internally with ad-hoc `=== nothing` checks
# scattered across one large function. That worked, but every NEW file added
# to the system had to reinvent its own ad-hoc error-propagation convention,
# and there was no single place that listed every kind of intermediate result
# the system could produce.
#
# This contract makes the propagation convention explicit and uniform:
# EVERY stage boundary is a registered type, and EVERY transition between
# stages is a dispatch() method. Multiple dispatch (Julia's native mechanism)
# is what selects the correct transition function for a given stage's type —
# there is no manual `if isa(x, Foo)` branching anywhere in the pipeline.
#
#
# ── 1.3  STAGE STRUCT REQUIREMENTS ───────────────────────────────────────────
#
# A pipeline-stage struct MUST contain:
#
#   success   :: Bool
#       Whether this stage completed successfully. Mandatory first field
#       by convention (not enforced by the type system, but expected by
#       every validate_dispatch_type check and by human readers).
#
#   error_msg :: Union{String, Nothing}
#       Populated iff success == false. Mandatory.
#
# A pipeline-stage struct SHOULD contain:
#
#   Enough of the previous stage's context (request, entry, variant, etc.)
#   that the NEXT stage's dispatch() method can do its work without needing
#   any global state. Prefer carrying the previous stage's struct forward
#   wrapped inside the new one (see SolverInvocationResult.variant in
#   dispatcher.jl, which carries the entire VariantSelectionResult forward)
#   over re-deriving values from scratch.
#
# A pipeline-stage struct MUST NOT:
#
#   ✗  Contain a bare Union{T, Nothing} field for its PAYLOAD without a
#      corresponding success::Bool to disambiguate — i.e. don't make the
#      caller infer success from whether a field is nothing; say so directly.
#   ✗  Be mutable (no `mutable struct`) — pipeline stages are immutable
#      snapshots; mutation invites the exact non-determinism this contract
#      exists to eliminate.
#   ✗  Hold a reference to itself or create a registration cycle.
#
#
# ── 1.4  REGISTRATION ────────────────────────────────────────────────────────
#
# Immediately after defining the struct:
#
#   struct MyNewStageResult
#       success   :: Bool
#       error_msg :: Union{String, Nothing}
#       # ... stage-specific fields ...
#   end
#
#   register_dispatch_type!(MyNewStageResult)
#
# Registration is a Set{DataType} membership add — O(1), happens once at
# module load, and costs nothing on the hot path. It exists purely so the
# dispatcher's catch-all fallback (Section 5 of dispatcher.jl) can tell the
# difference between:
#   "this type was never registered" (tell the author to register it)
#   "this type IS registered but has no dispatch() method" (a real bug)
# rather than emitting the same opaque MethodError for both.
#
#
# ── 1.5  THE dispatch() METHOD ───────────────────────────────────────────────
#
# Immediately after registration, define exactly one new method of dispatch:
#
#   function dispatch(stage::MyNewStageResult)::DispatchResult  # or next-stage type
#       if !stage.success
#           return _final_err(stage.error_msg)   # or propagate to next stage's err constructor
#       end
#       # ... do this stage's work ...
#       next_stage = ...
#       return dispatch(next_stage)               # tail call into the next stage
#   end
#
# RULES for this method:
#
#   ✓  MUST be named exactly `dispatch`, with a single positional argument
#      typed to your new struct — this is what makes Julia's multiple
#      dispatch select it automatically; no manual routing table needed.
#   ✓  MUST check `stage.success` first and short-circuit on failure.
#   ✓  MUST NOT throw under normal operation. If you call into code that
#      might throw (e.g. invoking a solver function), wrap it in try/catch
#      and convert the caught exception into a failure-state struct for
#      THIS stage or the next one — see dispatch(::VariantSelectionResult)
#      in dispatcher.jl for the canonical pattern.
#   ✓  MUST end by either returning a terminal DispatchResult directly, or
#      calling dispatch() on the next stage's struct. Never return a bare
#      stage struct to a caller outside the chain.
#
#
# ── 1.6  NAMING CONVENTIONS ──────────────────────────────────────────────────
#
# Stage struct names: PascalCase, ending in "Result", describing WHAT WAS
# ATTEMPTED, not what stage number it is — e.g. RegistryLookupResult, not
# Stage1Result. Stage numbers shift as the pipeline grows; descriptive names
# don't.
#
# File location: stage structs for the CORE pipeline live in dispatcher.jl
# itself (Section 2). A stage struct for a NEW, optional pipeline extension
# (e.g. a caching layer, a logging stage) should live in its own file and
# `using ..Dispatcher: register_dispatch_type!` to hook in, rather than
# editing dispatcher.jl directly.


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — VALIDATOR
# ─────────────────────────────────────────────────────────────────────────────

struct DispatchContractViolation <: Exception
    type_name :: Symbol
    rule      :: String
end

Base.showerror(io::IO, e::DispatchContractViolation) =
    print(io, "DispatchContractViolation [$(e.type_name)]: $(e.rule)")

"""
    validate_dispatch_type(t::Type{T}) where T -> Vector{DispatchContractViolation}

Structural checks on a pipeline-stage type that can be verified via
reflection, without needing an instance. Returns an empty vector if
compliant.

    using .DispatchContract: validate_dispatch_type
    @test isempty(validate_dispatch_type(Dispatcher.RegistryLookupResult))
"""
function validate_dispatch_type(t::Type{T}) where T
    violations = DispatchContractViolation[]
    name = nameof(T)

    # R-1: must be registered
    if !is_registered_dispatch_type(T)
        push!(violations, DispatchContractViolation(name,
            "Type is not registered. Call register_dispatch_type!($(name))."))
    end

    # R-2: must be immutable
    if ismutabletype(T)
        push!(violations, DispatchContractViolation(name,
            "Pipeline-stage types must be immutable (struct, not mutable struct)."))
    end

    fnames = fieldnames(T)
    ftypes = T.types

    # R-3: must have a `success` field, and it must be exactly Bool
    if :success ∉ fnames
        push!(violations, DispatchContractViolation(name,
            "Missing required field `success::Bool`."))
    else
        idx = findfirst(==(:success), fnames)
        if ftypes[idx] !== Bool
            push!(violations, DispatchContractViolation(name,
                "Field `success` must be exactly Bool, got $(ftypes[idx])."))
        end
    end

    # R-4: must have an `error_msg` field, and it must allow Nothing
    if :error_msg ∉ fnames
        push!(violations, DispatchContractViolation(name,
            "Missing required field `error_msg::Union{String,Nothing}`."))
    else
        idx = findfirst(==(:error_msg), fnames)
        t = ftypes[idx]
        ok = t === Union{String, Nothing} || t === Union{Nothing, String}
        if !ok
            push!(violations, DispatchContractViolation(name,
                "Field `error_msg` must be Union{String,Nothing}, got $(t)."))
        end
    end

    # R-5: a corresponding dispatch(::T) method must exist.
    # Resolved directly against the Dispatcher module (imported above) —
    # no guessing through Main, which would fail whenever this validator
    # runs inside BSPEC or any other wrapping module.
    if !hasmethod(Dispatcher.dispatch, Tuple{T})
        push!(violations, DispatchContractViolation(name,
            "No dispatch(::$(name)) method found in Dispatcher."))
    end

    return violations
end

end # module DispatchContract
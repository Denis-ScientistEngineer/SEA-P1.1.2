module Dispatcher

# ── Public API ────────────────────────────────────────────────────────────────
export dispatch, DispatchResult, DispatchError,
       RegistryLookupResult, VariantSelectionResult, SolverInvocationResult,
       register_dispatch_type!, is_registered_dispatch_type, list_dispatch_types

using ..SolverRegistry: get_solver, SolverEntry, SolverVariant
using ..CommandParser: ParsedRequest

# =============================================================================
# SECTION 1 — THE DISPATCH TYPE REGISTRY
# =============================================================================
#
# Every wrapper type that flows through dispatch() must be registered here
# before the dispatcher will accept it. This is the formal analogue of
# SolverRegistry for physics solvers: just as a solver must register!() before
# the system will route requests to it, a pipeline-stage type must register
# itself before dispatch() will route data through it.
#
# Registration happens once, at module load, via register_dispatch_type!().
# It is NOT a permission check on every call (that would cost a hash lookup
# per dispatch — wasteful on a hot path). It exists so that:
#   1. A clear, typed error is produced for genuinely unknown types
#      (see Section 5 — the catch-all dispatch(x::Any) method)
#   2. The system can introspect which stage types exist (diagnostics, docs)
#   3. Adding a new pipeline stage is a deliberate, visible act — not an
#      accidental MethodError discovered at runtime in production

const DISPATCH_TYPE_REGISTRY = Set{DataType}()

"""
    register_dispatch_type!(t::Type{T}) where T

Register a type as a known dispatch-pipeline payload. Call this once,
immediately after defining a new wrapper struct, e.g.:

    struct MyNewStageResult
        ...
    end
    register_dispatch_type!(MyNewStageResult)

After registration, you must also define a `dispatch(x::MyNewStageResult)`
method — registration alone does not give the type behaviour, it only
silences the "type not registered" diagnostic in the catch-all fallback.
"""
function register_dispatch_type!(t::Type{T}) where T
    push!(DISPATCH_TYPE_REGISTRY, T)
    return nothing
end

"""
    is_registered_dispatch_type(t::Type{T}) where T -> Bool
"""
is_registered_dispatch_type(t::Type{T}) where T = T ∈ DISPATCH_TYPE_REGISTRY

"""
    list_dispatch_types() -> Vector{DataType}

All currently registered pipeline-stage types, sorted by name for stable
diagnostic output.
"""
list_dispatch_types() = sort!(collect(DISPATCH_TYPE_REGISTRY); by = string)


# =============================================================================
# SECTION 2 — PIPELINE STAGE TYPES
# =============================================================================
#
# The pipeline is a chain of dispatch() calls, each consuming one stage's
# typed output and producing the next stage's typed input:
#
#   ParsedRequest
#     ↓ dispatch(::ParsedRequest)
#   RegistryLookupResult
#     ↓ dispatch(::RegistryLookupResult)
#   VariantSelectionResult
#     ↓ dispatch(::VariantSelectionResult)
#   SolverInvocationResult
#     ↓ dispatch(::SolverInvocationResult)
#   DispatchResult                          ← terminal, returned to caller
#
# Every stage struct carries its OWN success/failure state. A failure at
# stage N does not throw — it produces a valid stage-N struct with
# success=false, and the dispatch(::StageN) method for that struct
# short-circuits straight to a failed DispatchResult without attempting
# the next stage. This is what makes the pipeline crash-proof: there is no
# point at which a Union{T,Nothing} or a thrown exception crosses a
# dispatch() boundary. Every boundary is a concrete, registered type.

# ── Stage 1 output: did the registry have a SolverEntry for this request? ───

struct RegistryLookupResult
    success  :: Bool
    request  :: ParsedRequest
    entry    :: Union{SolverEntry, Nothing}   # present iff success
    error_msg:: Union{String, Nothing}        # present iff !success
end

register_dispatch_type!(RegistryLookupResult)

# ── Stage 2 output: did a SolverVariant match the provided variables? ───────

struct VariantSelectionResult
    success  :: Bool
    request  :: ParsedRequest
    variant  :: Union{SolverVariant, Nothing} # present iff success
    error_msg:: Union{String, Nothing}        # present iff !success
end

register_dispatch_type!(VariantSelectionResult)

# ── Stage 3 output: did the solver function execute and return a finite value? ─

struct SolverInvocationResult
    success    :: Bool
    variant    :: VariantSelectionResult      # carries the variant + request forward
    raw_value  :: Union{Float64, Nothing}      # present iff success
    error_msg  :: Union{String, Nothing}       # present iff !success
end

register_dispatch_type!(SolverInvocationResult)

# ── Terminal stage: what the caller actually receives ────────────────────────

struct DispatchResult
    success      :: Bool
    value        :: Union{Float64, Nothing}
    solves_for   :: Union{Symbol,  Nothing}
    description  :: Union{String,  Nothing}
    error_msg    :: Union{String,  Nothing}
end

register_dispatch_type!(DispatchResult)

# ── A distinct, explicit error type for dispatcher-internal problems ────────
# (unregistered types, pipeline contract violations) — kept separate from
# DispatchResult so a solver/physics failure is never confused with a
# dispatcher plumbing failure.

struct DispatchError
    stage     :: Symbol     # which pipeline stage raised this, or :unregistered_type
    message   :: String
    bad_value :: Any        # the offending value, for diagnostics — never re-dispatched
end

register_dispatch_type!(DispatchError)


# =============================================================================
# SECTION 3 — CONVENIENCE CONSTRUCTORS
# =============================================================================

_lookup_ok(req, entry)     = RegistryLookupResult(true,  req, entry,   nothing)
_lookup_err(req, msg)       = RegistryLookupResult(false, req, nothing, msg)

_variant_ok(req, v)         = VariantSelectionResult(true,  req, v,       nothing)
_variant_err(req, msg)      = VariantSelectionResult(false, req, nothing, msg)

_invoke_ok(vsel, val)       = SolverInvocationResult(true,  vsel, val,     nothing)
_invoke_err(vsel, msg)      = SolverInvocationResult(false, vsel, nothing, msg)

_final_ok(val, sym, desc)   = DispatchResult(true,  val,     sym,  desc,    nothing)
_final_err(msg)             = DispatchResult(false, nothing, nothing, nothing, msg)


# =============================================================================
# SECTION 4 — THE DISPATCH CHAIN (multiple dispatch on pipeline stage type)
# =============================================================================

# ── Stage 1: ParsedRequest → RegistryLookupResult ────────────────────────────
#
# Entry point of the whole pipeline. Looks up the SolverEntry for the
# request's (regime, domain, field) triple. Nothing from get_solver() is
# absorbed HERE — it never travels past this function as a bare Nothing.

function dispatch(req::ParsedRequest)::DispatchResult
    entry = get_solver(req.regime, req.domain, req.field)

    lookup_result = if entry === nothing
        _lookup_err(req,
            "No solver registered for ($(req.regime), $(req.domain), $(req.field)). " *
            "Check spelling or register a new solver."
        )
    else
        _lookup_ok(req, entry)
    end

    return dispatch(lookup_result)
end

# ── Stage 2: RegistryLookupResult → VariantSelectionResult ──────────────────
#
# If stage 1 failed, short-circuit straight to a failed DispatchResult —
# do NOT attempt variant selection on a missing entry.

function dispatch(lookup::RegistryLookupResult)::DispatchResult
    if !lookup.success
        return _final_err(lookup.error_msg)
    end

    entry = lookup.entry::SolverEntry   # type-asserted: success=true guarantees this
    req   = lookup.request

    variant = _select_variant(entry, req.variables)

    selection_result = if variant === nothing
        needed = join(
            ["$(v.solves_for): needs $(join(v.required_vars, ", "))"
             for v in entry.variants],
            " | "
        )
        provided = join(string.(keys(req.variables)), ", ")
        _variant_err(req,
            "No variant of $(req.field) matched the provided variables " *
            "($(provided)). Available variants: [$needed]"
        )
    else
        _variant_ok(req, variant)
    end

    return dispatch(selection_result)
end

# ── Stage 3: VariantSelectionResult → SolverInvocationResult ────────────────
#
# If stage 2 failed, short-circuit. Otherwise invoke the solver's fn,
# catching any exception so it never escapes as a raw Julia error.

function dispatch(selection::VariantSelectionResult)::DispatchResult
    if !selection.success
        return _final_err(selection.error_msg)
    end

    variant = selection.variant::SolverVariant
    req     = selection.request

    invocation_result = try
        val = variant.fn(req.variables)
        _invoke_ok(selection, val)
    catch e
        _invoke_err(selection, "Solver error in $(req.field): $(sprint(showerror, e))")
    end

    return dispatch(invocation_result)
end

# ── Stage 4 (terminal): SolverInvocationResult → DispatchResult ─────────────
#
# Final numeric validation (isfinite) and packaging into the type the
# caller actually receives.

function dispatch(invocation::SolverInvocationResult)::DispatchResult
    if !invocation.success
        return _final_err(invocation.error_msg)
    end

    val     = invocation.raw_value::Float64
    variant = invocation.variant.variant::SolverVariant
    req     = invocation.variant.request

    if !isfinite(val)
        return _final_err(
            "Solver returned non-finite result ($(val)) for $(req.field). " *
            "Check input values for physical validity."
        )
    end

    return _final_ok(val, variant.solves_for, variant.description)
end

# ── Terminal type dispatching on itself: idempotent pass-through ────────────
#
# If something downstream already holds a DispatchResult and calls
# dispatch() on it again (e.g. a retry path, or batch code that re-dispatches
# uniformly without checking type first), this is a safe no-op rather than
# falling through to the catch-all "unregistered type" error.

dispatch(result::DispatchResult)::DispatchResult = result


# =============================================================================
# SECTION 5 — CATCH-ALL: UNREGISTERED / UNKNOWN TYPES
# =============================================================================
#
# This is the formal realisation of "the dispatcher catches its own format
# errors and can request that data format be registered." Any value of a
# type with no specific dispatch(::T) method falls through to this method
# (Julia's multiple dispatch picks the most specific method; this Any
# fallback is the least specific, so it only fires when nothing better
# matches). We distinguish two cases:
#
#   1. The type IS registered (someone called register_dispatch_type!) but
#      forgot to write the corresponding dispatch(::T) method — this is a
#      genuine bug in the dispatcher itself, reported as such.
#   2. The type is NOT registered at all — this is the expected path for
#      a truly new, unregistered format. We name the type explicitly and
#      tell the caller it needs registration, rather than letting Julia's
#      raw MethodError leak through.

function dispatch(x::T) where T
    if is_registered_dispatch_type(T)
        return DispatchError(
            :dispatcher_internal,
            "Type $(T) is registered but has no dispatch(::$(T)) method defined. " *
            "This is a Dispatcher bug — add a method, not a registration.",
            x
        )
    else
        return DispatchError(
            :unregistered_type,
            "Received unrecognised type $(T). New pipeline-stage types must call " *
            "register_dispatch_type!($(T)) and define dispatch(::$(T)) before " *
            "the dispatcher will route them.",
            x
        )
    end
end


# =============================================================================
# SECTION 6 — INTERNAL HELPERS
# =============================================================================

# Chooses the first SolverVariant whose required_vars are all present in the
# user's variable Dict. Order in SolverEntry.variants encodes priority.
function _select_variant(entry::SolverEntry, vars::Dict)::Union{SolverVariant, Nothing}
    for variant in entry.variants
        if all(haskey(vars, v) for v in variant.required_vars)
            return variant
        end
    end
    return nothing
end


# =============================================================================
# SECTION 7 — BATCH DISPATCH
# =============================================================================

"""
    dispatch(reqs::AbstractVector{ParsedRequest}) -> Vector{DispatchResult}

Pre-allocated batch dispatch. Each request runs the full chain
independently; a failure at any stage for one request never affects
the others.
"""
function dispatch(reqs::AbstractVector{ParsedRequest})::Vector{DispatchResult}
    results = Vector{DispatchResult}(undef, length(reqs))
    @inbounds for i in eachindex(reqs)
        results[i] = dispatch(reqs[i])
    end
    return results
end

end # module Dispatcher
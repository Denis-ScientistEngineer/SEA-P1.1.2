# =============================================================================
# B-SPEC Solver Contract  —  solver_contract.jl
# =============================================================================
#
# This file is the authoritative specification for every physics solver module
# in B-SPEC. It is NOT executable on its own. It contains:
#
#   1. The obligations every solver module MUST satisfy
#   2. The obligations the system (Dispatcher + Registry) provides in return
#   3. A reference template to copy when building a new solver
#   4. A compile-time validator (validate_solver_entry) you can call in tests
#
# Reading order for a new contributor:
#   solver_contract.jl  →  solver_registry.jl  →  dispatcher.jl
#   →  electric_field_solver.jl  (reference implementation)
#
# =============================================================================

module SolverContract

export validate_solver_entry, ContractViolation

using ..SolverRegistry: SolverVariant, SolverEntry
using ..CommandParser:  VarValue


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — THE CONTRACT (read this before writing any solver)
# ─────────────────────────────────────────────────────────────────────────────
#
# The contract governs the boundary between:
#
#   [CommandParser] → ParsedRequest → [Dispatcher] → SolverVariant.fn → Float64
#                                           ↕
#                                    [SolverRegistry]
#
# Every solver module is a supplier of SolverVariant functions to the registry.
# The Dispatcher is the sole consumer of those functions. The contract defines
# what each side must guarantee so they can evolve independently.
#
#
# ── 1.1  MODULE STRUCTURE (what a solver file must contain) ──────────────────
#
#   module XxxSolver                         # name ends in "Solver"
#
#       export register!                     # exactly one public export
#
#       using ..SolverRegistry: SolverVariant, SolverEntry, register_solver!
#
#       # Optional: module-level physical constants (const, typed Float64)
#       # Optional: a private _get() helper (see Section 1.4)
#
#       # Private variant functions — see Section 1.3
#       function _result_from_inputs(vars) ... end
#
#       # Private assembly function — see Section 1.5
#       function _build_entry()::SolverEntry ... end
#
#       # Public registration function — see Section 1.6
#       function register!()
#           register_solver!(_build_entry())
#           return nothing
#       end
#
#       register!()   # auto-register on module load — REQUIRED
#
#   end # module XxxSolver
#
#
# ── 1.2  IDENTITY FIELDS (how the Dispatcher finds your solver) ──────────────
#
# Every SolverEntry carries three Symbol identity fields:
#
#   regime  — top-level physics pillar
#   domain  — sub-discipline within the regime
#   field   — the specific physical concept being solved
#
# LEGAL VALUES (extend _KNOWN_SYMBOLS in command_parser.jl when adding new ones):
#
#   regime  :ClassicalMechanics | :StatisticalMechanics
#           :QuantumMechanics   | :RelativisticMechanics
#           :Electromagnetism
#
#   domain  :Electrostatics | :Circuits | :Magnetostatics | :Electrodynamics
#           :SolidMechanics | :FluidMechanics | :Thermodynamics
#           :Kinematics     | :Dynamics       | :WavesOptics
#
#   field   Any UpperCamelCase symbol uniquely naming the physics concept,
#           e.g. :ElectricField, :OhmsLaw, :BeamDeflection, :CoulombsLaw
#
# RULE: (regime, domain, field) must be globally unique across all registered
# solvers. The Registry warns and overwrites on collision — do not rely on
# overwriting as a versioning mechanism.
#
#
# ── 1.3  VARIANT FUNCTIONS — the core obligation ─────────────────────────────
#
# Every variant function MUST have this exact signature:
#
#   function _name(vars::Dict{Symbol, VarValue})::Float64
#
# Where VarValue = Union{Float64, Vector{Float64}, Symbol}  (from CommandParser)
#
# A variant function MUST:
#   ✓  Accept exactly one argument: the variables Dict from ParsedRequest
#   ✓  Return exactly one Float64 — the computed physical quantity
#   ✓  Use _get(vars, :key) (see 1.4) to extract every input — never index directly
#   ✓  Throw ArgumentError (and only ArgumentError) for physics domain violations
#      e.g. division by zero distance, negative absolute temperature, etc.
#   ✓  Be pure: same inputs → same output, no side effects, no I/O, no global mutation
#   ✓  Use SI units throughout, consistently with the variable names in required_vars
#
# A variant function MUST NOT:
#   ✗  Return nothing — the Dispatcher has no branch for a Nothing return
#   ✗  Catch its own exceptions — the Dispatcher's try/catch is the error boundary
#   ✗  Call register_solver! or touch the Registry
#   ✗  Call parse_request or anything in CommandParser
#   ✗  Mutate the vars Dict
#   ✗  Access module-level mutable state
#   ✗  Return NaN or Inf — these are physics errors; throw ArgumentError instead
#      (the Dispatcher's isfinite() check catches slipped-through non-finites and
#       turns them into DispatchResult failures, but solvers should not rely on this)
#
#
# ── 1.4  THE _get HELPER (required pattern for variable extraction) ───────────
#
# Every solver module MUST define a private _get that validates type and presence:
#
#   @inline function _get(vars::Dict, key::Symbol)::Float64
#       v = get(vars, key, nothing)
#       v === nothing && throw(ArgumentError("Missing required variable: $key"))
#       v isa Float64  || throw(ArgumentError(
#           "Variable $key must be a scalar Float64, got $(typeof(v))"))
#       return v
#   end
#
# Do NOT write vars[:key] directly — it throws KeyError (not ArgumentError),
# which gives the Dispatcher a weaker error message and bypasses type checking.
# The _get pattern is intentionally duplicated per module (not shared) to keep
# each solver self-contained and independently testable.
#
# For Vector{Float64} inputs (e.g. a list of charges), use _get_vec:
#
#   @inline function _get_vec(vars::Dict, key::Symbol)::Vector{Float64}
#       v = get(vars, key, nothing)
#       v === nothing && throw(ArgumentError("Missing required variable: $key"))
#       v isa Vector{Float64} || throw(ArgumentError(
#           "Variable $key must be a Float64 vector, got $(typeof(v))"))
#       return v
#   end
#
#
# ── 1.5  SolverVariant ASSEMBLY RULES ────────────────────────────────────────
#
#   SolverVariant(
#       required_vars :: Vector{Symbol},   # keys that fn() will call _get on
#       solves_for    :: Symbol,           # the output variable symbol
#       description   :: String,           # equation + plain English, e.g.:
#                                          #   "E = k·|q|/r² — point charge field"
#       fn            :: Function          # the variant function from 1.3
#   )
#
# required_vars RULES:
#   • List ONLY the symbols your fn actually calls _get on
#   • Do NOT list the solves_for symbol — it is the output, not an input
#   • Symbol names must exactly match what the user types in the input string
#     (CommandParser preserves them as-is from the raw input)
#   • Order does not affect dispatch — the Dispatcher checks set membership
#
# description FORMAT:
#   "LHS = RHS — plain English summary"
#   e.g. "r = √(k·|q|/E) — distance from field magnitude and source charge"
#   Keep under 80 characters. This string appears verbatim in API responses.
#
# VARIANT ORDERING IN THE VARIANTS LIST:
#   List variants in priority order — the Dispatcher picks the FIRST variant
#   whose required_vars are all present in the user's variables Dict.
#   Convention: most physically fundamental / most commonly requested form first.
#   When two variants share variables (ambiguous), place the more specific one
#   earlier (e.g. Coulomb point-charge before uniform-field approximations).
#
#
# ── 1.6  REGISTRATION ────────────────────────────────────────────────────────
#
# Every solver module MUST provide:
#
#   function register!()
#       register_solver!(_build_entry())
#       return nothing
#   end
#
#   register!()   # called at module load — REQUIRED
#
# The auto-register line at module load is the B-SPEC convention: including a
# solver file in the main entry point is sufficient to activate it. Solvers
# must NOT require a manual register!() call from the caller.
#
# register!() returns nothing. Do not use its return value.
#
#
# ── 1.7  PHYSICAL CONSTANTS ──────────────────────────────────────────────────
#
# Declare all constants as module-level consts with SI values and a comment
# stating the unit:
#
#   const k_e = 8.9875517923e9    # N·m²/C²  — Coulomb's constant
#   const ε₀  = 8.8541878128e-12  # F/m      — vacuum permittivity
#   const μ₀  = 1.25663706212e-6  # H/m      — vacuum permeability
#   const c   = 2.99792458e8      # m/s      — speed of light
#   const G   = 6.67430e-11       # N·m²/kg² — gravitational constant
#   const h   = 6.62607015e-34    # J·s      — Planck's constant
#   const k_B = 1.380649e-23      # J/K      — Boltzmann constant
#   const N_A = 6.02214076e23     # mol⁻¹   — Avogadro's number
#   const e   = 1.602176634e-19   # C        — elementary charge
#
# Do not redefine constants defined in another solver module — they are private
# to each module. If two solvers need k_e, both define their own const k_e.
#
#
# ── 1.8  NAMING CONVENTIONS ──────────────────────────────────────────────────
#
# Module name:      UpperCamelCase ending in "Solver", e.g. OhmsLawSolver
# Variant functions: _result_from_inputs, e.g. _E_from_q_r, _V_from_I_R
# Helper functions:  _ prefix, e.g. _get, _get_vec
# Constants:         snake_case or Greek letter, e.g. k_e, ε₀, mu_0
# File name:         snake_case matching the concept, e.g. ohms_law_solver.jl
#
# Variable symbol conventions (use these exact symbols — CommandParser passes
# them through verbatim from the user's input string):
#
#   :E   electric field magnitude (N/C or V/m)
#   :q   electric charge (C)
#   :r   distance / radius (m)
#   :F   force (N)
#   :V   electric potential / voltage (V)
#   :d   distance / separation (m)
#   :sigma  surface charge density (C/m²)
#   :I   electric current (A)
#   :R   resistance (Ω)
#   :B   magnetic field magnitude (T)
#   :m   mass (kg)
#   :v   velocity (m/s)
#   :a   acceleration (m/s²)
#   :t   time (s)
#   :T   temperature (K)
#   :P   pressure (Pa) or power (W) — context-dependent, note in description
#   :n   number density or quantity (dimensionless)
#   :L   length / inductance (m or H — note in description)
#   :C   capacitance (F)
#   :f   frequency (Hz)
#   :lambda  wavelength (m)
#   :omega   angular frequency (rad/s)
#
# When a solver needs a symbol not in this table, choose a single lowercase or
# Greek-letter name, document its SI unit in a comment, and add it here.


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — SYSTEM GUARANTEES (what the Dispatcher promises to solvers)
# ─────────────────────────────────────────────────────────────────────────────
#
# If a solver correctly follows Section 1, the Dispatcher guarantees:
#
#   G1. variant.fn(vars) is called ONLY when all required_vars are present
#       in vars as Float64 or Vector{Float64} or Symbol values. The Dispatcher
#       never calls fn() with a partially-populated dict.
#
#   G2. Every ArgumentError thrown by fn() is caught and returned as a
#       DispatchResult(success=false, error_msg=...). The error never
#       propagates to the HTTP layer or crashes the server.
#
#   G3. Non-finite returns (NaN, Inf, -Inf) are caught after fn() returns and
#       converted to a DispatchResult failure. Solvers should still avoid
#       returning them (throw instead), but they will not crash the system.
#
#   G4. The Dispatcher never mutates the vars Dict before or after calling fn().
#
#   G5. Batch dispatch (dispatch(Vector{ParsedRequest})) is independent per
#       request. A failure in element i does not affect elements i+1..n.
#
#   G6. The Registry lookup is O(1) (three Dict hash reads). Solvers do not
#       need to optimise for lookup cost.
#
#   G7. register_solver!() is idempotent for the same entry. Calling register!()
#       more than once warns but does not corrupt the registry.


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — REFERENCE TEMPLATE (copy this to create a new solver)
# ─────────────────────────────────────────────────────────────────────────────

const _TEMPLATE = raw"""
module XxxSolver
# Replace Xxx with your physics concept in UpperCamelCase.
# File name: xxx_solver.jl

export register!

using ..SolverRegistry: SolverVariant, SolverEntry, register_solver!

# ── Physical constants (SI, with unit comments) ────────────────────────────
# const k_e = 8.9875517923e9    # N·m²/C²

# ── Variable extractor — copy verbatim, do not modify ─────────────────────
@inline function _get(vars::Dict, key::Symbol)::Float64
    v = get(vars, key, nothing)
    v === nothing && throw(ArgumentError("Missing required variable: $key"))
    v isa Float64  || throw(ArgumentError(
        "Variable $key must be a scalar Float64, got $(typeof(v))"))
    return v
end

# ── Variant functions ──────────────────────────────────────────────────────
# Naming: _<output>_from_<input1>_<input2>
# Must return Float64. Throw ArgumentError for physics violations.

function _Y_from_A_B(vars)
    a = _get(vars, :A)
    b = _get(vars, :B)
    b == 0.0 && throw(ArgumentError("B must be non-zero"))
    return a / b
end

function _A_from_Y_B(vars)
    y = _get(vars, :Y)
    b = _get(vars, :B)
    return y * b
end

# ── SolverEntry assembly ───────────────────────────────────────────────────
function _build_entry()::SolverEntry
    return SolverEntry(
        :Regime,     # one of the legal regime symbols
        :Domain,     # one of the legal domain symbols
        :XxxConcept, # unique UpperCamelCase field symbol
        [
            SolverVariant([:A, :B], :Y, "Y = A/B — <plain English>", _Y_from_A_B),
            SolverVariant([:Y, :B], :A, "A = Y·B — <plain English>", _A_from_Y_B),
        ]
    )
end

# ── Registration ───────────────────────────────────────────────────────────
function register!()
    register_solver!(_build_entry())
    return nothing
end

register!()   # auto-register on module load

end # module XxxSolver
"""


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — COMPILE-TIME VALIDATOR
# ─────────────────────────────────────────────────────────────────────────────

struct ContractViolation <: Exception
    solver  :: Symbol   # the SolverEntry's field symbol
    variant :: Symbol   # the variant's solves_for symbol
    rule    :: String   # which contract rule was violated
end

Base.showerror(io::IO, e::ContractViolation) =
    print(io, "ContractViolation [$(e.solver)/$(e.variant)]: $(e.rule)")

"""
    validate_solver_entry(entry::SolverEntry) -> Vector{ContractViolation}

Check a SolverEntry against the contract rules that can be verified at
runtime without executing the physics functions. Returns an empty vector
if the entry is compliant. Designed to be called in unit tests:

    using .SolverContract: validate_solver_entry
    @test isempty(validate_solver_entry(ElectricFieldSolver._build_entry()))
"""
function validate_solver_entry(entry::SolverEntry)::Vector{ContractViolation}
    violations = ContractViolation[]
    f = entry.field

    # ── Entry-level checks ─────────────────────────────────────────────────

    # R-1: regime must be a recognised pillar symbol
    legal_regimes = (:ClassicalMechanics, :StatisticalMechanics,
                     :QuantumMechanics,   :RelativisticMechanics,
                     :Electromagnetism)
    if entry.regime ∉ legal_regimes
        push!(violations, ContractViolation(f, :_, "Unknown regime $(entry.regime). Add to legal_regimes in solver_contract.jl if this is a new pillar."))
    end

    # R-2: at least one variant must be registered
    if isempty(entry.variants)
        push!(violations, ContractViolation(f, :_, "SolverEntry has no variants"))
        return violations   # remaining checks require at least one variant
    end

    # ── Variant-level checks ───────────────────────────────────────────────

    seen_signatures = Set{Tuple{Symbol, Vector{Symbol}}}()

    for v in entry.variants
        s = v.solves_for

        # R-3: solves_for must not appear in required_vars
        if v.solves_for ∈ v.required_vars
            push!(violations, ContractViolation(f, s,
                "solves_for (:$(v.solves_for)) must not appear in required_vars"))
        end

        # R-4: required_vars must not be empty
        # (a variant with no inputs is a constant, not a solver)
        if isempty(v.required_vars)
            push!(violations, ContractViolation(f, s,
                "required_vars is empty — a solver variant must take at least one input"))
        end

        # R-5: description must follow the "equation — plain English" format
        if !occursin(" — ", v.description)
            push!(violations, ContractViolation(f, s,
                "description must contain \" — \" separating equation from plain English: \"$(v.description)\""))
        end

        # R-6: description must not exceed 80 characters
        if length(v.description) > 80
            push!(violations, ContractViolation(f, s,
                "description exceeds 80 chars ($(length(v.description))): \"$(v.description)\""))
        end

        # R-7: fn must be callable — verify it is a Function
        if !(v.fn isa Function)
            push!(violations, ContractViolation(f, s,
                "fn field is not a Function, got $(typeof(v.fn))"))
        end

        # R-8: no duplicate (solves_for, required_vars) signatures
        sig = (v.solves_for, sort(v.required_vars))
        if sig ∈ seen_signatures
            push!(violations, ContractViolation(f, s,
                "duplicate variant signature: solves_for=:$(v.solves_for), required_vars=$(v.required_vars)"))
        end
        push!(seen_signatures, sig)

        # R-9: all variable symbols must be lowercase or snake_case
        # (UpperCamelCase is reserved for field/domain/regime symbols)
        bad_vars = filter(v.required_vars) do sym
            str = string(sym)
            length(str) > 1 && any(isuppercase, str)
        end
        if !isempty(bad_vars)
            push!(violations, ContractViolation(f, s,
                "Variable symbols should be lowercase or snake_case. Found: $(bad_vars). " *
                "UpperCamelCase is reserved for regime/domain/field symbols."))
        end
    end

    return violations
end

"""
    print_template([io::IO])

Print the new-solver template to stdout (or any IO). Intended for use
during development:

    julia> using .SolverContract; SolverContract.print_template()
"""
function print_template(io::IO = stdout)
    println(io, _TEMPLATE)
end

end # module SolverContract
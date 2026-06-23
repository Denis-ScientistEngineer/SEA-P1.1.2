module ElectricFieldSolver

export register!

using ..SolverRegistry: SolverVariant, SolverEntry, register_solver!

# ====== 1. Physical Constants (SI) ==========================================

const k_e = 8.9875517923e9     # N·m²/C²  — Coulomb's constant = 1/(4πε₀)
const ε₀  = 8.8541878128e-12   # F/m      — vacuum permittivity

# ====== 2. Variable Extractor ===============================================
# Required pattern per SolverContract §1.4.
# Throws ArgumentError (caught by Dispatcher) — never returns nothing.

@inline function _get(vars::Dict, key::Symbol)::Float64
    v = get(vars, key, nothing)
    v === nothing && throw(ArgumentError("Missing required variable: $key"))
    v isa Float64  || throw(ArgumentError(
        "Variable $key must be a scalar Float64, got $(typeof(v))"))
    return v
end

# ====== 3. Variant Functions ================================================
# Signature: (vars::Dict) -> Float64
# Naming convention: _<output>_from_<inputs>
# Physics guards throw ArgumentError — never return NaN/Inf.

# ── Group 1: Coulomb point-charge  |E| = k·|q| / r² ────────────────────────

function _E_from_q_r(vars)
    q = _get(vars, :q)   # source charge (C)
    r = _get(vars, :r)   # distance from charge (m)
    r == 0.0 && throw(ArgumentError(
        "r must be non-zero — field is undefined at the source charge location"))
    return k_e * abs(q) / r^2
end

function _q_from_E_r(vars)
    E = _get(vars, :E)   # field magnitude (N/C)
    r = _get(vars, :r)   # distance (m)
    r == 0.0 && throw(ArgumentError("r must be non-zero"))
    return E * r^2 / k_e
end

function _r_from_E_q(vars)
    E = _get(vars, :E)   # field magnitude (N/C)
    q = _get(vars, :q)   # source charge (C)
    E <= 0.0 && throw(ArgumentError("E must be positive and non-zero"))
    return sqrt(k_e * abs(q) / E)
end

# ── Group 2: Force on test charge  E = F / q ────────────────────────────────

function _E_from_F_q(vars)
    F = _get(vars, :F)   # force experienced by test charge (N)
    q = _get(vars, :q)   # test charge (C)
    q == 0.0 && throw(ArgumentError("Test charge q must be non-zero"))
    return F / q
end

function _F_from_E_q(vars)
    E = _get(vars, :E)   # field magnitude (N/C)
    q = _get(vars, :q)   # charge (C)
    return E * q
end

function _q_from_F_E(vars)
    F = _get(vars, :F)   # force (N)
    E = _get(vars, :E)   # field magnitude (N/C)
    E == 0.0 && throw(ArgumentError("E must be non-zero"))
    return F / E
end

# ── Group 3: Uniform field between parallel plates  E = V / d ───────────────

function _E_from_V_d(vars)
    V = _get(vars, :V)   # potential difference (V)
    d = _get(vars, :d)   # plate separation (m)
    d == 0.0 && throw(ArgumentError("Plate separation d must be non-zero"))
    return V / d
end

function _V_from_E_d(vars)
    E = _get(vars, :E)   # field magnitude (V/m)
    d = _get(vars, :d)   # plate separation (m)
    return E * d
end

function _d_from_V_E(vars)
    V = _get(vars, :V)   # potential difference (V)
    E = _get(vars, :E)   # field magnitude (V/m)
    E == 0.0 && throw(ArgumentError("E must be non-zero"))
    return V / E
end

# ── Group 4: Surface / conductor  E = σ / ε₀ ────────────────────────────────

function _E_from_sigma(vars)
    σ = _get(vars, :sigma)   # surface charge density (C/m²)
    return σ / ε₀
end

function _sigma_from_E(vars)
    E = _get(vars, :E)       # field magnitude at surface (V/m)
    return E * ε₀
end

# ====== 4. SolverEntry Assembly =============================================
# Variants listed in dispatch-priority order (most common case first).
# required_vars lists only inputs — never the solves_for output.

function _build_entry()::SolverEntry
    return SolverEntry(
        :Electromagnetism,
        :Electrostatics,
        :ElectricField,
        [
            # Group 1 — Coulomb point-charge
            SolverVariant([:q, :r], :E,
                "E = k·|q|/r² — point charge field magnitude",
                _E_from_q_r),
            SolverVariant([:E, :r], :q,
                "q = E·r²/k — source charge from field and distance",
                _q_from_E_r),
            SolverVariant([:E, :q], :r,
                "r = √(k·|q|/E) — distance from field and charge",
                _r_from_E_q),

            # Group 2 — Force on test charge
            SolverVariant([:F, :q], :E,
                "E = F/q — field from force on test charge",
                _E_from_F_q),
            SolverVariant([:E, :q], :F,
                "F = E·q — force on charge in a field",
                _F_from_E_q),
            SolverVariant([:F, :E], :q,
                "q = F/E — charge from force and field",
                _q_from_F_E),

            # Group 3 — Parallel plates
            SolverVariant([:V, :d], :E,
                "E = V/d — uniform field between plates",
                _E_from_V_d),
            SolverVariant([:E, :d], :V,
                "V = E·d — voltage from field and separation",
                _V_from_E_d),
            SolverVariant([:V, :E], :d,
                "d = V/E — plate separation from voltage and field",
                _d_from_V_E),

            # Group 4 — Surface charge density
            SolverVariant([:sigma], :E,
                "E = σ/ε₀ — surface field from charge density",
                _E_from_sigma),
            SolverVariant([:E], :sigma,
                "σ = E·ε₀ — charge density from field at surface",
                _sigma_from_E),
        ]
    )
end

# ====== 5. Registration =====================================================

"""
    register!()

Register the ElectricField SolverEntry into the global SolverRegistry.
Called automatically when this module is loaded — no manual call needed.
"""
function register!()
    register_solver!(_build_entry())
    return nothing
end

register!()   # auto-register on module load (SolverContract §1.6)

end # module ElectricFieldSolver

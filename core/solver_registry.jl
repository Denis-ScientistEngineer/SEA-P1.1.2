module SolverRegistry
# This is the file that records all the solvers avilable in the system.


export SolverVariant, SolverEntry, REGISTRY,register_solver!, get_solver, list_domain_solvers, list_solvers


# ====== 1. Solver Types =========
# This records the overall structure of the solvers
# Each variant knows:
#   - which variables it REQUIRES to be given
#   - which variable it SOLVES FOR (exactly one)
#   - the function that does the math

struct SolverVariant
    required_vars::Vector{Symbol}   # the input the user must supply
    solves_for::Symbol              # the output the solver produces
    description::String             # a human-readable functional description of the variant
    fn::Function                    # the function that implements the math
end

# This is the top-level entry for one physics concept e.g ElectricField
struct SolverEntry
    regime::Symbol                  # e.g :classical, :quantum
    domain::Symbol                  # e.g :solidmechanics, :electromagnetics
    field::Symbol                   # Concept e.g :ElectricField, :OhmsLaw, :HeatEquation
    variants::Vector{SolverVariant} 
end


# ===== 2. Registry Store ======
# This is the global database for all the solvers
# We use a nested Dict for 0(1) 3 hash table lookups

const REGISTRY = Dict{Symbol,
                    Dict{Symbol,
                        Dict{Symbol, SolverEntry}}}()


# ====== 3. Registry API ======
# These are the functions that users and solvers call to interact with the registry
# Its a gateway that allows the user to securely send new solvers to the registry 
# Recieves dat, validates the input, checks duplication, saves data, returns response
"""
    register_solver!(entry::SolverEntry)

Add a SolverEntry to the global REGISTRY. Called once at module load time
by each solver file (e.g. electric_field_solver.jl). Duplicate registrations
(same regime/domain/field) warn and overwrite.
"""
function register_solver!(entry::SolverEntry)
    r = entry.regime
    d = entry.domain
    f = entry.field

    # Validate Input: Ensure nested dictionary exists - get! onlyallocates on first access
    # look up for r
    # This creates the first inner dictionary(regime[rd])
    #regime dictionary - rd
    rd = get!(Registry, r) do
        Dict{Symbol, Dict{Symbol, SolverEntry}}()
    end

    # look up for d if it doesnt exist create a new empty dictionary(domain[d])
    dd = get!(rd, d) do 
        Dict{Symbol, SolverEntry}()
    end

    # check if a solver is already registered under this specific field
    if haskey(dd, f)
        @warn "SolverRegistry: Overwriting existing solver for ($r, $d, $f)"
    end

    dd[f] = entry
    return entry
end


##### Database Interaction
# ===== 3. Lookup API =====
"""
        get_solver(regime, domain, field) -> Union{SolverEntry, Nothing}

Fast three-level hash lookup. Returns nothing if no solver is found
"""
function get_solver(regime::Symbol, domain::Symbol, field::Symbol)::Union{SolverEntry, Nothing}
    # Navigates layers safely using get(dict, key, default)
    rd = get(REGISTRY, regime, nothing)     # looks for regime inside the registry and get returns nothing if it isn't there
    rd === nothing && return nothing        # Is a short-circuit operator such that when rd=nothing the function exits returning nothing
    dd = get(rd, domain, nothing)           # If the regime exists, it takes that inner dictionary(regime) and looks for the domain
    dd === nothing && return nothing
    return get(dd, field, nothing)
end


# ====== 4. Introspection Helpers ======
"""
    list_solvers() -> Vector{NamedTuple}

Returns a list of all solvers currently in the data base registered under (regime,domain, field) triples.
Returns structured highly reusable data
"""
function list_solvers()
    out = NamedTuple{(:regime, :domain, :field), Tuple{Symbol, Symbol, Symbol}}[]
    for (r, rd) in REGISTRY, (d, dd) in rd, (f, _) in dd
        push!(out, (regime=r, domain=d, field=f))
    end

    sort!(out, by = x -> (x.regime, x.domain, x.field))
    return out
end


"""
    list_domain_solvers(regime, domain) -> Vector{Symbol}

Return all field symbols registered under a given regime+domain.
"""
function list_domain_solvers()
    rd = get(REGISTRY, regime, nothing)
    rd === nothing && return nothing
    dd = get(REGISTRY, domain, nothing)
    dd === nothing && return nothing
    return sort!(collect(keys(dd)))
end


#=
Why this design is excellent:
Because it returns data rather than just printing text, 
you can instantly feed the output of list_solvers() into other components of your software. 
For example, you can easily filter it, count your solvers, 
or even automatically convert it into a user-interface dropdown menu or a Markdown table.
=#

end

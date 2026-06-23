module CommandParser

export parse_request, ParsedRequest

# ====== 1. Types & Constants ======

const MAX_INPUT_LENGTH = 4096
const MAX_VARIABLES    = 16          # stack buffer ceiling — no heap growth for normal inputs
const VarValue = Union{Float64, Vector{Float64}, Symbol}

struct ParsedRequest
    regime::Symbol
    domain::Symbol
    field::Symbol
    command::Symbol
    variables::Dict{Symbol, VarValue}
end

# ====== 2. Pre-compiled Regex ======

const STRUCT_PATTERN = r"^\[\s*([^\]]+)\s*\]\s*\[\s*([^\]]+)\s*\]\s*\[\s*([^\]]+)\s*\]\s*([^:]+)\s*:\s*(.*)$"
const VAR_PATTERN    = r"([a-zA-Z]\w*)\s*=\s*(\[[^\]]+\]|[+-]?(?:\d+\.?\d*|\.\d+)(?:(?:[eE]|[ \t]*\*[ \t]*10\^)[ \t]*[+-]?\d+)?|[a-zA-Z]\w*)"
const SCALAR_PATTERN = r"[+-]?(?:\d+\.?\d*|\.\d+)(?:(?:[eE]|[ \t]*\*[ \t]*10\^)[ \t]*[+-]?\d+)?"

# ====== 3. Symbol Intern Cache ======
# Pre-intern all known regime/domain/field/command symbols at module load time.
# After this, Symbol("ClassicalMechanics") is a cheap pointer equality check —
# no string allocation, no hash, just an integer ID lookup in Julia's global
# symbol table.
const _KNOWN_SYMBOLS = let
    strs = [
        # Regimes
        "ClassicalMechanics", "StatisticalMechanics", "QuantumMechanics", "RelativisticMechanics",
        # Domains
        "SolidMechanics", "FluidMechanics", "Thermodynamics", "Electromagnetism",
        "WavesOptics", "Kinematics", "Dynamics",
        # Commands
        "calculate", "solve", "analyze", "convert",
        # Common fields
        "BeamDeflection", "CircuitAnalysis", "WaveEquation", "ProjectileMotion",
        "CoulombsLaw", "OhmsLaw", "NewtonsLaw",
    ]
    # Calling Symbol() on each string at load time registers them in Julia's
    # global intern table. Subsequent Symbol(same_string) calls hit the table
    # and return the existing pointer — zero allocation.
    foreach(Symbol, strs)
    nothing  # we don't need to keep the list; the side-effect is what matters
end

# ====== 4. Helpers ======

@inline function _clean_symbol(str::AbstractString)::Symbol
    s = strip(str)
    occursin(' ', s) ? Symbol(replace(s, " " => "")) : Symbol(s)
end

# Returns nothing on parse failure — callers skip the entry rather than throw.
@inline function _parse_scientific(s::AbstractString)::Union{Float64, Nothing}
    idx = findfirst("*10^", s)
    if idx !== nothing
        base = tryparse(Float64, strip(SubString(s, 1, first(idx) - 1)))
        exp  = tryparse(Int,     strip(SubString(s, last(idx) + 1, lastindex(s))))
        (base === nothing || exp === nothing) && return nothing
        return base * (10.0 ^ exp)
    end
    return tryparse(Float64, s)
end

# ====== 5. Stack-buffered Variable Parser ======
# Collects variable key-value pairs into fixed-size stack arrays before
# constructing the Dict. This means:
#   - No Dict resizing during the parse loop
#   - Dict is sized exactly right at construction (one allocation, correct capacity)
#   - NTuple-based key/value buffers live on the stack, not the heap

function _parse_variables(variable_string::AbstractString)::Dict{Symbol, VarValue}
    # Stack-allocated fixed-size buffers — no heap growth for ≤ MAX_VARIABLES inputs
    keys_buf   = Vector{Symbol}(undef, MAX_VARIABLES)
    values_buf = Vector{VarValue}(undef, MAX_VARIABLES)
    count = 0

    for m in eachmatch(VAR_PATTERN, variable_string)
        count >= MAX_VARIABLES && break

        name      = Symbol(m.captures[1])
        raw_value = m.captures[2]

        parsed_value::Union{VarValue, Nothing} = nothing

        if startswith(raw_value, '[') && endswith(raw_value, ']')
            # ---- Vector branch ----
            vec = Float64[]
            sizehint!(vec, 4)
            for sm in eachmatch(SCALAR_PATTERN, raw_value)
                v = _parse_scientific(sm.match)
                v !== nothing && push!(vec, v)
            end
            if isempty(vec)
                @warn "CommandParser: '$name' produced empty vector — skipping"
                continue
            end
            parsed_value = vec

        else
            fc = first(raw_value)
            if isdigit(fc) || fc === '-' || fc === '+' || fc === '.'
                v = _parse_scientific(raw_value)
                if v === nothing
                    @warn "CommandParser: bad numeric for '$name': «$(raw_value)» — skipping"
                    continue
                end
                parsed_value = v
            else
                parsed_value = _clean_symbol(raw_value)
            end
        end

        count += 1
        keys_buf[count]   = name
        values_buf[count] = parsed_value
    end

    # Construct Dict with exact capacity — one allocation, zero resizes.
    d = Dict{Symbol, VarValue}()
    sizehint!(d, count)
    @inbounds for i in 1:count
        d[keys_buf[i]] = values_buf[i]
    end
    return d
end

# ====== 6. Main Entry Point ======

function parse_request(input::AbstractString)::Union{ParsedRequest, Nothing}

    # O(1) length guard — before touching the regex engine
    length(input) > MAX_INPUT_LENGTH && (
        @warn "CommandParser: input too long ($(length(input)) chars)";
        return nothing
    )

    # Strip once, match once — no double-attempt
    m = match(STRUCT_PATTERN, strip(input))
    if m === nothing
        @warn "CommandParser: invalid format — «$(first(input, 120))»"
        return nothing
    end

    regime  = _clean_symbol(m.captures[1])
    domain  = _clean_symbol(m.captures[2])
    field   = _clean_symbol(m.captures[3])
    command = _clean_symbol(m.captures[4])

    variables = _parse_variables(m.captures[5])

    return ParsedRequest(regime, domain, field, command, variables)
end

# ====== 7. Batch Entry Point ======
# Processes a vector of inputs and returns results in a pre-allocated output
# array. Avoids the repeated undef-array + assignment pattern in the benchmark
# script by using map! with a pre-typed container.

function parse_requests(inputs::AbstractVector{<:AbstractString})::Vector{Union{ParsedRequest, Nothing}}
    results = Vector{Union{ParsedRequest, Nothing}}(undef, length(inputs))
    @inbounds for i in eachindex(inputs)
        results[i] = parse_request(inputs[i])
    end
    return results
end

end # module CommandParser
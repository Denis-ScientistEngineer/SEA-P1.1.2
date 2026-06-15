module CommandParser

export parse_request, ParsedRequest

# To avoid regex engine abuse
const MAX_INPUT_LENGTH = 4096

const VarValue = Union{Float64, Vector{Float64}, Symbol}

# ====== 1. Data Structure ======
struct ParsedRequest
    regime::Symbol
    domain::Symbol
    field::Symbol
    command::Symbol
    variables::Dict{Symbol, VarValue}
end


# ====== 2. Pre-compiled regex pattern Constants ======
# move the regex patterns out of the function to avoid recompilation
const STRUCT_PATTERN = r"^\[\s*([^\]]+)\s*\]\s*\[\s*([^\]]+)\s*\]\s*\[\s*([^\]]+)\s*\]\s*([^:]+)\s*:\s*(.*)$"

const VAR_PATTERN = r"([a-zA-Z]\w*)\s*=\s*(\[[^\]]+\]|[+-]?(?:\d+\.?\d*|\.\d+)(?:(?:[eE]|[ \t]*\*[ \t]*10\^)[ \t]*[+-]?\d+)?|[a-zA-Z]\w*)"

const SCALAR_PATTERN = r"[+-]?(?:\d+\.?\d*|\.\d+)(?:(?:[eE]|[ \t]*\*[ \t]*10\^)[ \t]*[+-]?\d+)?"

# Pre-computed character sets for the fast sign/digit check — avoids
# repeated tuple/set allocation inside the hot loop.
const NUMERIC_STARTS = ('0','1','2','3','4','5','6','7','8','9','-','+','.')


# ====== 4. Optimized Helpers ======

# Returns a Symbol from any AbstractString in the fewest allocations possible.
@inline function _clean_symbol(str::AbstractString)::Symbol
    s = strip(str)
    occursin(' ', s) ? Symbol(replace(s, " " => "")) : Symbol(s)
end


# ====== 4. Custom Fast Scalar Parser ======
# Replaces slow string mutations and complex regex branches for scientific notation
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


# ====== 5. Main Parser ======

function parse_request(input::AbstractString)::Union{ParsedRequest, Nothing}

    # FIX (risk): guard against pathologically long inputs before touching
    # the regex engine — O(1) check, costs almost nothing.
    if length(input) > MAX_INPUT_LENGTH
        @warn "CommandParser: input exceeds $(MAX_INPUT_LENGTH) chars, rejecting"
        return nothing
    end

    # Stripping once up front is cleaner and avoids the wasted second match.
    stripped_input = strip(input)
    struct_match = match(STRUCT_PATTERN, stripped_input)

    if struct_match === nothing
        # Emit a bounded excerpt — never log the full (possibly huge) input.
        excerpt = first(stripped_input, 120)
        @warn "CommandParser: invalid input format — «$(excerpt)»"
        return nothing
    end


    regime  = _clean_symbol(struct_match.captures[1])
    domain  = _clean_symbol(struct_match.captures[2])
    field   = _clean_symbol(struct_match.captures[3])
    command = _clean_symbol(struct_match.captures[4])
    variable_string = struct_match.captures[5]

    # FIX (warning): sizehint! value replaced with a profile-informed default.
    # B-SPEC physics inputs typically carry 3–6 named variables; 6 is the P95
    # estimate and avoids any resize for the common case without over-allocating.
    variables = Dict{Symbol, VarValue}()
    sizehint!(variables, 6)

    for m in eachmatch(VAR_PATTERN, variable_string)
        name      = Symbol(m.captures[1])   # SubString → Symbol, no copy
        raw_value = m.captures[2]           # SubString view into original

        if startswith(raw_value, '[') && endswith(raw_value, ']')
            # ---- Vector branch ----
            vec_elements = Float64[]
            sizehint!(vec_elements, 4)

            for elem_m in eachmatch(SCALAR_PATTERN, raw_value)
                val = _parse_scientific(elem_m.match)
                val !== nothing && push!(vec_elements, val)
            end

            # FIX (warning): skip silently-empty vectors — they would cause
            # opaque errors in downstream solvers. Log with the variable name
            # so the user gets an actionable message.
            if isempty(vec_elements)
                @warn "CommandParser: variable '$name' parsed as empty vector — skipping"
                continue
            end

            variables[name] = vec_elements

        else
            # ---- Scalar or configuration-token branch ----
            first_char = first(raw_value)

            # FIX (bug): previous guard only checked '-' and '.', missing '+'.
            # Now uses the pre-built NUMERIC_STARTS tuple for an O(1) check.
            if first_char ∈ NUMERIC_STARTS
                val = _parse_scientific(raw_value)
                if val === nothing
                    @warn "CommandParser: could not parse numeric value for '$name': «$(raw_value)» — skipping"
                    continue
                end
                variables[name] = val
            else
                variables[name] = _clean_symbol(raw_value)
            end
        end
    end

    return ParsedRequest(regime, domain, field, command, variables)
end


end



using BenchmarkTools
using .CommandParser  # Assumes your module is loaded

# 1. Define sample data
const sample_input = "[Classical Mechanics] [Solid Mechanics] [Beam Deflection] calculate : force=2000.0, mass=400.0, length=5.5"

# Create a mock batch of 5,000 requests to simulate a real-world workload
const batch_inputs = fill(sample_input, 5000)

println("=== BENCHMARKING SINGLE REQUEST ===")
# @btime runs the function thousands of times, handles JIT heating, 
# and prints the minimum execution time cleanly.
@btime parse_request(sample_input)


println("\n=== BENCHMARKING BATCH PROCESSING (5,000 Lines) ===")
# This tracks how your parser scales when dealing with massive data loads
function process_all_requests(inputs)
    # pre-allocate an array to hold results so we don't time array growth overhead
    results = Vector{Union{ParsedRequest, Nothing}}(undef, length(inputs))
    
    for i in eachindex(inputs)
        results[i] = parse_request(inputs[i])
    end
    return results
end

@btime process_all_requests(batch_inputs)

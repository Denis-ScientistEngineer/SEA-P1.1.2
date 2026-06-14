module CommandParser

export parse_request, ParsedRequest

# ====== 1. Data Structure ======
struct ParsedRequest
    regime::Symbol
    domain::Symbol
    field::Symbol
    command::Symbol
    variables::Dict{Symbol, Float64}
end


# ====== 2. Pre-compiled regex pattern Constants ======
# move the regex patterns out of the function to avoid recompilation
const STRUCT_PATTERN = r"^\[\s*([^\]]+)\s*\]\s*\[\s*([^\]]+)\s*\]\s*\[\s*([^\]]+)\s*\]\s*([^:]+)\s*:\s*(.*)$"
const VAR_PATTERN = r"([a-zA-Z]\w*)\s*=\s*(-?\d+(?:\.\d+)?(?:(?:[eE]|\s*\*\s*10\^)\s*[-+]?\d+)?)"


# ====== 3. Execution Function ======
"""
    Parse_request(input::AbstractString)::Union{ParsedRequest, Nothing}

Extracts regime, domain, field, command, and variables from a structured input string. 
Returns a `ParsedRequest` object if successful, or `nothing` if the input does not match the expected format.
"""

function parse_request(input::AbstractString)::Union{ParsedRequest, Nothing}
    # Match against the precompiled pattern. 
    # use strip(input) and let the regex handle the whitespace
    # or handle it duing token extraction to avoid new stripped strings

    struct_match = match(STRUCT_PATTERN, input)

    if struct_match === nothing
        # scondary error check reporting only if the fast path fails
        struct_match = match(STRUCT_PATTERN, strip(input))
        if struct_match === nothing
            @warn "Invalid Input Format!\nExpected layout = [Regime] [Domain] [Field] Command: var1=value1 var2=value2 ...\nReceived: $input"
            return nothing
        end
    end


    # Helper function using SubString view modifications instead of allocating new Strings
    function clean_symbol(str::SubString)
        #strip() on  SubString returns a SubString view (0 allocations)
        stripped = strip(str)
        if occursin(' ', stripped)
            # Only allocate a new string if space actually exist to be removed
            return Symbol(replace(stripped, " " => ""))
        else
            return Symbol(stripped)
        end
    end

    regime = clean_symbol(struct_match.captures[1])
    domain = clean_symbol(struct_match.captures[2])
    field = clean_symbol(struct_match.captures[3])
    command = clean_symbol(struct_match.captures[4])

    variable_string = struct_match.captures[5]

    variables = Dict{Symbol, Float64}()

    for m in eachmatch(VAR_PATTERN, variable_string)
        name = Symbol(m.captures[1])
        raw_val = m.captures[2]

        # Avoid allocating a new string via replace() unless there are actual space to strip
        val_to_parse = occursin(' ', raw_val) ? replace(raw_val, " " => "") : raw_val

        if occursin("*10^", val_to_parse)
            # findfirst returns indices, allowing us to split via SubString views instead of split() arrays
            idx = findfirst("*10^", val_to_parse)
            base_str = SubString(val_to_parse, 1, first(idx) - 1)
            exp_str = SubString(val_to_parse, last(idx) + 1, lastindex(val_to_parse))

            variables[name] = parse(Float64, base_str) * (10.0^parse(Float64, exp_str))
        else
            variables[name] = parse(Float64, val_to_parse)
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

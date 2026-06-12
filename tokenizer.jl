

# ==== 1. Data Structures ====
struct Token
    name::Symbol
    value::Float64
end

struct ParsedRequest
    domain::Symbol
    command::Symbol
    variables::Dict{Symbol, Float64}
end

# ==== 2. Main Interface ====

"""
    parse_request(input::String)::Union{ParsedRequest, Nothing}

Extracts the domain, command, and variables from a formatted string.
Expected layout: `[Domain] command : var1=val1 var2=val2 ...`
"""
function parse_request(input::String)::Union{ParsedRequest, Nothing}
    # Structural Regex: matches [Domain] command : variables
    structural_pattern = r"^\[\s*([^\]]+)\s*\]\s*([^:]+)\s*:\s*(.*)$"
    
    struct_match = match(structural_pattern, strip(input))

    if struct_match === nothing
        @warn "Invalid Input format!\nExpected layout = [Domain] command : variable1=value1 ..."
        return nothing
    end

    # Extract primary components
    domain = Symbol(strip(struct_match.captures[1]))
    command = Symbol(strip(struct_match.captures[2]))
    variable_string = struct_match.captures[3]
    
    # Tokenize and convert directly to a Dictionary
    tokens = tokenize_variables(variable_string)
    variables = Dict{Symbol, Float64}(t.name => t.value for t in tokens)

    return ParsedRequest(domain, command, variables)
end

# ==== 3. Parsing Engine ====

"""
    tokenize_variables(input::String)::Vector{Token}

Extracts variable names and their numerical values from the remaining string.
"""
function tokenize_variables(input::AbstractString)::Vector{Token}
    tokens = Token[]
    
    # Robust Regex: Captures names and numbers (Int, Float, Scientific, and *10^)
    # Examples it catches: mass = 400, vel = -3.14, force = 2e3, pressure = 5 * 10^-2
    pattern = r"([a-zA-Z]\w*)\s*=\s*(-?\d+(?:\.\d+)?(?:(?:[eE]|\s*\*\s*10\^)\s*[-+]?\d+)?)"

    for m in eachmatch(pattern, input)
        raw_name = m.captures[1]
        raw_value = m.captures[2]

        name = Symbol(raw_name)
        value = parse_numeric_value(raw_value)

        push!(tokens, Token(name, value))
    end

    return tokens
end

"""
    parse_numeric_value(raw_value::AbstractString)::Float64

Handles standard floats and custom `* 10^` notation.
"""
function parse_numeric_value(raw_value::AbstractString)::Float64
    # Clean up whitespace to make splitting foolproof
    cleaned_value = replace(raw_value, " " => "")

    if contains(cleaned_value, "*10^")
        parts = split(cleaned_value, "*10^")
        base = parse(Float64, parts[1])
        exponent = parse(Float64, parts[2])
        return base * (10.0^exponent)
    else
        return parse(Float64, cleaned_value)
    end
end


test = "[point charge] get electric field : q = 1e-6 distance = 10"
answ = parse_request(test)
@time println(answ)
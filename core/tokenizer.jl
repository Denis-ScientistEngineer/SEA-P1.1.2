# This is the user input string manipulation file
# It takes in the input string and prepares it in a format usable by the solvers
# Format : [Token] key = value pair


# ====== Step 1: Token structure =======
# create the token structure
struct Token
    name::Symbol
    value::Float64
end


# ====== Step 2: Request structure =======
struct ParsedRequest
    domain::String
    command::String
    variables::String
end


# ====== Step 3: Extract Request parts =======
function extractor(input::String)::Union{ParsedRequest, Nothing}
    # 1. The main regex to split: [Domain] command : variables
    # Format: [text] text : text
    
    structural_pattern = r"^\[\s*([^\]]+)\s*\]\s*([^:]+)\s*:\s*(.*)$"

    struct_match = match(structural_pattern, input)

    if struct_match === nothing
        println("ERROR: Invalid Input format!")
        println("   Expected layout = [Domain] command : variable1=value1, variable2=key2, ....")
        return nothing
    end


    # Extract metadata cleanly
    domain = strip(struct_match.captures[1])
    command = strip(struct_match.captures[2])
    variables = struct_match.captures[3]

    return ParsedRequest(domain, command, variables)
end


# ===== Step 4: Tokenizer =====
# we create the key = value pair e.g mass = 200
function tokenizer(input::String)::Vector{Token}
    tokens = Token[]

    # define the regex pattern to look for
    # quantity = value
    pattern = r"[a-zA-Z][a-zA-Z0-9]\s*=\s*(-?\d+\.?\d*(?:[eE][-+]?\d+)?)"

    for m in eachmatch(pattern, input)
        raw_name = m.captures[1]
        raw_value = m.captures[2]

        name = Symbol(raw_name)
        value = parse(Float64, raw_value)

        push!(tokens, Token(name, value))
    end
    return tokens

end


# ===== Step 4: Convert tokens to dictionary ======
function tokens_to_dictionary(tokens::Vector{Token})::Dict{Symbol, Float64}
    return Dict(t.name => t.value for t in tokens)
end





inp = "[point charge] get electric field : q=2 F=200"
#extractor(inp)
values = extractor(inp)

(; domain, command, variables) = values
vars = values.variables

token_array = tokenizer(vars)
tokens_to_dictionary(vars)
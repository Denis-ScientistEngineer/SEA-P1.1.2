struct Token
	name::Symbol
	value::Float64
end


# ===== Step 2: Tokenizer =====
# This function extracts tokens: name , value from the input string

function tokenize(input::String)::Vector{Token}
	# step 1: start with empty tokens
	tokens = Token[]
	
	# step 2: define the search pattern

	pattern = r"([a-zA-Z][a-zA-Z0-9]*)\s*?=\s*?(-?\d+\.?\d*(?:\s*\*\s*10\^|[eE])?[-+]?\d+)"

	# step 3: capture and record every occurence finding of the pattern
	for m in eachmatch(pattern, input)
		raw_name = m.captures[1]
		raw_value = m.captures[2]

		name = Symbol(raw_name)
		value = 0.0

		# check if the user used * 10^ format
		if contains(raw_value, "*")
			# split the string around the multiplication block into parts
			parts = split(raw_value, r"\s*\*\s*10\^")
			base = parse(Float64, parts[1])
			exponent = parse(Float64, parts[2])

			value = base * (10.0^exponent)

		else
			# incase of scientific notation: e 
			value = parse(Float64, raw_value)
		end

		push!(tokens, Token(name, value))
	end

	return tokens
end


# ===== Step 3: tokens yo dictionary ====
function tok_to_dict(tokens::Vector{Token})::Dict{Symbol, Float64}
	return Dict(t.name => t.value for t in tokens)
end



rm = "mass = 400"
rme = tokenize(rm)
ecx= tokens_to_dict(rme)
println(rme)
println(exc)

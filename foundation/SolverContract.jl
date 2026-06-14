# This is the file that contains the rules every solver must obey
# ====== Contract details =========
# 1. Ever solver must register:
#       1. Regime it is operating on e.g quantum, classical, statistical e.t.c
#       2. Domain it belongs to e.g electromagnetics, solid mechanics, fluid mechanics
#       3. Field e.g point charge, electron, projectile e.t.c
#       4. command e.g electric field, capacitance, free fall e.t.c
# 2. Every solver that handles problems in  specific field e.g capacitor, must register the 
#   the fumctions that handle every command
# 3. Every function that handles the command requested must have the physicl formula to handle
#   that hndles the variables passed to it.
# 4. These functions should be able to solve for every variable in the Formula it works with
#   for example: a function that calculates power; P=VI should be able to solve for P,V and I depending 
#    on wwhat variable was missing from the variables passed to it by the dispatcher
# 5. Every solver must return solver results

# ==== Important notes:
# We should have a registry files for every regime, domain, field, command and solvers
# Every domain registers itself on the regime it is operating on
# Every domainhas solvers files e.g Electromagnetics has: electric_field.jl, coulomb_force.jl, gaus_law.jl e.t.c
# Every solver file has functions that handle every request/command of every field e.g electric_field.jl has functions such as point_charge_electricfield, vol_charge_elf e.t.c
# Every function that handles every command for a specific field must register in itself the variables it works with so that it will chack during its operation what it needs to compute for
# The function should return the result of its calculation



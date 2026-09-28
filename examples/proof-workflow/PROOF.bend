import Base
import ./main.bend as Model
import ./LAWS.bend as Laws

def add_zero_right(value: Nat) -> {Model.add_zero(value) == value : Nat}:
  match value:
    case 0n:
      {==}
    case 1n+predecessor:
      %add_zero_right(predecessor) : {1n+Model.add_zero(predecessor) == 1n+_ : Nat}
      {==}

def Laws.adding_zero_preserves_value(value):
  add_zero_right(value)

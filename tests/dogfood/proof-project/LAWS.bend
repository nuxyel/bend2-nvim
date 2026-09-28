import Base
import ./main.bend as Model

law adding_zero_preserves_value:
  for value: Nat
  {Model.add_zero(value) == value : Nat}

// Exercises the unwrap rules + import variants:
//
// - Result/Option return → unwrap to success path
// - List(T) → List(S) → unwrap to T → S (container-preserving)
// - Aliased module import (`as o`)
// - Unqualified type import (`{type Order}`)
// - Generic return — filtered out by default (`drop_generic: True`)

import gleam/option.{type Option}
import sample/customer.{type CustomerId}
import sample/order.{type Order} as o

pub fn lookup_id(value: String) -> Result(o.OrderId, Nil) {
  o.new_id(value)
}

pub fn maybe_customer(_value: String) -> Option(CustomerId) {
  todo
}

pub fn batch_snapshot(_orders: List(Order)) -> List(o.OrderSnapshot) {
  todo
}

// Generic return — should produce no edge in the default-filtered graph.
pub fn identity(x: a) -> a {
  x
}

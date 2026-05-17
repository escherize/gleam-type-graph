// Snapshot/restore symmetry + a multi-arg constructor (fan-in test).

import sample/customer.{type CustomerId}
import sample/money.{type Money}

pub opaque type Order {
  Order(id: OrderId, customer: CustomerId, total: Money)
}

pub opaque type OrderId {
  OrderId(value: String)
}

pub type OrderSnapshot {
  OrderSnapshot(id: String, total_cents: Int)
}

pub fn new_id(value: String) -> Result(OrderId, Nil) {
  case value {
    "" -> Error(Nil)
    _ -> Ok(OrderId(value))
  }
}

pub fn snapshot(o: Order) -> OrderSnapshot {
  let OrderId(id) = o.id
  OrderSnapshot(id: id, total_cents: money.to_cents(o.total))
}

pub fn restore(s: OrderSnapshot, customer: CustomerId) -> Order {
  Order(
    id: OrderId(s.id),
    customer: customer,
    total: money.from_cents(s.total_cents),
  )
}

// Multi-arg with three distinct typed inputs → fan-in cluster.
pub fn make_order(
  customer: CustomerId,
  id: OrderId,
  total: Money,
) -> Order {
  Order(id: id, customer: customer, total: total)
}

// Multi-arg where the input dedup leaves duplicates → fan-in carries the
// raw param order (`Order, Order, String`) but the input edge set dedupes
// to {Order, String}.
pub fn merge(_a: Order, _b: Order, _label: String) -> Order {
  todo
}

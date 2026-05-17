// Smart-constructor + serialiser. Round-trips through Int.

pub opaque type Money {
  Money(cents: Int)
}

pub fn from_cents(cents: Int) -> Money {
  Money(cents)
}

pub fn to_cents(m: Money) -> Int {
  m.cents
}

// Private — should be excluded from the graph.
fn double(m: Money) -> Money {
  Money(m.cents * 2)
}

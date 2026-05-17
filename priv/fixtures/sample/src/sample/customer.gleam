// Smart-constructor module. String → CustomerId, with Result return that
// gets unwrapped to the success path.

pub opaque type CustomerId {
  CustomerId(value: String)
}

pub fn new_id(value: String) -> Result(CustomerId, Nil) {
  case value {
    "" -> Error(Nil)
    _ -> Ok(CustomerId(value))
  }
}

module MathTests

open Expecto

[<Tests>]
let tests =
  testList "Math" [
    test "add works" {
      Expect.equal (Math.add 2 3) 5 "2 + 3 = 5"
    }
    test "divide by zero returns Error" {
      Expect.isError (Math.divide 10 0) "should be Error"
    }
    test "isEven detects even numbers" {
      Expect.isTrue (Math.isEven 4) "4 is even"
    }
    test "deliberately failing test" {
      Expect.equal (Math.add 2 2) 5 "this should fail"
    }
  ]

open Jest;
open Expect;

describe("Base64", () => {
  test("encodes string", () => {
    "123" |> Sihl.Core.Base64.encode |> expect |> toBe("MTIz")
  });
  test("decodes string", () => {
    "MTIz" |> Sihl.Core.Base64.decode |> expect |> toBe("123")
  });
  test("decodes encoded string yields string", () => {
    "123"
    |> Sihl.Core.Base64.encode
    |> Sihl.Core.Base64.decode
    |> expect
    |> toBe("123")
  });
});

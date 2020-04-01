module Async = SihlCoreAsync;

[@bs.module]
external random: (~nBytes: int, ~encoding: string) => Js.Promise.t(string) =
  "./crypt/random-bytes.js";

let base64 = (~specialChars=?, nBytes) =>
  switch (specialChars) {
  | Some(true) => random(~nBytes, ~encoding="base64")
  | _ =>
    random(~nBytes, ~encoding="base64")
    ->Async.mapAsync(str =>
        str
        |> Js.String.replaceByRe([%re "/\//g"], "a")
        |> Js.String.replaceByRe([%re "/\+/g"], "b")
        |> Js.String.replaceByRe([%re "/\=/g"], "c")
      )
  };

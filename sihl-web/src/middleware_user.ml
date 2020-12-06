module User = Sihl_type.User

let key : User.t Opium_kernel.Hmap.key =
  Opium_kernel.Hmap.Key.create ("user", User.sexp_of_t)
;;

let find req = Opium_kernel.Hmap.find_exn key (Opium_kernel.Request.env req)
let find_opt req = Opium_kernel.Hmap.find key (Opium_kernel.Request.env req)

let set user req =
  let env = Opium_kernel.Request.env req in
  let env = Opium_kernel.Hmap.add key user env in
  { req with env }
;;

module Make (UserService : Sihl_contract.User.Sig) = struct
  let require_user ~login_path_f =
    let filter handler req =
      let user = find_opt req in
      match user with
      | Some _ -> handler req
      | None ->
        let login_path = login_path_f () in
        Sihl_type.Http_response.redirect_to login_path |> Lwt.return
    in
    Opium_kernel.Rock.Middleware.create ~name:"user.require.user" ~filter
  ;;

  let require_admin ~login_path_f =
    let filter handler req =
      let user = find_opt req in
      match user with
      | Some user ->
        if User.is_admin user
        then handler req
        else (
          let login_path = login_path_f () in
          Sihl_type.Http_response.redirect_to login_path |> Lwt.return)
      | None ->
        let login_path = login_path_f () in
        Sihl_type.Http_response.redirect_to login_path |> Lwt.return
    in
    Opium_kernel.Rock.Middleware.create ~name:"user.require.admin" ~filter
  ;;
end

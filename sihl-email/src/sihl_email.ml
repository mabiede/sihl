include Sihl.Contract.Email

let log_src = Logs.Src.create ("sihl.service." ^ Sihl.Contract.Email.name)

module Logs = (val Logs.src_log log_src : Logs.LOG)

let dev_inbox : Sihl.Contract.Email.t list ref = ref []

module DevInbox = struct
  let inbox () = !dev_inbox
  let add_to_inbox email = dev_inbox := List.cons email !dev_inbox
  let clear_inbox () = dev_inbox := []
end

let print email =
  let open Sihl.Contract.Email in
  Logs.info (fun m ->
      m
        {|
-----------------------
Email sent by: %s
Recipient: %s
Subject: %s
-----------------------
Text:

%s
-----------------------
Html:

%s
-----------------------
|}
        email.sender
        email.recipient
        email.subject
        email.text
        (Option.value ~default:"<None>" email.html))
;;

let should_intercept () =
  let is_production = Sihl.Configuration.is_production () in
  let bypass =
    Option.value
      ~default:false
      (Sihl.Configuration.read_bool "EMAIL_BYPASS_INTERCEPT")
  in
  match is_production, bypass with
  | false, true -> false
  | false, false -> true
  | true, _ -> false
;;

let intercept sender email =
  let is_development = Sihl.Configuration.is_development () in
  let console =
    Option.value
      ~default:is_development
      (Sihl.Configuration.read_bool "EMAIL_CONSOLE")
  in
  let () = if console then print email else () in
  if should_intercept ()
  then Lwt.return (DevInbox.add_to_inbox email)
  else sender email
;;

module type SmtpConfig = sig
  val sender : string
  val username : string
  val password : string
  val hostname : string
  val port : int option
  val start_tls : bool
  val ca_path : string option
  val ca_cert : string option
  val console : bool option
end

module MakeSmtp (Config : SmtpConfig) : Sihl.Contract.Email.Sig = struct
  include DevInbox

  let send' (email : Sihl.Contract.Email.t) =
    let recipients =
      List.concat
        [ [ Letters.To email.recipient ]
        ; List.map (fun address -> Letters.Cc address) email.cc
        ; List.map (fun address -> Letters.Bcc address) email.bcc
        ]
    in
    let body =
      match email.html with
      | Some html -> Letters.Html html
      | None -> Letters.Plain email.text
    in
    let sender = Config.sender in
    let username = Config.username in
    let password = Config.password in
    let hostname = Config.hostname in
    let port = Config.port in
    let with_starttls = Config.start_tls in
    let ca_path = Config.ca_path in
    let ca_cert = Config.ca_cert in
    let config =
      Letters.Config.make ~username ~password ~hostname ~with_starttls
      |> Letters.Config.set_port port
      |> fun conf ->
      match ca_cert, ca_path with
      | Some path, _ -> Letters.Config.set_ca_cert path conf
      | None, Some path -> Letters.Config.set_ca_path path conf
      | None, None -> conf
    in
    Letters.build_email
      ~from:email.sender
      ~recipients
      ~subject:email.subject
      ~body
    |> function
    | Ok message -> Letters.send ~config ~sender ~recipients ~message
    | Error msg -> raise (Sihl.Contract.Email.Exception msg)
  ;;

  let send email = intercept send' email
  let bulk_send _ = failwith "Bulk sending not implemented yet"

  let start () =
    (* Make sure that configuration is valid *)
    if Sihl.Configuration.is_production ()
    then Sihl.Configuration.require schema
    else ();
    (* if mail is intercepted, don't punish user for not providing SMTP
       credentials *)
    if should_intercept () then () else Sihl.Configuration.require schema;
    Lwt.return ()
  ;;

  let stop () = Lwt.return ()

  let lifecycle =
    Sihl.Container.create_lifecycle Sihl.Contract.Email.name ~start ~stop
  ;;

  let register () =
    let configuration = Sihl.Configuration.make ~schema () in
    Sihl.Container.Service.create ~configuration lifecycle
  ;;
end

module EnvSmtpConfig = struct
  type config =
    { sender : string
    ; username : string
    ; password : string
    ; hostname : string
    ; port : int option
    ; start_tls : bool
    ; ca_path : string option
    ; ca_cert : string option
    ; console : bool option
    }

  let config
      sender
      username
      password
      hostname
      port
      start_tls
      ca_path
      ca_cert
      console
    =
    { sender
    ; username
    ; password
    ; hostname
    ; port
    ; start_tls
    ; ca_path
    ; ca_cert
    ; console
    }
  ;;

  let schema =
    let open Conformist in
    make
      [ string "SMTP_SENDER"
      ; string "SMTP_USERNAME"
      ; string "SMTP_PASSWORD"
      ; string "SMTP_HOST"
      ; optional (int ~default:587 "SMTP_PORT")
      ; bool "SMTP_START_TLS"
      ; optional (string ~default:"/etc/ssl/certs" "SMTP_CA_PATH")
      ; optional (string ~default:"" "SMTP_CA_CERT")
      ; optional (bool ~default:false "EMAIL_CONSOLE")
      ]
      config
  ;;

  let sender = (Sihl.Configuration.read schema).sender
  let username = (Sihl.Configuration.read schema).username
  let password = (Sihl.Configuration.read schema).password
  let hostname = (Sihl.Configuration.read schema).hostname
  let port = (Sihl.Configuration.read schema).port
  let start_tls = (Sihl.Configuration.read schema).start_tls
  let ca_path = (Sihl.Configuration.read schema).ca_path
  let ca_cert = (Sihl.Configuration.read schema).ca_cert
  let console = (Sihl.Configuration.read schema).console
end

module Smtp = MakeSmtp (EnvSmtpConfig)

module type SendGridConfig = sig
  val api_key : string
  val console : bool option
end

module MakeSendGrid (Config : SendGridConfig) : Sihl.Contract.Email.Sig = struct
  include DevInbox

  let body ~recipient ~subject ~sender ~content =
    Printf.sprintf
      {|
  {
    "personalizations": [
      {
        "to": [
          {
            "email": "%s"
          }
        ],
        "subject": "%s"
      }
    ],
    "from": {
      "email": "%s"
    },
    "content": [
       {
         "type": "text/plain",
         "value": "%s"
       }
    ]
  }
|}
      recipient
      subject
      sender
      content
  ;;

  let sendgrid_send_url =
    "https://api.sendgrid.com/v3/mail/send" |> Uri.of_string
  ;;

  let send' email =
    let open Lwt.Syntax in
    let open Sihl.Contract.Email in
    let token = Config.api_key in
    let headers =
      Cohttp.Header.of_list
        [ "authorization", "Bearer " ^ token
        ; "content-type", "application/json"
        ]
    in
    let sender = email.sender in
    let recipient = email.recipient in
    let subject = email.subject in
    let text_content = email.text in
    (* TODO support html content *)
    (* let html_content = Sihl.Email.text_content email in *)
    let req_body = body ~recipient ~subject ~sender ~content:text_content in
    let* resp, resp_body =
      Cohttp_lwt_unix.Client.post
        ~body:(Cohttp_lwt.Body.of_string req_body)
        ~headers
        sendgrid_send_url
    in
    let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
    match status with
    | 200 | 202 ->
      Logs.info (fun m -> m "Successfully sent email using sendgrid");
      Lwt.return ()
    | _ ->
      let* body = Cohttp_lwt.Body.to_string resp_body in
      Logs.err (fun m ->
          m
            "Sending email using sendgrid failed with http status %i and body \
             %s"
            status
            body);
      raise (Sihl.Contract.Email.Exception "Failed to send email")
  ;;

  let send email = intercept send' email
  let bulk_send _ = Lwt.return ()

  let start () =
    (* Make sure that configuration is valid *)
    Sihl.Configuration.require schema;
    Lwt.return ()
  ;;

  let stop () = Lwt.return ()

  let lifecycle =
    Sihl.Container.create_lifecycle Sihl.Contract.Email.name ~start ~stop
  ;;

  let register () =
    let configuration = Sihl.Configuration.make ~schema () in
    Sihl.Container.Service.create ~configuration lifecycle
  ;;
end

module EnvSendGridConfig = struct
  type config =
    { api_key : string
    ; console : bool option
    }

  let config api_key console = { api_key; console }

  let schema =
    let open Conformist in
    make
      [ string "SENDGRID_API_KEY"
      ; optional (bool ~default:false "EMAIL_CONSOLE")
      ]
      config
  ;;

  let api_key = (Sihl.Configuration.read schema).api_key
  let console = (Sihl.Configuration.read schema).console
end

module SendGrid = MakeSendGrid (EnvSendGridConfig)

(* This is useful if you need to answer a request quickly while sending the
   email in the background *)
module Queued
    (QueueService : Sihl.Contract.Queue.Sig)
    (Email : Sihl.Contract.Email.Sig) : Sihl.Contract.Email.Sig = struct
  include DevInbox

  module Job = struct
    let input_to_string email =
      email
      |> Sihl.Contract.Email.to_yojson
      |> Yojson.Safe.to_string
      |> Option.some
    ;;

    let string_to_input email =
      match email with
      | None ->
        Logs.err (fun m ->
            m
              "Serialized email string was NULL, can not deserialize email. \
               Please fix the string manually and reset the job instance.");
        Error "Invalid serialized email string received"
      | Some email ->
        let email =
          try Ok (Yojson.Safe.from_string email) with
          | _ ->
            Logs.err (fun m ->
                m
                  "Serialized email string was NULL, can not deserialize \
                   email. Please fix the string manually and reset the job \
                   instance.");
            Error "Invalid serialized email string received"
        in
        Result.bind email (fun email ->
            email
            |> Sihl.Contract.Email.of_yojson
            |> Option.to_result ~none:"Failed to deserialize email")
    ;;

    let handle input = Email.send input |> Lwt.map Result.ok

    (** Nothing to clean up, sending emails is a side effect *)
    let failed _ = Lwt_result.return ()

    let job =
      Sihl.Contract.Queue.create
        ~name:"send_email"
        ~input_to_string
        ~string_to_input
        ~handle
        ~failed
        ()
      |> Sihl.Contract.Queue.set_max_tries 10
      |> Sihl.Contract.Queue.set_retry_delay Sihl.Time.OneHour
    ;;
  end

  let send email =
    (* skip queue when running tests *)
    if not (Sihl.Configuration.is_production ())
    then (
      Logs.debug (fun m -> m "Skipping queue for email sending");
      Email.send email)
    else QueueService.dispatch Job.job email
  ;;

  let bulk_send emails =
    (* TODO [jerben] Implement queue API for multiple jobs so we don't have to
       use transactions here *)
    let rec loop emails =
      match emails with
      | email :: emails -> Lwt.bind (send email) (fun () -> loop emails)
      | [] -> Lwt.return ()
    in
    loop emails
  ;;

  let start () = QueueService.register_jobs [ Job.job ] |> Lwt.map ignore
  let stop () = Lwt.return ()

  let lifecycle =
    Sihl.Container.create_lifecycle
      Sihl.Contract.Email.name
      ~start
      ~stop
      ~dependencies:(fun () ->
        [ Email.lifecycle; Sihl.Database.lifecycle; QueueService.lifecycle ])
  ;;

  let register () = Sihl.Container.Service.create lifecycle
end

module Template = Template

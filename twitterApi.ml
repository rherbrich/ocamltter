let ocamltter_consumer_key = "vS0nKAS6ieWL76zZaQgF4A"
let ocamltter_consumer_secret = "XHa1ZiPcNRsYKw4mdIv8wHUiNulpBFxKT1ntXXuJgo"

open Util
open Util.Date
open Http
open Json
open Oauth

exception TwErr of string

type tweet = {
    date: Date.t;
    sname: string;
    id: int64;
    clientname: string;
    text: string;
  }

let parse_date01 st = (* Wed Apr 21 02:29:17 +0000 2010 *)
  let mon = pmonth @@ String.sub st 4 3 in
  let day = int_of_string @@ String.sub st 8 2 in
  let h = int_of_string @@ String.sub st 11 2 in
  let m = int_of_string @@ String.sub st 14 2 in
  let s = int_of_string @@ String.sub st 17 2 in
  let year = int_of_string @@ String.sub st 26 4 in
  Date.make_from_gmt year mon day h m s

let parse_date02 st = (* Sat, 17 Apr 2010 08:23:55 +0000 *)
  let mon = pmonth @@ String.sub st 8 3 in
  let day = int_of_string @@ String.sub st 5 2 in
  let h = int_of_string @@ String.sub st 17 2 in
  let m = int_of_string @@ String.sub st 20 2 in
  let s = int_of_string @@ String.sub st 23 2 in
  let year = int_of_string @@ String.sub st 12 4 in
  Date.make_from_gmt year mon day h m s

let parse_date st =
  try parse_date01 st with
  | _ -> parse_date02 st

let show_tweet t =
  let mo,d,h,m = Date.mon t.date, Date.day t.date, hour t.date, min t.date in
  !%" [%02d/%02d %02d:%02d] %s: %s %LdL" mo d h m t.sname t.text t.id

let tw_compare t1 t2 = compare t1.date t2.date
    
let json2status j =
    let date =
      Json.getf "created_at" j |> Json.as_string |> parse_date
    in
    let text =
      Json.getf "text" j |> Json.as_string
    in
    let id =
      Json.getf "id" j |> Json.as_float |> Int64.of_float
    in
    let sname =
      Json.getf "user" j |> Json.getf "screen_name" |> Json.as_string
    in
    let client =
      Json.getf "source" j |> Json.as_string
    in
    {date=date; sname=sname; text=text; id=id; clientname=client}

let json2timeline j =
  Json.as_list j |> List.map json2status

let catch_twerr (f: 'a -> Json.t) (x : 'a) =
  try
    let j = f x in
    match Json.getf_opt "error" j with
    | Some err ->
	let msg = Json.as_string err in
	raise (TwErr msg)
    | None -> j
  with
  | TwErr m as e -> raise e
  | e -> failwith ("twitter error: "^Printexc.to_string e)

let twitter (tok,sec,verif) ?(host="api.twitter.com") meth cmd params =
  let oauth = {
    Oauth.consumer_key = ocamltter_consumer_key;
    Oauth.consumer_secret = ocamltter_consumer_secret;
    Oauth.access_token=tok;
    Oauth.access_token_secret=sec;
    Oauth.verif=verif
  } in
  let f () =
    Json.parse (Oauth.access oauth meth host cmd params)
  in
  catch_twerr f ()

let twitter_without_auth ?(host="api.twitter.com") meth cmd params =
  let f () =
    Http.conn host meth cmd params (fun _ ch -> slist "" id (read_all ch))
      |> Json.parse
  in
  catch_twerr f ()

let home_timeline ?since_id ?count oauth =
  let params = [("since_id",since_id); ("count", option_map sint count)]
      |> list_filter_map (function
	| (key, Some v) -> Some (key, v)
	| (_, None) -> None)
  in
  twitter oauth GET "/statuses/home_timeline.json" params
    |> json2timeline

let user_timeline ?since_id ?count oauth sname =
  let params = [("since_id",since_id); ("count", option_map sint count);
		("screen_name", Some sname)]
      |> list_filter_map (function
	| (key, Some v) -> Some (key, v)
	| (_, None) -> None)
  in
  twitter oauth GET "/statuses/user_timeline.json" params
    |> json2timeline

let show status_id =
  twitter_without_auth GET (!%"/statuses/show/%Ld.json" status_id) []
    |> json2status

let get_tweet = show

let mentions oauth count =
  let params = [("count", !%"%d" count)] in
  twitter oauth GET "/1/statuses/mentions.json" params
    |> json2timeline

let update ?(in_reply_to_status_id) oauth text =
  let text = match in_reply_to_status_id with
  | Some id ->
      let t = get_tweet (Int64.of_string id) in
      !%"@%s %s" t.sname text
  | None -> text
  in
  let params = [("in_reply_to_status_id", in_reply_to_status_id);
		("status",Some text)]
      |> list_filter_map (function
	| (key, Some v) -> Some (key, v)
	| (_, None) -> None)
  in
  twitter oauth POST "/statuses/update.json" params

let retweet oauth status_id =
  twitter oauth POST (!%"/statuses/retweet/%s.json" status_id) []

let search word =
  let ps = [("q",word);("rpp","100")] in
  twitter_without_auth GET ~host:"search.twitter.com" "/search.json" ps
    |> Json.getf "results"
    |> Json.as_list
    |> List.map (fun j ->
      let d = parse_date @@ Json.as_string @@ Json.getf "created_at" j in
      let sname = Json.as_string @@ Json.getf "from_user" j in
      let text = Json.as_string @@ Json.getf "text" j in
      let id = Int64.of_float @@ Json.as_float @@ Json.getf"id" j in
      { date=d; sname=sname; id=id; clientname=""; text=text })

let rate_limit_status () =
  twitter_without_auth GET "/1/account/rate_limit_status.json" []

let host = "api.twitter.com"


let read_lines ch = slist "\n" id (read_all ch)
let parse_http_params s = 
  Str.split(Str.regexp"&") s |> 
  List.map (fun s -> 
    let l = Str.split (Str.regexp "=") s 
    in try List.hd l, List.hd (List.tl l) with Failure _ -> raise (Failure ("can't parse"^s)))
let read_params ch = parse_http_params (read_lines ch)
let assoc key dic = try List.assoc key dic with Not_found -> raise (Failure (key ^ " not found"))

let fetch_request_token () = 
      Oauth.fetch_request_token 
        ~host:host
        ~path:"/oauth/request_token"
        ~oauth_consumer_key:ocamltter_consumer_key
        ~oauth_consumer_secret:ocamltter_consumer_secret
        ()
    (fun _ ch ->
  let res = read_params ch in
  let token, secret = assoc "oauth_token" res, assoc "oauth_token_secret" res in
    "http://twitter.com/oauth/authorize?oauth_token="^token, token, secret)



let fetch_access_token req_token req_secret verif = 
  fetch_access_token 
    ~http_method:GET
    ~host:host
    ~path:"/oauth/access_token"
    ~oauth_consumer_key:ocamltter_consumer_key
    ~oauth_consumer_secret:ocamltter_consumer_secret
    ~oauth_token:req_token
    ~oauth_token_secret:req_secret
    ~verif:verif
    ()
    (fun _ ch -> 
      let res = read_params ch in
      let acc_token, acc_secret, user = 
        assoc "oauth_token" res, 
        assoc "oauth_token_secret" res,
        assoc "screen_name" res
      in user, acc_token, acc_secret
    )



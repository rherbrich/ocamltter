open Util
open Util.Date
open Http
open Json

exception TwErr of string

type timeline = {
    date: Date.t;
    sname: string;
    id: string;
    clientname: string;
    text: string;
  }

let parse_date st =
  let mon = pmonth @@ String.sub st 4 3 in
  let day = int_of_string @@ String.sub st 8 2 in
  let h = int_of_string @@ String.sub st 11 2 in
  let m = int_of_string @@ String.sub st 14 2 in
  let s = int_of_string @@ String.sub st 17 2 in
  let year = int_of_string @@ String.sub st 26 4 in
  Date.make_from_gmt year mon day h m s

let show tl =
  let h,m = hour tl.date, min tl.date in
  !%" [%02d:%02d] %s: %s %sL" h m tl.sname tl.text tl.id

let json2timeline j =
  let post j =
    let date =
      Json.getf "created_at" j +> Json.as_string +> parse_date
    in
    let text =
      Json.getf "text" j +> Json.as_string
    in
    let id =
      Json.getf "id" j +> Json.as_float +> Int64.of_float +> Int64.to_string
    in
    let sname =
      Json.getf "user" j +> Json.getf "screen_name" +> Json.as_string
    in
    let client =
      Json.getf "source" j +> Json.as_string
    in
    {date=date; sname=sname; text=text; id=id; clientname=client}
  in
  Json.as_list j +> List.map post

let twitter (f: unit -> string) =
  try
    let j = Json.parse @@ f () in
    match Json.getf_opt "error" j with
    | Some err ->
	let msg = Json.as_string err in
(*      let req = Json.as_string @@ Json.getf "request" j in*)
	raise (TwErr msg)
    | None -> j
  with
  | TwErr m as e -> raise e
  | e -> failwith ("twitter error: "^Printexc.to_string e)

let home_timeline ?since_id ?(count=20) (user, pass) =
  twitter begin fun () ->
    let since = match since_id with
    | Some since -> "&since_id=" ^ since
    | None -> ""
    in
    Http.conn GET ~user:user ~pass:pass
      (!%"twitter.com/statuses/home_timeline.json?count=%d%s" count since)
      (fun _ ch -> slist "\n" id (read_all ch))
  end
    +> json2timeline

let get_aline acc status_id =
  let prev = Int64.to_string (Int64.pred status_id) in
  home_timeline ~since_id:prev ~count:200 acc
    +> (List.hd $ List.filter (fun tl -> tl.id = Int64.to_string status_id))


let update ?(in_reply_to_status_id) (user, pass) text =
  twitter begin fun () ->
    let reply, text = match in_reply_to_status_id with
    | Some id ->
	let tl = get_aline (user,pass) (Int64.of_string id) in
	(!%"&in_reply_to_status_id=%s" id, !%"@%s %s" tl.sname text)
    | None -> "",text
    in
    let arg =
      !%"status=%s%s" (Http.url_encode text) reply
    in
    Http.conn (POST arg) ~user:user ~pass:pass
      "twitter.com/statuses/update.json"
      (fun _ ch -> slist "\n" id (read_all ch))
  end

let retweet (user, pass) status_id =
  twitter begin fun () ->
    Http.conn (POST ("")) ~user:user ~pass:pass
      (!%"twitter.com/statuses/retweet/%s.json" status_id)
      (fun _ ch -> slist "\n" id (read_all ch))
  end

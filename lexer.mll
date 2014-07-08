{
  open Types
  open Lexing
  open Printf

  let get_loc lexbuf =
          let start = lexbuf.lex_start_p                in
          let line = start.pos_lnum                     in
          let cnum = start.pos_cnum - start.pos_bol     in
                mk_loc line cnum
}

let space   = [' ' '\t']
let modname = ['a'-'z' 'A'-'Z' '0'-'9' '_']+
let ident   = ['a'-'z' 'A'-'Z' '0'-'9' '_']['a'-'z' 'A'-'Z' '0'-'9' '_' '!' '?' '\'' ]*
let capital = ['A'-'Z']+

rule token = parse
  | space       { token lexbuf  }
  | '\n'        { new_line lexbuf ; token lexbuf }
  | "(;"        { comment lexbuf}
  | '.'         { DOT           }
  | ','         { COMMA         }
  | ':'         { COLON         }
  | '['         { LEFTSQU       }
  | ']'         { RIGHTSQU      }
  | '{'         { LEFTBRA       }
  | '}'         { RIGHTBRA      }
  | '('         { LEFTPAR       }
  | ')'         { RIGHTPAR      }
  | "-->"	{ LONGARROW     }
  | "->"	{ ARROW         }
  | "=>"	{ FATARROW      }
  | ":="	{ DEF           }
  | "_"         { UNDERSCORE ( get_loc lexbuf ) }
  | "Type"      { TYPE ( get_loc lexbuf )       }
  | "#NAME" space+ (modname as md)
  { NAME (get_loc lexbuf , hstring md) }
  | "#WHNF"     { WHNF ( get_loc lexbuf ) }
  | "#HNF"      { HNF ( get_loc lexbuf ) }
  | "#SNF"      { SNF ( get_loc lexbuf ) }
  | "#STEP"     { STEP ( get_loc lexbuf ) }
  | "#INFER"    { INFER ( get_loc lexbuf ) }
  | "#CONV"     { CONV ( get_loc lexbuf ) }
  | "#CHECK"    { CHECK ( get_loc lexbuf ) }
  | "#PRINT"    { PRINT ( get_loc lexbuf ) }
  | "#GDT"      { GDT ( get_loc lexbuf ) }
  | "#LISTRULES"     { LISTRULES ( get_loc lexbuf ) }
  | "#LISTNONLINEAR" { LISTNONLINEAR ( get_loc lexbuf ) }
  | "#LISTTYPELEVEL" { LISTTYPELEVEL ( get_loc lexbuf ) }
  | "#LISTPIRULES"   { LISTPIRULES ( get_loc lexbuf ) }
  | "#TPDB"      { TPDB ( get_loc lexbuf ) }
  | '#' (capital as cmd)
  { OTHER (get_loc lexbuf, cmd) }
  | modname as md '.' (ident as id)
  { QID ( get_loc lexbuf , hstring md , hstring id ) }
  | ident  as id
  { ID  ( get_loc lexbuf , hstring id ) }
  | _   as s
  { Global.fail (get_loc lexbuf) "Unexpected characters '%s'." (String.make 1 s) }
  | eof { EOF }

 and comment = parse
  | ";)" { token lexbuf          }
  | '\n' { new_line lexbuf ; comment lexbuf }
  | _    { comment lexbuf        }
  | eof	 { Global.fail (get_loc lexbuf) "Unexpected end of file."  }

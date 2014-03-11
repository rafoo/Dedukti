
open Types

type 'a substitution = (int*'a) list
(*
module type UTerm =
sig
  type term
  type error
  val no_unifier: error
  val subst: term substitution -> term -> term
  val occurs_check: int -> term -> bool
  val decompose: (int*term) list -> (int*term*term) list 
  -> ((int*term) list,error) sum
end

module Make = functor (T: UTerm) ->
struct
  type state = (int*T.term*T.term) list * (int*T.term) list * T.term substitution

  let rec safe_assoc v = function
    | []                  -> None
    | (x,t)::_ when x=v   -> Some t
    | _::tl               -> safe_assoc v tl

  let rec unify0 : state -> (T.term substitution,T.error) sum = function
    | ( [], [] , s )            -> Success s
    | ( [], (v,te0)::lst , s )  ->
        ( let te = T.subst s te0 in
            if T.occurs_check v te then Failure T.no_unifier
            else
              match safe_assoc v s with
                | Some te'      -> unify0 ( [(0,te,te')] , lst , s )
                | None      ->
                    let s' = List.map (fun (z,t) -> (z,T.subst [(v,te)] t)) s in
                      unify0 ( [] , lst , (v,te)::s' )
        )
    | ( a , b , s )      ->
        ( match T.decompose b a with
            | Success b'        -> unify0 ( [] , b' , s )
            | fail              -> fail
        )

  let unify lst = 
    let lst' = List.map (fun (t,t') -> (0,t,t')) lst in
      unify0 ( lst' , [] , [] )
end

(* Partial Higher Order Unification *)

type unif_error = 
  | NoUnifier
  | NoWHNF
(*  | TooComplex *)

module TU : UTerm with type term = Types.term with type error = unif_error =
struct
  type term = Types.term

  type error = unif_error
  let no_unifier = NoUnifier

  let subst = Subst.subst_meta 

  let rec add_lst k a l1 l2 =
    match l1, l2 with
      | [], []                  -> Some a
      | a1::l1', a2::l2'        -> add_lst k ((k,a1,a2)::a) l1' l2'
      | _,_                     -> None

  let is_neutral = function
    | []                                        -> assert false
    | Type::_ | Kind::_ | (Pi(_,_,_))::_        -> true
    | (DB(_,_))::_ | (Lam(_,_,_))::_            -> false
    | (Meta _)::_ | (App _)::_                  -> assert false
    | (Const (m,v))::_                          ->
        ( match Env.get_global_symbol dloc m v with
            | Env.Decl(_,None)  -> true
            | _                 -> false )

  exception ShiftExn
  let rec shift (r:int) : term -> term = function
    | DB (x,n) when (n>=r)      -> mk_DB x (n-r) 
    | DB (_,_)                  -> raise ShiftExn
    | App args                  -> mk_App (List.map (shift r) args )
    | Lam (x,a,f)               -> mk_Lam x (shift r a) (shift r f)
    | Pi  (x,a,b)               -> mk_Pi  x (shift r a) (shift r b)
    | t                         -> t

  let print_eq (_,t1,t2) =
    (Global.debug 2) dloc "Decompose: %s == %s\n"
      (Pp.string_of_term t1) 
      (Pp.string_of_term t2) 

  let rec decompose b = function
    | []                -> Success b
    | (k,t1,t2)::a      ->
        begin
          match Reduction.bounded_whnf 500 t1,
                Reduction.bounded_whnf 500 t2 with
            | Some t1', Some t2'        ->
                begin
                  (*print_eq (0,t1',t2') ; *)
                  match t1', t2' with
                    | Meta n, t | t, Meta n  -> 
                        (try decompose ((n,shift k t)::b) a 
                         with ShiftExn -> Failure NoUnifier )
                    | Kind, Kind | Type, Type                   -> decompose b a
                    | DB(_,n1), DB(_,n2) when n1=n2             -> decompose b a
                    | Const(m1,v1), Const(m2,v2) when
                        (ident_eq v1 v2 && ident_eq m1 m2)      -> decompose b a
                    | Pi(_,a1,b1), Pi(_,a2,b2)
                    | Lam(_,a1,b1), Lam(_,a2,b2)        ->
                        decompose b ((k,a1,a2)::(k+1,b1,b2)::a)
                    | App ((Const (m1,v1))::args1) , 
                      App ((Const (m2,v2))::args2) when (Env.is_neutral dloc m1 v1) ->
                        if ident_eq v1 v2 && ident_eq m1 m2 then
                          ( match add_lst k a args1 args2 with
                              | Some a'  -> decompose b a'
                              | None     -> Failure NoUnifier )
                        else Failure NoUnifier
                    | App (f1::lst1) , t | t , App (f1::lst1)   ->
                        ( match Reduction.bounded_are_convertible 500 t1' t2' with
                            | Yes       -> decompose b a
                            | No        -> (
                                Global.debug_no_loc 2 "[Unification] Ignoring %s == %s." 
                                  (Pp.string_of_term t1') (Pp.string_of_term t2') ; 
                                decompose b a (*here we loose info*) )
                            | Maybe     -> Failure NoWHNF )
                    | _ , _                             -> Failure NoUnifier
                end
            | _,_                       -> Failure NoWHNF
        end

  let rec occurs_check n = function
    | Meta k                      -> n=k
    | Pi (_,a,b) | Lam (_,a,b)    -> occurs_check n a || occurs_check n b
    | App lst                     -> List.exists (occurs_check n) lst
    | _                           -> false
end

module TUnification = Make(TU)

let unify_t = TUnification.unify

(* Pattern Unification *)

module PU : UTerm with type term = Types.pattern =
struct
  type term = Types.pattern
  type error = unit
  let no_unifier = ()
  let subst = Subst.subst_pattern

  let rec occurs_check n = function
    | Var (_,k)           -> n=k
    | Pattern(_,_,args) -> aux n args 0
  and aux n args i =
    if i < Array.length args then
      if occurs_check n args.(i) then true
      else aux n args (i+1)
    else false

  let add_to_list lst0 arr1 arr2 =
    (*assert (Array.length arr1 = Array.length arr2) *)
    let n = Array.length arr1 in
    let rec aux lst i =
      if i<n then
        aux ((0,arr1.(i),arr2.(i))::lst) (i+1)
      else lst
    in
      aux lst0 0

  let rec decompose b = function
    | []                                        -> Success b
    | (_,Var(_,k),p)::a | (_,p,Var (_,k))::a    -> decompose ((k,p)::b) a
    | (_,Pattern (md,id,args),
       Pattern(md',id',args'))::a               ->
        if ident_eq id id' && ident_eq md md'
        && Array.length args = Array.length args' then
          decompose b (add_to_list a args args')
        else Failure ()

end

module PUnification = Make(PU)

let unify_p lst =
  match PUnification.unify lst with
    | Success s  -> Some s
    | Failure _  -> None

 *)

                      (**************)
type uty =
  | MGU         of term substitution
  | UPrefix     of term substitution
  | NoUnifier

type state =    (int*term*term) list 
                * (int*term) list 
                * term substitution
                * (int*term*term) list

let rec add_lst k a l1 l2 =
    match l1, l2 with
      | [], []                  -> Some a
      | a1::l1', a2::l2'        -> add_lst k ((k,a1,a2)::a) l1' l2'
      | _,_                     -> None

exception ShiftExn
let rec shift (r:int) : term -> term = function
  | DB (x,n) when (n>=r)      -> mk_DB x (n-r) 
  | DB (_,_)                  -> raise ShiftExn
  | App args                  -> mk_App (List.map (shift r) args )
  | Lam (x,a,f)               -> mk_Lam x (shift r a) (shift r f)
  | Pi  (x,a,b)               -> mk_Pi  x (shift r a) (shift r b)
  | t                         -> t

let rec decompose b c = function
    | []                -> Some (b,c)
    | (k,t1,t2)::a      ->
        begin
          match Reduction.bounded_whnf 500 t1,
                Reduction.bounded_whnf 500 t2 with
            | Some t1', Some t2'        ->
                begin
                  match t1', t2' with
                    | Meta n, t | t, Meta n             -> 
                        (try decompose ((n,shift k t)::b) c a 
                         with ShiftExn -> None )
                    | Kind, Kind | Type, Type           -> decompose b c a
                    | DB(_,n1), DB(_,n2) when n1=n2     -> decompose b c a
                    | Const(m1,v1), Const(m2,v2) when
                        (ident_eq v1 v2 && ident_eq m1 m2) -> decompose b c a
                    | Pi(_,a1,b1), Pi(_,a2,b2)
                    | Lam(_,a1,b1), Lam(_,a2,b2)        ->
                        decompose b c ((k,a1,a2)::(k+1,b1,b2)::a)
                    | App ((Const (m1,v1))::args1) , 
                      App ((Const (m2,v2))::args2) when (Env.is_neutral dloc m1 v1) ->
                        if ident_eq v1 v2 && ident_eq m1 m2 then
                          ( match add_lst k a args1 args2 with
                              | Some a'  -> decompose b c a'
                              | None     -> None )
                        else None
                    | App (f1::lst1) , t | t , App (f1::lst1)   ->
                        ( match Reduction.bounded_are_convertible 500 t1' t2' with
                            | Yes       -> decompose b c a
                            | No        -> decompose b ((k,t1',t2')::c) a 
                            | Maybe     -> assert false (*TODO*) )
                    | _ , _                             -> None
                end
            | _ , _     -> assert false (*TODO*)
        end

let rec safe_assoc v = function
  | []                  -> None
  | (x,t)::_ when x=v   -> Some t
  | _::tl               -> safe_assoc v tl

let rec occurs_check n = function
    | Meta k                      -> n=k
    | Pi (_,a,b) | Lam (_,a,b)    -> occurs_check n a || occurs_check n b
    | App lst                     -> List.exists (occurs_check n) lst
    | _                           -> false

let rec unify0 : state -> uty = function
  | ( [] , [] , s , [] )        -> MGU s
  | ( [] , [] , s , _  )        -> UPrefix s
  | ( [] , (v,te0)::lst , s , c )       ->
      begin
        let te = Subst.subst_meta s te0 in
          if occurs_check v te then NoUnifier
          else
            match safe_assoc v s with
              | Some te'        -> unify0 ( [(0,te,te')] , lst , s , c )
              | None            ->
                  let sub = Subst.subst_meta [(v,te)] in
                  let s' = List.rev_map (fun (z,t) -> (z, sub t)) s in
                    unify0 ( List.rev_map ( fun (z,t1,t2) -> (z,sub t1,sub t2) ) c,
                             lst , (v,te)::s' , [] )
      end
  | ( a , b , s , c )           ->
      begin
        match decompose b c a with
          | Some (b',c')        -> unify0 ( [] , b' , s , c' )
          | None                -> NoUnifier
      end

let unify lst = 
  let lst' = List.map (fun (t,t') -> (0,t,t')) lst in
    unify0 ( lst' , [] , [] , [] )
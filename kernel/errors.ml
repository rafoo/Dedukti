open Basic
open Format
open Rule
open Term
open Reduction

let errors_in_snf = ref false

let snf_config = {default_cfg with strategy = Snf}

let snf t = if !errors_in_snf then Env.unsafe_reduction ~red:snf_config t else t

let color = ref true

let colored n s =
  if !color then "\027[3" ^ string_of_int n ^ "m" ^ s ^ "\027[m" else s

let green  = colored 2
let orange = colored 3
let red    = colored 1

let success fmt =
  eprintf "%s" (green "SUCCESS ");
  kfprintf (fun _ -> pp_print_newline err_formatter () ) err_formatter fmt


let prerr_loc lc = eprintf "%a " pp_loc lc

let fail lc fmt =
  eprintf "%s" (red "ERROR ") ;
  prerr_loc lc;
  kfprintf (fun _ -> pp_print_newline err_formatter () ; raise Exit) err_formatter fmt

let pp_typed_context out = function
  | [] -> ()
  | _::_ as ctx -> fprintf out " in context:@.%a" Pp.print_typed_context ctx

let fail_typing_error err =
  let open Typing in
  match err with
  | KindIsNotTypable -> fail dloc "Kind is not typable."
  | ConvertibilityError (te,ctx,exp,inf) ->
    fail (get_loc te)
      "@[<v>Error while typing@ '%a'%a.@.Expected:@ %a.@.Inferred:@ %a.@]"
      Pp.print_term te pp_typed_context ctx Pp.print_term (snf exp) Pp.print_term (snf inf)
  | VariableNotFound (lc,x,n,ctx) ->
    fail lc "@[The variable@ '%a'@ was not found in context:@.@]"
      Pp.print_term (mk_DB lc x n) pp_typed_context ctx
  | SortExpected (te,ctx,inf) ->
    fail (Term.get_loc te)
      "@[Error while typing@ '%a'%a.@.Expected: a sort.@.Inferred:@ %a.@]"
      Pp.print_term te pp_typed_context ctx Pp.print_term (snf inf)
  | ProductExpected (te,ctx,inf) ->
    fail (get_loc te)
      "@[Error while typing@ '%a'%a.@.Expected: a product type.@.Inferred:@ %a.@]"
      Pp.print_term te pp_typed_context ctx Pp.print_term (snf inf)
  | InexpectedKind (te,ctx) ->
    fail (get_loc te)
      "@[Error while typing@ '%a'%a.@.Expected: anything but Kind.@.Inferred: Kind.@]"
      Pp.print_term te pp_typed_context ctx
  | DomainFreeLambda lc ->
    fail lc "@[Cannot infer the type of domain-free lambda.@]"
  | CannotInferTypeOfPattern (p,ctx) ->
    fail (get_loc_pat p)
      "@[Error while typing@ '%a'%a.@.The type could not be infered.@]"
      Pp.print_pattern p pp_typed_context ctx
  | CannotSolveConstraints (r,cstr) ->
    fail (get_loc_pat r.pat)
      "@[Error while typing the rewrite rule@.%a@.Cannot solve typing constraints:@.%a@]"
      Pp.print_untyped_rule r
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> fprintf fmt "@.")
           (fun out (_,t1,t2) -> fprintf out "%a ~~ %a"
                                   Pp.print_term t1 Pp.print_term t2))
        cstr
  | BracketError1 (te,ctx) ->
    fail (get_loc te) "@[Error while typing the term@ { %a }%a.@.\
                       Brackets can only contain variables occuring \
                       on their left and cannot contain bound variables.@]"
      Pp.print_term te pp_typed_context ctx
  | BracketError2 (te,ctx,ty) ->
    fail (get_loc te) "@[Error while typing the term@ { %a }%a.@.\
                       The type of brackets can only contain variables occuring\
                       on their left and cannot contains bound variables.@]"
      Pp.print_term te pp_typed_context ctx
  | FreeVariableDependsOnBoundVariable (l,x,n,ctx,ty) ->
    fail l "@[Error while typing@ '%a'%a.@.\
            The type is not allowed to refer to bound variables.@.\
            Infered type:@ %a.@]" Pp.print_ident x pp_typed_context ctx Pp.print_term ty
  | Unconvertible (l,t1,t2) ->
    fail l "@[Assertion error. Given terms are not convertible:@ '%a'@ and@ '%a'@]"
      Pp.print_term t1 Pp.print_term t2
  | Convertible (l,t1,t2) ->
    fail l "@[Assertion error. Given terms are convertible:@ '%a'@ and@ '%a'@]"
      Pp.print_term t1 Pp.print_term t2
  | Inhabit (l,t1,t2) ->
    fail l "@[Assertion error.@ '%a' is of type@ '%a'@]"
      Pp.print_term t1 Pp.print_term t2
  | NotImplementedFeature l -> fail l "@[Feature not implemented.@]"

let fail_dtree_error err =
  let open Dtree in
  match err with
  | HeadSymbolMismatch (lc,cst1,cst2) ->
    fail lc "@[Unexpected head symbol@ '%a'@ (expected@ '%a').@]"
      Pp.print_name cst1 Pp.print_name cst2
  | ArityMismatch (lc,cst) ->
    fail lc
      "@[All the rewrite rules for the symbol@ '%a'@ should have the same arity.@]"
      Pp.print_name cst
  | ArityInnerMismatch (lc,rid, id) ->
    fail lc
      "@[The definable symbol@ '%a'@ inside the rewrite rules for@ '%a' should have the same arity when they are on the same column.@]"
      Pp.print_ident id Pp.print_ident rid


let fail_rule_error err =
  let open Rule in
  match err with
  | BoundVariableExpected pat ->
    fail (get_loc_pat pat)
      "@[The pattern of the rule is not a Miller pattern. The pattern@ '%a'@ is not a bound variable.@]" Pp.print_pattern pat
  | VariableBoundOutsideTheGuard te ->
    fail (get_loc te)
      "@[The term@ '%a'@ contains a variable bound outside the brackets.@]"
      Pp.print_term te
  | DistinctBoundVariablesExpected (lc,x) ->
    fail lc "@[The pattern of the rule is not a Miller pattern. The variable@ '%a'@ should be applied to distinct variables.@]" Pp.print_ident x
  | UnboundVariable (lc,x,pat) ->
    fail lc "@[The variables@ '%a'@ does not appear in the pattern@ '%a'.@]"
      Pp.print_ident x Pp.print_pattern pat
  | AVariableIsNotAPattern (lc,id) ->
    fail lc "@[A variable is not a valid pattern.@]"
  | NotEnoughArguments (lc,id,n,nb_args,exp_nb_args) ->
    fail lc "@[The variable@ '%a'@ is applied to %i argument(s) (expected: at least %i).@]"
      Pp.print_ident id nb_args exp_nb_args
  | NonLinearRule r ->
    fail (Rule.get_loc_pat r.pat) "@[Non left-linear rewrite rule:@.%a.@.\
                               Maybe you forgot to pass the -nl option.@]"
      Pp.print_typed_rule r
  | NonLinearNonEqArguments(lc,arg) ->
    fail lc "For each occurence of the free variable %a, the symbol should be applied to the same number of arguments" Pp.print_ident arg


let pp_cerr out err =
  let open Confluence in
  match  err with
  | NotConfluent cmd ->
    fprintf out "@[Checker's answer: NO.@.Command: %s@]" cmd
  | MaybeConfluent cmd ->
    fprintf out "@[Checker's answer: MAYBE.@.Command: %s@]" cmd
  | CCFailure cmd ->
    fprintf out "@[Checker's answer: ERROR.@.Command: %s@]" cmd

let fail_signature_error err =
  let open Signature in
  match err with
  | UnmarshalBadVersionNumber (lc,md) ->
    fail lc "@[Fail to open module@ '%s'@ (file generated by a different version?).@]" md
  | UnmarshalSysError (lc,md,msg) ->
    fail lc "@[Fail to open module@ '%s'@ (%s).@]" md msg
  | UnmarshalUnknown (lc,md) ->
    fail lc "@[Fail to open module@ '%s'.@]" md
  | SymbolNotFound (lc,cst) ->
    fail lc "@[Cannot find symbol@ '%a'.@]" Pp.print_name cst
  | AlreadyDefinedSymbol (lc,id) ->
    fail lc "@[Already declared symbol@ '%a'.@]" Pp.print_ident id
  | CannotBuildDtree err -> fail_dtree_error err
  | CannotMakeRuleInfos err -> fail_rule_error err
  | CannotAddRewriteRules (lc,id) ->
    fail lc
      "@[Cannot add rewrite rules for the static symbol@ '%a'.@ \
       Add the keyword 'def' to its declaration to make the symbol\
       @ '%a'@ definable.@]"
      Pp.print_ident id Pp.print_ident id
  | ConfluenceErrorRules (lc,rs,cerr) ->
    fail lc "@[Confluence checking failed when adding the rewrite rules below.@.%a@.%a@]"
      pp_cerr cerr (pp_print_list ~pp_sep:(fun fmt () -> fprintf fmt "@\n")
                      pp_rule_infos) rs
  | ConfluenceErrorImport (lc,md,cerr) ->
    fail lc "@[Confluence checking failed when importing the module@ '%a'.@.%a@]"
      Pp.print_mident md pp_cerr cerr
  | GuardNotSatisfied(lc, t1, t2) ->
    fail lc "@[Error while reducing a term: a guard was not satisfied.@.\
             Expected:@ %a.@.\
             Found:@ %a@]"
      Pp.print_term t1 Pp.print_term t2

let fail_env_error = function
  | Env.EnvErrorSignature e -> fail_signature_error e
  | Env.EnvErrorType e -> fail_typing_error e
  | Env.KindLevelDefinition (lc,id) ->
    fail lc "@[Cannot add a rewrite rule for@ '%a'@ since it is a kind.@]" Pp.print_ident id
